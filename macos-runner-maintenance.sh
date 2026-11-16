#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR='/Library/Application Support/github-runner-macos'
WRAPPER="$SERVICE_DIR/github-runner-wrapper.sh"
PLIST_DIR='/Library/LaunchDaemons'
PLIST_BUDDY='/usr/libexec/PlistBuddy'

die() {
    echo "ERROR: $*" >&2
    exit 1
}

mode="${1:---list}"
required_labels="${2-hvf}"
HEALTH_ATTEMPTS=30
HEALTH_RETRY_SECONDS=2
[[ $# -le 2 && ($# -le 1 || "$mode" == --repair-drained) ]] || die 'Only --repair-drained accepts a required-label CSV.'
case "$mode" in
    --list | --install-only | --repair-drained) ;;
    *) die 'Usage: macos-runner-maintenance.sh [--list | --install-only | --repair-drained [required-labels-csv]]' ;;
esac
[[ "$(uname -s)" == Darwin ]] || die 'Run this on the macOS runner host.'
if [[ "$(id -u)" != 0 ]]; then
    exec sudo /bin/bash "$SCRIPT_DIR/macos-runner-maintenance.sh" "$@"
fi

disabled_services="$(launchctl print-disabled system)" || die 'Cannot read disabled system services.'
labels=()
plists=()
loaded_states=()
accounts=()
homes=()
runner_dirs=()
found=0

read_key() {
    "$PLIST_BUDDY" -c "Print :$2" "$1"
}

for plist in "$PLIST_DIR"/*.plist; do
    [[ -f "$plist" ]] || continue
    wrapper="$(read_key "$plist" ProgramArguments:3 2>/dev/null)" || continue
    [[ "$wrapper" == "$WRAPPER" ]] || continue
    label="$(read_key "$plist" Label)" || die "Missing service label: $plist"
    [[ "$label" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid service label: $plist"
    account="$(read_key "$plist" UserName)" || die "Missing service account: $plist"
    home="$(read_key "$plist" EnvironmentVariables:HOME)" || die "Missing runner home: $plist"
    runner_dir="$(read_key "$plist" ProgramArguments:4)" || die "Missing runner directory: $plist"
    stdout="$(read_key "$plist" StandardOutPath)" || die "Missing stdout path: $plist"
    stderr="$(read_key "$plist" StandardErrorPath)" || die "Missing stderr path: $plist"
    [[ -n "$account" && "$account" != root && "$home" == /* && "$runner_dir" == /* ]] ||
        die "Unsafe runner identity or paths: $plist"
    found=$((found + 1))
    loaded=no
    if launchctl print "system/$label" >/dev/null 2>&1; then
        loaded=yes
    fi
    disabled="$(read_key "$plist" Disabled 2>/dev/null)" || disabled=false
    override="$(printf '%s\n' "$disabled_services" | awk -F '"' -v label="$label" '
        $2 == label && $3 ~ /=>[[:space:]]*true/ { print "true" }
        $2 == label && $3 ~ /=>[[:space:]]*false/ { print "false" }
    ')"
    [[ -z "$override" ]] || disabled="$override"
    enabled=yes
    if [[ "$disabled" == true ]]; then
        enabled=no
    fi
    printf '%s: account=%s loaded=%s enabled=%s\n' "$label" "$account" "$loaded" "$enabled"
    printf '  HOME=%s\n  runner=%s\n  stdout=%s\n  stderr=%s\n' "$home" "$runner_dir" "$stdout" "$stderr"
    printf '  Lock inspection: sudo -H -u %q /usr/bin/env %q /bin/bash -c %q\n' \
        "$account" "HOME=$home" 'lsof +D "$HOME/.homebrew/var/homebrew/locks"'
    [[ "$enabled" == yes ]] || continue
    labels+=("$label")
    plists+=("$plist")
    loaded_states+=("$loaded")
    accounts+=("$account")
    homes+=("$home")
    runner_dirs+=("$runner_dir")
done

[[ "$found" -gt 0 ]] || die "No managed macOS runner daemons found in $PLIST_DIR."
[[ "$mode" != --list ]] || exit 0
[[ "${#labels[@]}" -gt 0 ]] || die 'No enabled macOS runner daemons; nothing changed.'

gh_api() {
    sudo -n -H -u "$SUDO_USER" "$gh_bin" api --hostname github.com "$@"
}

verify_github_runner() {
    local endpoint="$1" expected_name="$2" state="${3:-online}" runner
    runner="$(gh_api "$endpoint")" || return 1
    printf '%s\n' "$runner" | jq -e --arg name "$expected_name" --arg state "$state" '
        .name == $name and ($state == "any" or .status == $state) and .busy == false and
        ([.labels[].name | ascii_downcase] | contains(["self-hosted", "macos", "arm64"]))
    ' >/dev/null
}

if [[ "$mode" == --repair-drained ]]; then
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
    command -v jq >/dev/null || die 'Install jq on the Mac before repairing runners.'
    gh_bin="$(command -v gh)" || die 'Install GitHub CLI (gh) on the Mac before repairing runners.'
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || die 'Run as the administrator who uses GitHub CLI; the command handles sudo itself.'
    sudo -n -H -u "$SUDO_USER" "$gh_bin" auth status --hostname github.com >/dev/null 2>&1 ||
        die 'GitHub authentication is unavailable. Run gh auth login as your administrator account, then retry.'
    endpoints=()
    runner_names=()
    payloads=()
    initial_labels=()
    for ((index = 0; index < ${#labels[@]}; index++)); do
        runner_dir="${runner_dirs[$index]}"
        expected="$required_labels"
        if [[ -f "$runner_dir/.configured-labels" ]]; then
            expected="$(cat "$runner_dir/.configured-labels")"
        fi
        payload="$(jq -cn --arg labels "$expected" '{labels: ($labels | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | unique)}')"
        registration="$runner_dir/.runner"
        runner_id="$(jq -er '.agentId | numbers | select(. > 0 and floor == .)' "$registration")" || die "Invalid runner ID: $registration"
        runner_name="$(jq -er '.agentName | strings | select(length > 0)' "$registration")" || die "Missing runner name: $registration"
        github_url="$(jq -er '.gitHubUrl // .githubUrl' "$registration")" || die "Missing GitHub target: $registration"
        [[ "$github_url" =~ ^https://github\.com/([a-zA-Z0-9_.-]+)(/([a-zA-Z0-9_.-]+))?/?$ ]] || die "Unsupported GitHub target: $github_url"
        owner="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[3]}"
        endpoint="orgs/$owner/actions/runners/$runner_id"
        [[ -z "$repo" ]] || endpoint="repos/$owner/$repo/actions/runners/$runner_id"
        verify_github_runner "$endpoint" "$runner_name" any || die "Runner must not be busy and must match its registration and self-hosted/macOS/ARM64 labels: $runner_name"
        endpoints+=("$endpoint")
        runner_names+=("$runner_name")
        payloads+=("$payload")
        initial_labels+=("$expected")
    done
fi

[[ -d "$SERVICE_DIR" && ! -L "$SERVICE_DIR" && "$(stat -f %u "$SERVICE_DIR")" == 0 ]] ||
    die 'Service directory must be a root-owned directory, not a symlink.'
[[ ! -L "$WRAPPER" ]] || die 'Refusing a symlinked service wrapper.'
/usr/bin/install -o root -g wheel -m 755 "$SCRIPT_DIR/github-runner-wrapper.sh" "$WRAPPER"
echo 'Installed persistent LLVM startup check for managed macOS runner daemons.'
[[ "$mode" != --install-only ]] || exit 0

failed=0
for ((index = 0; index < ${#labels[@]}; index++)); do
    target="system/${labels[$index]}"
    if ! verify_github_runner "${endpoints[$index]}" "${runner_names[$index]}" any; then
        echo "ERROR: Runner state changed before restart: $target" >&2
        failed=1
        continue
    fi
    if [[ "${loaded_states[$index]}" == yes ]]; then
        if ! launchctl kickstart -k "$target"; then
            echo "ERROR: Restart failed: $target" >&2
            failed=1
            continue
        fi
    elif ! launchctl bootstrap system "${plists[$index]}"; then
        echo "ERROR: Start failed: $target" >&2
        failed=1
        continue
    fi
    echo "Restart/start requested: $target"
done
[[ "$failed" == 0 ]] || die 'Some services could not restart; no scheduling labels restored.'

for ((index = 0; index < ${#labels[@]}; index++)); do
    for ((attempt = 1; attempt <= HEALTH_ATTEMPTS; attempt++)); do
        if verify_github_runner "${endpoints[$index]}" "${runner_names[$index]}"; then
            break
        fi
        [[ "$attempt" -lt "$HEALTH_ATTEMPTS" ]] || die "Runner did not become online and idle; no scheduling labels restored: ${runner_names[$index]}"
        sleep "$HEALTH_RETRY_SECONDS"
    done
    sudo -n -H -u "${accounts[$index]}" /usr/bin/env -i HOME="${homes[$index]}" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -c \
        'test -x "$HOME/.homebrew/bin/clang" && test "$HOME/.homebrew/bin/clang" -ef "$HOME/.homebrew/opt/llvm/bin/clang" && "$HOME/.homebrew/opt/llvm/bin/clang" --version' ||
        die "LLVM verification failed; no scheduling labels restored: ${runner_names[$index]}"
done

for ((index = 0; index < ${#labels[@]}; index++)); do
    if ! verify_github_runner "${endpoints[$index]}" "${runner_names[$index]}"; then
        echo "ERROR: Runner is no longer online and idle: ${runner_names[$index]}" >&2
        failed=1
        continue
    fi
    if ! response="$(printf '%s\n' "${payloads[$index]}" | gh_api --method POST "${endpoints[$index]}/labels" --input -)" ||
        ! printf '%s\n' "$response" | jq -e --argjson expected "${payloads[$index]}" '
            ([.labels[].name | ascii_downcase]) as $actual |
            (($expected.labels + ["self-hosted", "macOS", "ARM64"]) | all(.[]; ascii_downcase as $name | $actual | index($name) != null))
        ' >/dev/null; then
        echo "ERROR: Label restoration or verification failed: ${runner_names[$index]}" >&2
        failed=1
        continue
    fi
    sudo -n -H -u "${accounts[$index]}" /bin/bash -c 'umask 077; printf "%s\n" "$2" > "$1"' \
        bash "${runner_dirs[$index]}/.configured-labels" "${initial_labels[$index]}" || die 'Could not save the verified label baseline.'
    echo "Repaired ${runner_names[$index]}; required labels restored, other GitHub labels preserved."
done
exit "$failed"
