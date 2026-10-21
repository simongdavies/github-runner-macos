#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"

# Mock macOS account/service commands. No real users or services are modified.
cat > "$TEST_BIN/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
command_name="${0##*/}"
printf '%s [%s]' "$command_name" "${TEST_ACTOR:-root}" >> "$TEST_LOG"
printf ' <%s>' "$@" >> "$TEST_LOG"
printf '\n' >> "$TEST_LOG"
case "$command_name" in
    id)
        case "$1" in
            -u)
                if [ "$#" -eq 1 ]; then
                    echo "${TEST_UID:-0}"
                else
                    cat "$TEST_DB/$2/UniqueID"
                fi
                ;;
            -Gn)
                if [ -f "$TEST_DB/$2/groups" ]; then
                    cat "$TEST_DB/$2/groups"
                else
                    echo staff
                fi
                ;;
        esac
        ;;
    dscl)
        operation="$2"
        record="$3"
        user="${record##*/}"
        case "$operation" in
            -list)
                echo 'root 0'
                for account in "$TEST_DB"/*; do
                    [ -f "$account/UniqueID" ] || continue
                    printf '%s %s\n' "${account##*/}" "$(cat "$account/UniqueID")"
                done
                ;;
            -read)
                [ -d "$TEST_DB/$user" ] || exit 1
                if [ "$#" -gt 3 ]; then
                    if [ "$4" = Comment ]; then
                        printf '%s:\n %s\n' "$4" "$(cat "$TEST_DB/$user/$4")"
                    elif [ "$4" = IsHidden ]; then
                        printf 'dsAttrTypeNative:%s: %s\n' "$4" "$(cat "$TEST_DB/$user/$4")"
                    else
                        printf '%s: %s\n' "$4" "$(cat "$TEST_DB/$user/$4")"
                    fi
                fi
                ;;
            -create)
                mkdir -p "$TEST_DB/$user"
                if [ "$#" -gt 3 ]; then
                    printf '%s\n' "$5" > "$TEST_DB/$user/$4"
                fi
                ;;
        esac
        ;;
    stat)
        path="$3"
        case "$path" in
            "$TEST_USERS"/*)
                user="${path##*/}"
                if [ -f "$TEST_DB/$user/home-owner" ]; then
                    cat "$TEST_DB/$user/home-owner"
                else
                    cat "$TEST_DB/$user/UniqueID"
                fi
                ;;
            *) echo 0 ;;
        esac
        ;;
    sudo)
        [ "$1" = -H ] && [ "$2" = -u ]
        actor="$3"
        shift 3
        [ "$1" = /usr/bin/env ] && [ "$2" = -i ]
        shift 2
        home="" user="" logname="" runner_path=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                HOME=*) home="${1#HOME=}" ;;
                USER=*) user="${1#USER=}" ;;
                LOGNAME=*) logname="${1#LOGNAME=}" ;;
                PATH=*) runner_path="${1#PATH=}" ;;
                *) break ;;
            esac
            shift
        done
        exec /usr/bin/env -i HOME="$home" USER="$user" LOGNAME="$logname" \
            PATH="$TEST_BIN:$runner_path" TEST_ACTOR="$actor" TEST_LOG="$TEST_LOG" \
            TEST_DB="$TEST_DB" TEST_USERS="$TEST_USERS" TEST_BIN="$TEST_BIN" "$@"
        ;;
    chown) ;;
    chmod)
        [ "$1" != +x ] || exec /bin/chmod "$@"
        ;;
    mkdir)
        if [ "$1" = -m ]; then shift 2; fi
        exec /bin/mkdir "$@"
        ;;
    uname)
        if [ "$1" = -s ]; then echo "${TEST_OS:-Darwin}"; else echo arm64; fi
        ;;
    hostname) echo fixture-mac ;;
    curl)
        while [ "$1" != -o ]; do shift; done
        printf 'public runner archive\n' > "$2"
        ;;
    tar)
        [ "$1" = -xzf ] && [ "$3" = -C ]
        if [ "$2" = - ]; then
            archive_content="$(cat)"
        else
            if [ "${TEST_ACTOR:-root}" != root ]; then
                echo "tar: cannot traverse root's private temporary directory" >&2
                exit 1
            fi
            archive_content="$(cat "$2")"
        fi
        [ "$archive_content" = 'public runner archive' ]
        cat > "$4/config.sh" <<'CONFIG'
#!/bin/bash
set -euo pipefail
printf 'config [%s] home=<%s> user=<%s> inherited=<%s> command=<%s>\n' \
    "${TEST_ACTOR:-root}" "$HOME" "$USER" "${HOST_ONLY_SECRET:-unset}" "$1" >> "$TEST_LOG"
if [ "$1" = remove ]; then
    rm -f .runner .credentials .credentials_rsaparams
else
    touch .runner .credentials
    echo 'FIXTURE_CONFIG=1' > .env
fi
CONFIG
        chmod +x "$4/config.sh"
        ;;
    sed)
        # Emulate BSD in-place editing on either BSD or GNU test hosts.
        if [ "$1" = -i ] && [ "${2-missing}" = "" ]; then
            shift 2
            /usr/bin/sed "$1" "$2" > "$2.test-tmp"
            mv "$2.test-tmp" "$2"
            exit 0
        fi
        exec /usr/bin/sed "$@"
        ;;
    launchctl)
        [ "$1" != list ]
        ;;
    *) echo "Unexpected mock: $command_name" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TEST_BIN/mock"
for command_name in id dscl stat sudo chown chmod mkdir uname hostname curl tar sed launchctl; do
    cp "$TEST_BIN/mock" "$TEST_BIN/$command_name"
done
export PATH="$TEST_BIN:$PATH"
export USER="${USER:-fixture-admin}"
export HOST_ONLY_SECRET=must-not-be-inherited

new_case() {
    local name="$1"
    export TEST_CASE="$TEST_ROOT/$name"
    export TEST_DB="$TEST_CASE/accounts"
    export TEST_USERS="$TEST_CASE/users"
    export TEST_LOG="$TEST_CASE/commands.log"
    unset TEST_UID TEST_OS
    /bin/mkdir -p "$TEST_DB" "$TEST_USERS" "$TEST_CASE/source"
    : > "$TEST_LOG"
    # Redirect only macOS installation roots into a disposable fixture.
    /usr/bin/sed \
        -e "s|/Users/|$TEST_USERS/|g" \
        -e "s|/Library/LaunchDaemons|$TEST_CASE/daemons|g" \
        -e "s|/Library/Application Support/github-runner-macos|$TEST_CASE/service-scripts|g" \
        "$SCRIPT_DIR/bootstrap-gh-runners.sh" > "$TEST_CASE/source/bootstrap-gh-runners.sh"
    cp "$SCRIPT_DIR/github-runner-wrapper.sh" "$SCRIPT_DIR/github-runner-cleanup.sh" "$TEST_CASE/source/"
}

bootstrap() {
    bash "$TEST_CASE/source/bootstrap-gh-runners.sh" "$@" > "$TEST_CASE/output" 2>&1
}

provision() {
    bootstrap --runner-user-prefix gha-macos --count 2 --repo owner/repo \
        --token fixture-token --version 1.2.3 --install-launchd --launchd-scope daemon "$@"
}

assert_contains() {
    grep -Fq -- "$2" "$1" || {
        echo "FAIL: missing '$2' in $1" >&2
        cat "$1" >&2
        exit 1
    }
}

assert_absent() {
    if grep -Fq -- "$2" "$1"; then
        echo "FAIL: unexpected '$2' in $1" >&2
        exit 1
    fi
}

expect_failure() {
    local message="$1"
    shift
    if "$@"; then
        echo "FAIL: expected failure: $message" >&2
        exit 1
    fi
    assert_contains "$TEST_CASE/output" "$message"
}

new_case provision
provision || { cat "$TEST_CASE/output"; exit 1; }
for i in 1 2; do
    user="gha-macos-$i"
    home="$TEST_USERS/$user"
    plist="$TEST_CASE/daemons/com.github.runner-$i.plist"
    assert_contains "$TEST_DB/$user/Comment" "Managed by bootstrap-gh-runners.sh ($user)"
    assert_contains "$TEST_DB/$user/UniqueID" "$((500 + i))"
    assert_contains "$TEST_DB/$user/Password" '*'
    assert_contains "$TEST_DB/$user/UserShell" /usr/bin/false
    assert_contains "$TEST_LOG" "config [$user] home=<$home> user=<$user> inherited=<unset>"
    assert_contains "$TEST_LOG" "tar [$user] <-xzf> <-> <-C> <$home/actions-runner>"
    assert_contains "$TEST_LOG" "chmod [$user] <700> <$home>"
    assert_contains "$TEST_LOG" "chmod [$user] <700> <$home/actions-runner>"
    assert_contains "$plist" "<string>$user</string>"
    assert_contains "$plist" "<string>$home</string>"
    assert_contains "$plist" "<string>$TEST_CASE/service-scripts/github-runner-wrapper.sh</string>"
    assert_contains "$plist" /opt/homebrew/bin:
    assert_contains "$plist" '<key>USER</key>'
    assert_contains "$plist" '<key>LOGNAME</key>'
    assert_contains "$home/actions-runner/.env" "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=$home/actions-runner/job-completed-hook.sh"
    assert_absent "$plist" .home
done
assert_contains "$TEST_LOG" 'chown [root] <root:wheel>'

: > "$TEST_LOG"
provision || { cat "$TEST_CASE/output"; exit 1; }
assert_absent "$TEST_LOG" '<-create>'
assert_absent "$TEST_LOG" 'config ['
assert_contains "$TEST_CASE/output" 'skipping; use --replace'
[ "$(grep -c '^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=' "$TEST_USERS/gha-macos-1/actions-runner/.env")" -eq 1 ]

: > "$TEST_LOG"
provision --replace || { cat "$TEST_CASE/output"; exit 1; }
assert_contains "$TEST_LOG" 'config [gha-macos-1]'
assert_contains "$TEST_LOG" 'command=<remove>'
assert_contains "$TEST_LOG" 'launchctl [root] <bootout> <system/com.github.runner-1>'

: > "$TEST_LOG"
provision --force-recreate || { cat "$TEST_CASE/output"; exit 1; }
assert_contains "$TEST_LOG" 'tar [gha-macos-1]'
assert_absent "$TEST_LOG" '<-create>'

: > "$TEST_LOG"
bootstrap --runner-user-prefix gha-macos --count 2 --launchd-scope daemon --uninstall-launchd
[ -d "$TEST_USERS/gha-macos-1/actions-runner" ]
[ -d "$TEST_DB/gha-macos-1" ]
[ ! -f "$TEST_CASE/daemons/com.github.runner-1.plist" ]
assert_absent "$TEST_LOG" '<-create>'
assert_absent "$TEST_LOG" '<-delete>'

new_case unrelated-account
mkdir -p "$TEST_DB/gha-macos-1"
echo 'Personal account' > "$TEST_DB/gha-macos-1/Comment"
expect_failure 'Refusing to reuse unrelated account' provision
assert_absent "$TEST_LOG" '<-create>'

new_case existing-home
mkdir -p "$TEST_USERS/gha-macos-1"
expect_failure 'Refusing to adopt existing home' provision
assert_absent "$TEST_LOG" '<-create>'

new_case privileged-account
provision
echo 'staff admin' > "$TEST_DB/gha-macos-1/groups"
expect_failure 'Runner account must not be privileged' provision

new_case changed-account
provision
echo /unexpected/home > "$TEST_DB/gha-macos-1/NFSHomeDirectory"
expect_failure 'Unexpected NFSHomeDirectory' provision

new_case visible-account
provision
echo 0 > "$TEST_DB/gha-macos-1/IsHidden"
expect_failure 'Unexpected IsHidden' provision

new_case duplicate-uid
provision
mkdir "$TEST_DB/unrelated"
echo 501 > "$TEST_DB/unrelated/UniqueID"
expect_failure 'Account uid is not unique' provision

new_case wrong-home-owner
provision
echo 0 > "$TEST_DB/gha-macos-1/home-owner"
: > "$TEST_LOG"
expect_failure 'Home is not owned by' provision
assert_absent "$TEST_LOG" 'sudo ['

new_case symlink-home
mkdir "$TEST_CASE/unrelated"
ln -s "$TEST_CASE/unrelated" "$TEST_USERS/gha-macos-1"
expect_failure 'Refusing to adopt existing home' provision

new_case invalid-options
expect_failure 'cannot be combined with --dir-prefix' provision --dir-prefix "$TEST_CASE/runner"
expect_failure 'cannot be combined with --launchd-user' provision --launchd-user existing
expect_failure 'requires --launchd-scope daemon' provision --launchd-scope agent
expect_failure 'standard' provision --launchd-dir "$TEST_CASE/untrusted"
expect_failure 'must start with a lowercase letter' provision --runner-user-prefix '../unsafe'
expect_failure 'at most 31 characters' provision --runner-user-prefix abcdefghijklmnopqrstuvwxyzabcd
expect_failure 'Invalid --launchd-label-prefix' provision --launchd-label-prefix '../unsafe'
expect_failure 'requires --install-launchd' bootstrap --runner-user-prefix gha-macos --count 1 --launchd-scope daemon
export TEST_UID=501
expect_failure 'requires root' provision
unset TEST_UID
export TEST_OS=Linux
expect_failure 'supported only on macOS' provision
unset TEST_OS
assert_absent "$TEST_LOG" '<-create>'
assert_absent "$TEST_LOG" 'curl ['

new_case legacy-agent
bootstrap --dir-prefix "$TEST_CASE/runner" --count 1 --repo owner/repo \
    --token fixture-token --version 1.2.3 --install-launchd --launchd-dir "$TEST_CASE/agents"
assert_contains "$TEST_CASE/agents/com.github.runner-1.plist" "<string>$TEST_CASE/runner-1/.home</string>"
assert_contains "$TEST_CASE/agents/com.github.runner-1.plist" "<string>$TEST_CASE/source/github-runner-wrapper.sh</string>"
assert_absent "$TEST_LOG" 'dscl ['
assert_absent "$TEST_LOG" 'sudo ['

new_case legacy-daemon
mkdir -p "$TEST_DB/existing"
echo "$TEST_CASE/existing-home" > "$TEST_DB/existing/NFSHomeDirectory"
bootstrap --dir-prefix "$TEST_CASE/runner" --count 1 --repo owner/repo \
    --token fixture-token --version 1.2.3 --install-launchd --launchd-scope daemon \
    --launchd-user existing --launchd-dir "$TEST_CASE/daemons"
assert_contains "$TEST_CASE/daemons/com.github.runner-1.plist" '<string>existing</string>'
assert_contains "$TEST_CASE/daemons/com.github.runner-1.plist" "<string>$TEST_CASE/runner-1/.home</string>"
assert_absent "$TEST_LOG" 'sudo ['
assert_absent "$TEST_LOG" '<-create>'

echo "PASS: account provisioning, reuse, replacement, teardown, refusal cases and legacy modes"
