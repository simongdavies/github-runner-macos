#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"

cat >"$TEST_BIN/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
command_name="${0##*/}"
case "$command_name" in
    uname) echo "${TEST_OS:-Darwin}" ;;
    id) echo "${TEST_UID:-0}" ;;
    stat) echo 0 ;;
    PlistBuddy)
        key="${2#Print :}"
        case "$key" in
            ProgramArguments:3) key=wrapper ;;
            ProgramArguments:4) key=runner ;;
            EnvironmentVariables:HOME) key=home ;;
        esac
        awk -F '=' -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; found=1 } END { if (!found) exit 1 }' "$3"
        ;;
    install)
        printf 'install\n' >> "$TEST_EVENTS"
        cp "$7" "$8"
        ;;
    sudo)
        if [[ "$1" == /bin/bash ]]; then
            echo elevate >> "$TEST_EVENTS"
            exec /usr/bin/env TEST_UID=0 SUDO_USER=operator "$@"
        fi
        [[ "$1" == -n && "$2" == -H && "$3" == -u ]]
        actor="$4"
        shift 4
        if [[ "$actor" == operator ]]; then
            export TEST_GH_ACTOR="$actor"
            exec "$@"
        fi
        [[ "$actor" == build-* ]]
        if [[ "$1" == /usr/bin/env ]]; then
            printf 'llvm %s\n' "$actor" >> "$TEST_EVENTS"
            [[ "$actor" != "${TEST_HEALTH_FAILURE:-never-match}" ]]
        else
            exec "$@"
        fi
        ;;
    gh)
        [[ "${TEST_GH_ACTOR:-}" == operator ]]
        if [[ "$1" == auth ]]; then
            [[ "$*" == 'auth status --hostname github.com' ]]
            [[ "${TEST_AUTH_FAILURE:-0}" == 0 ]]
            exit $?
        fi
        [[ "$1" == api && "$2" == --hostname && "$3" == github.com ]]
        shift 3
        if [[ "$1" == --method ]]; then
            [[ "$2" == POST && "$4" == --input && "$5" == - ]]
            endpoint="$3"
            runner_id="${endpoint%/labels}"
            runner_id="${runner_id##*/}"
            payload="$(cat)"
            printf 'post %s %s\n' "$endpoint" "$payload" >> "$TEST_EVENTS"
            [[ "${TEST_API_FAILURE:-0}" == 0 ]] || exit 1
            jq --argjson payload "$payload" '.labels += [$payload.labels[] | {name: ., type: "custom"}] | .labels |= unique_by(.name)' \
                "$TEST_CASE/github/$runner_id.json" > "$TEST_CASE/updated"
            mv "$TEST_CASE/updated" "$TEST_CASE/github/$runner_id.json"
            cat "$TEST_CASE/github/$runner_id.json"
        else
            runner_id="${1##*/}"
            cat "$TEST_CASE/github/$runner_id.json"
        fi
        ;;
    launchctl)
        case "$1" in
            print-disabled)
                [[ "${TEST_DISABLED_FAILURE:-0}" == 0 ]] || exit 1
                printf '{\n "custom.disabled-21" => true\n "custom.pool-4" => false\n}\n'
                ;;
            print) [[ "${TEST_ALL_LOADED:-0}" == 1 || "$2" != system/custom.pool-13 ]] ;;
            kickstart | bootstrap)
                printf '%s %s\n' "$1" "${*:2}" >> "$TEST_EVENTS"
                [[ "$*" != *"${TEST_FAIL_LABEL:-never-match}"* ]] || exit 1
                if [[ "${TEST_RECOVER_ON_RESTART:-0}" == 1 ]]; then
                    runner_id="${*: -1}"
                    runner_id="${runner_id##*-}"
                    runner_id="${runner_id%.plist}"
                    jq '.status = "online"' "$TEST_CASE/github/$runner_id.json" > "$TEST_CASE/updated"
                    mv "$TEST_CASE/updated" "$TEST_CASE/github/$runner_id.json"
                fi
                ;;
            *) exit 1 ;;
        esac
        ;;
    sleep) ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_BIN/mock"
for command_name in uname id stat PlistBuddy install launchctl sudo gh sleep; do
    cp "$TEST_BIN/mock" "$TEST_BIN/$command_name"
done
export PATH="$TEST_BIN:$PATH"

new_case() {
    export TEST_CASE="$TEST_ROOT/$1"
    export TEST_EVENTS="$TEST_CASE/events"
    unset TEST_OS TEST_UID TEST_FAIL_LABEL TEST_DISABLED_FAILURE
    unset TEST_ALL_LOADED TEST_HEALTH_FAILURE TEST_API_FAILURE
    unset TEST_AUTH_FAILURE TEST_RECOVER_ON_RESTART
    export SUDO_USER=operator
    mkdir -p "$TEST_CASE/daemons" "$TEST_CASE/services" "$TEST_CASE/source"
    : >"$TEST_EVENTS"
    sed -e "s|/Library/Application Support/github-runner-macos|$TEST_CASE/services|g" \
        -e "s|/Library/LaunchDaemons|$TEST_CASE/daemons|g" \
        -e "s|/usr/libexec/PlistBuddy|$TEST_BIN/PlistBuddy|g" \
        -e "s|/usr/bin/install|$TEST_BIN/install|g" \
        "$SCRIPT_DIR/macos-runner-maintenance.sh" >"$TEST_CASE/source/macos-runner-maintenance.sh"
    cp "$SCRIPT_DIR/github-runner-wrapper.sh" "$TEST_CASE/source/"
    for label in custom.pool-4 custom.pool-13 custom.disabled-21 unrelated.tart; do
        wrapper="$TEST_CASE/services/github-runner-wrapper.sh"
        [[ "$label" != unrelated.tart ]] || wrapper=/other/tart-runner-loop.sh
        cat >"$TEST_CASE/daemons/$label.plist" <<EOF
Label=$label
UserName=build-$label
home=$TEST_CASE/homes/$label
runner=$TEST_CASE/homes/$label/actions-runner
wrapper=$wrapper
StandardOutPath=/logs/$label.out
StandardErrorPath=/logs/$label.err
EOF
    done
}

maintenance() {
    bash "$TEST_CASE/source/macos-runner-maintenance.sh" "$@" >"$TEST_CASE/output" 2>&1
}

succeed() {
    if ! maintenance "$@"; then
        cat "$TEST_CASE/output" >&2
        exit 1
    fi
}

label_case() {
    new_case "$1"
    export TEST_ALL_LOADED=1
    mkdir -p "$TEST_CASE/github"
    for runner_id in 4 13; do
        local runner_dir="$TEST_CASE/homes/custom.pool-$runner_id/actions-runner"
        mkdir -p "$runner_dir"
        jq -n --argjson id "$runner_id" --arg name "runner-$runner_id" \
            '{agentId: $id, agentName: $name, gitHubUrl: "https://github.com/example"}' >"$runner_dir/.runner"
        jq -n --arg name "runner-$runner_id" \
            '{name: $name, status: "online", busy: false, labels: [{name: "self-hosted"}, {name: "macOS"}, {name: "ARM64"}, {name: "keep-existing"}]}' \
            >"$TEST_CASE/github/$runner_id.json"
        echo "hvf,original-$runner_id" >"$runner_dir/.configured-labels"
    done
}

new_case inventory
succeed --list
grep -Fq 'custom.pool-4: account=build-custom.pool-4 loaded=yes enabled=yes' "$TEST_CASE/output"
grep -Fq 'custom.pool-13: account=build-custom.pool-13 loaded=no enabled=yes' "$TEST_CASE/output"
grep -Fq 'custom.disabled-21: account=build-custom.disabled-21 loaded=yes enabled=no' "$TEST_CASE/output"
grep -Fq '/logs/custom.pool-13.err' "$TEST_CASE/output"
if grep -Fq unrelated.tart "$TEST_CASE/output"; then exit 1; fi
[[ ! -s "$TEST_EVENTS" ]]

label_case repair-all
unset TEST_ALL_LOADED
succeed --repair-drained
grep -Fxq "bootstrap system $TEST_CASE/daemons/custom.pool-13.plist" "$TEST_EVENTS"
grep -Fxq 'kickstart -k system/custom.pool-4' "$TEST_EVENTS"
if grep -Fq custom.disabled-21 "$TEST_EVENTS"; then exit 1; fi
awk '/^llvm / { verified++ } /^post / && verified != 2 { exit 1 }' "$TEST_EVENTS"
cmp "$SCRIPT_DIR/github-runner-wrapper.sh" "$TEST_CASE/services/github-runner-wrapper.sh"

new_case elevation
export TEST_UID=501
succeed --list
grep -Fxq elevate "$TEST_EVENTS"

new_case install-only
succeed --install-only
[[ "$(cat "$TEST_EVENTS")" == install ]]

label_case disabled-plist
cp "$TEST_CASE/daemons/custom.pool-13.plist" "$TEST_CASE/daemons/custom.stopped.plist"
sed 's/custom.pool-13/custom.stopped/g' "$TEST_CASE/daemons/custom.stopped.plist" >"$TEST_CASE/replaced"
mv "$TEST_CASE/replaced" "$TEST_CASE/daemons/custom.stopped.plist"
echo 'Disabled=true' >>"$TEST_CASE/daemons/custom.stopped.plist"
echo 'Disabled=true' >>"$TEST_CASE/daemons/custom.pool-4.plist"
succeed --repair-drained
if grep -Fq custom.stopped "$TEST_EVENTS"; then exit 1; fi
grep -Fq 'kickstart -k system/custom.pool-4' "$TEST_EVENTS"

label_case restart-failure
export TEST_FAIL_LABEL=custom.pool-13
if maintenance --repair-drained; then exit 1; fi
grep -Fq 'kickstart -k system/custom.pool-4' "$TEST_EVENTS"
if grep -Fq 'post ' "$TEST_EVENTS"; then exit 1; fi

for refusal in wrong-os unreadable-disabled no-runners all-disabled bad-metadata symlink; do
    label_case "$refusal"
    case "$refusal" in
        wrong-os) export TEST_OS=Linux ;;
        unreadable-disabled) export TEST_DISABLED_FAILURE=1 ;;
        no-runners) rm "$TEST_CASE/daemons/"*.plist ;;
        all-disabled) rm "$TEST_CASE/daemons/custom.pool-"*.plist ;;
        bad-metadata)
            sed '/^home=/d' "$TEST_CASE/daemons/custom.pool-13.plist" >"$TEST_CASE/malformed"
            mv "$TEST_CASE/malformed" "$TEST_CASE/daemons/custom.pool-13.plist"
            ;;
        symlink) ln -s "$TEST_CASE/unrelated" "$TEST_CASE/services/github-runner-wrapper.sh" ;;
    esac
    if maintenance --repair-drained; then
        echo "FAIL: expected refusal for $refusal" >&2
        exit 1
    fi
    [[ ! -s "$TEST_EVENTS" ]]
done

label_case restore-initial-labels
succeed --repair-drained
for runner_id in 4 13; do
    jq -e --arg initial "original-$runner_id" \
        '[.labels[].name] | contains(["hvf", $initial, "keep-existing", "self-hosted", "macOS", "ARM64"])' \
        "$TEST_CASE/github/$runner_id.json" >/dev/null
done
[[ "$(grep -c '^post ' "$TEST_EVENTS")" == 2 ]]
[[ "$(grep -c '^llvm ' "$TEST_EVENTS")" == 2 ]]

label_case required-labels
rm "$TEST_CASE/homes/custom.pool-13/actions-runner/.configured-labels"
succeed --repair-drained
jq -e '[.labels[].name] | contains(["hvf", "keep-existing"])' "$TEST_CASE/github/13.json" >/dev/null
grep -Fxq hvf "$TEST_CASE/homes/custom.pool-13/actions-runner/.configured-labels"
grep -Fxq hvf,original-4 "$TEST_CASE/homes/custom.pool-4/actions-runner/.configured-labels"

label_case custom-required-labels
rm "$TEST_CASE/homes/custom.pool-13/actions-runner/.configured-labels"
succeed --repair-drained hvf,required-custom
jq -e '[.labels[].name] | contains(["hvf", "required-custom", "keep-existing"])' "$TEST_CASE/github/13.json" >/dev/null

label_case offline-recovery
export TEST_RECOVER_ON_RESTART=1
for runner_id in 4 13; do
    jq '.status = "offline"' "$TEST_CASE/github/$runner_id.json" >"$TEST_CASE/updated"
    mv "$TEST_CASE/updated" "$TEST_CASE/github/$runner_id.json"
done
succeed --repair-drained
[[ "$(grep -c '^post ' "$TEST_EVENTS")" == 2 ]]

label_case repo-target
jq '.gitHubUrl = "https://github.com/example/project"' \
    "$TEST_CASE/homes/custom.pool-13/actions-runner/.runner" >"$TEST_CASE/updated"
mv "$TEST_CASE/updated" "$TEST_CASE/homes/custom.pool-13/actions-runner/.runner"
succeed --repair-drained
grep -Fq 'post repos/example/project/actions/runners/13/labels' "$TEST_EVENTS"

for refusal in auth-failure offline busy wrong-name missing-default-label bad-target llvm-failure; do
    label_case "$refusal"
    case "$refusal" in
        auth-failure) export TEST_AUTH_FAILURE=1 ;;
        llvm-failure) export TEST_HEALTH_FAILURE=build-custom.pool-4 ;;
        bad-target)
            jq '.gitHubUrl = "https://untrusted.example/org"' "$TEST_CASE/homes/custom.pool-4/actions-runner/.runner" >"$TEST_CASE/updated"
            mv "$TEST_CASE/updated" "$TEST_CASE/homes/custom.pool-4/actions-runner/.runner"
            ;;
        *)
            case "$refusal" in
                offline) filter='.status = "offline"' ;;
                busy) filter='.busy = true' ;;
                wrong-name) filter='.name = "someone-else"' ;;
                missing-default-label) filter='.labels |= map(select(.name != "ARM64"))' ;;
            esac
            jq "$filter" "$TEST_CASE/github/4.json" >"$TEST_CASE/updated"
            mv "$TEST_CASE/updated" "$TEST_CASE/github/4.json"
            ;;
    esac
    if maintenance --repair-drained; then
        echo "FAIL: label restoration must refuse $refusal" >&2
        exit 1
    fi
    if grep -Fq 'post ' "$TEST_EVENTS"; then exit 1; fi
    case "$refusal" in
        offline | llvm-failure) ;;
        *) [[ ! -s "$TEST_EVENTS" ]] ;;
    esac
done

label_case api-failure
export TEST_API_FAILURE=1
if maintenance --repair-drained; then exit 1; fi
[[ "$(grep -c '^post ' "$TEST_EVENTS")" == 2 ]]

echo 'PASS: unified repair, privilege escalation, discovery, restart and disabled-service preservation'
echo 'PASS: required labels, additive updates, offline recovery and authentication/health/identity refusals'
