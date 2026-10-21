#!/bin/bash
#
# Bootstrap multiple GitHub Actions runners on macOS.
#
# Creates numbered runner directories from a prefix, downloads the latest
# runner archive once, extracts into each directory, and runs config.sh.
#
# Examples:
#   bash bootstrap-gh-runners.sh \
#     --dir-prefix "$HOME/github-runner" \
#     --count 2 \
#     --repo owner/repo \
#     --token "<registration-token>"
#
#   bash bootstrap-gh-runners.sh \
#     --dir-prefix "$HOME/github-runner" \
#     --count 2 \
#     --org my-org \
#     --token "<registration-token>" \
#     --labels "mini"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  bootstrap-gh-runners.sh --dir-prefix <path-prefix> --count <N> [--repo <owner/repo> | --org <org> | --url <https://github.com/...>] --token <registration-token> [options]
  sudo bootstrap-gh-runners.sh --runner-user-prefix <prefix> --count <N> [target and token options] --install-launchd --launchd-scope daemon

Required:
  --dir-prefix <path-prefix>   Directory prefix. Script creates <prefix>-1 .. <prefix>-N.
                               Omit with --runner-user-prefix.
  --count <N>                  Number of runners to create.
  Registration token, one of:
    --token <token>            GitHub runner registration token.
    --token-file <path>        Read the token from a file (keeps it out of shell
                               history and argv; recommended).
  One of:
    --repo <owner/repo>        Repository runner target.
    --org <org>                Organization runner target.
    --url <url>                Explicit target URL (repo or org).

Optional:
    --labels <csv>               Custom labels for all runners. Default: "hvf".
                                                             GitHub adds self-hosted, macOS, and ARM64 automatically.
  --runner-group <name>        Runner group name (org/enterprise scopes only).
  --name-prefix <prefix>       Runner name prefix. Default: "$(hostname -s)-runner".
  --runner-user-prefix <p>     Opt in to creating non-admin accounts <p>-1 .. <p>-N.
                               Requires root, --install-launchd and daemon scope.
                               Uses /Users/<account>/actions-runner and the account's
                               real home. Cannot combine with --dir-prefix or
                               --launchd-user. Existing unrelated accounts are refused.
                               Uninstall removes services, not accounts or their data.
  Existing configured runners are skipped unless --replace or --force-recreate is used.
  --replace                    Pass --replace to config.sh (recommended).
  --force-recreate             Delete existing runner directories before install.
  --install-launchd            Install/reload launchd services for all 1..N runners.
  --uninstall-launchd          Stop and remove launchd services for 1..N, then exit.
                               Use sudo to also remove system daemon plists.
    --launchd-scope <scope>      launchd scope: agent|daemon. Default: agent.
    --launchd-user <user>        User account for daemon scope. Default: current user.
    --launchd-dir <dir>          Directory for plist files.
                                                             Defaults: ~/Library/LaunchAgents (agent),
                                                                                 /Library/LaunchDaemons (daemon).
  --launchd-label-prefix <p>   launchd label prefix. Default: com.github.runner.
    --launch-agents-dir <dir>    Back-compat alias for --launchd-dir.
  --version <x.y.z>            Runner version. Default: latest release.
  -h, --help                   Show this help.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

run_as_runner() {
    if [ -n "$RUNNER_USER_PREFIX" ]; then
        sudo -H -u "$LAUNCHD_USER" /usr/bin/env -i \
            HOME="$RUNNER_HOME" USER="$LAUNCHD_USER" LOGNAME="$LAUNCHD_USER" \
            PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@"
    else
        "$@"
    fi
}

run_in_runner_dir() {
    local runner_dir="$1"
    shift
    run_as_runner /bin/bash -c 'cd "$1" && shift && exec "$@"' bash "$runner_dir" "$@"
}

read_account_attribute() {
    # dscl can put a value on the next line, indented, even for one value.
    dscl . -read "$1" "$2" | awk '
        NR == 1 { sub(/^[^:]+:[[:space:]]*/, "") }
        { sub(/^[[:space:]]+/, ""); if (length) print }
    '
}

ensure_runner_account() {
    local user="$LAUNCHD_USER"
    local record="/Users/${user}"
    local marker="Managed by bootstrap-gh-runners.sh (${user})"
    local uid groups attribute expected actual

    if dscl . -read "$record" >/dev/null 2>&1; then
        actual="$(read_account_attribute "$record" Comment)"
        [ "$actual" = "$marker" ] || die "Refusing to reuse unrelated account: $user"
    else
        [ ! -e "$RUNNER_HOME" ] && [ ! -L "$RUNNER_HOME" ] \
            || die "Refusing to adopt existing home: $RUNNER_HOME"
        uid="$(dscl . -list /Users UniqueID | awk 'BEGIN { max = 500 } $2 > max { max = $2 } END { print max + 1 }')"
        echo "Creating non-admin service account: $user (uid $uid)"
        dscl . -create "$record"
        dscl . -create "$record" UniqueID "$uid"
        dscl . -create "$record" PrimaryGroupID 20
        dscl . -create "$record" NFSHomeDirectory "$RUNNER_HOME"
        dscl . -create "$record" UserShell /usr/bin/false
        dscl . -create "$record" RealName "GitHub Actions runner $user"
        dscl . -create "$record" IsHidden 1
        dscl . -create "$record" Password '*'
        mkdir -m 700 "$RUNNER_HOME"
        chown "$user:staff" "$RUNNER_HOME"
        # Mark only fully provisioned accounts; partial failures need operator review.
        dscl . -create "$record" Comment "$marker"
    fi

    uid="$(id -u "$user")"
    [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 501 ] || die "Unsafe uid for account: $user"
    [ "$(dscl . -list /Users UniqueID | awk -v uid="$uid" '$2 == uid { n++ } END { print n+0 }')" -eq 1 ] \
        || die "Account uid is not unique: $user"
    for attribute in NFSHomeDirectory PrimaryGroupID UserShell IsHidden Password; do
        case "$attribute" in
            NFSHomeDirectory) expected="$RUNNER_HOME" ;;
            PrimaryGroupID) expected=20 ;;
            UserShell) expected=/usr/bin/false ;;
            IsHidden) expected=1 ;;
            Password) expected='*' ;;
        esac
        actual="$(read_account_attribute "$record" "$attribute")"
        [ "$actual" = "$expected" ] || die "Unexpected $attribute for managed account: $user"
    done
    groups="$(id -Gn "$user")"
    case " $groups " in
        *" admin "*|*" wheel "*) die "Runner account must not be privileged: $user" ;;
    esac
    [ -d "$RUNNER_HOME" ] && [ ! -L "$RUNNER_HOME" ] || die "Unsafe or missing home: $RUNNER_HOME"
    [ "$(stat -f %u "$RUNNER_HOME")" = "$uid" ] || die "Home is not owned by $user: $RUNNER_HOME"
    run_as_runner chmod 700 "$RUNNER_HOME"
}

install_service_scripts() {
    SERVICE_SCRIPT_DIR="/Library/Application Support/github-runner-macos"
    [ ! -L "$SERVICE_SCRIPT_DIR" ] || die "Service script directory must not be a symlink."
    if [ -e "$SERVICE_SCRIPT_DIR" ]; then
        [ -d "$SERVICE_SCRIPT_DIR" ] && [ "$(stat -f %u "$SERVICE_SCRIPT_DIR")" = 0 ] \
            || die "Service script directory must be a root-owned directory."
    fi
    mkdir -p "$SERVICE_SCRIPT_DIR"
    chown root:wheel "$SERVICE_SCRIPT_DIR"
    chmod 755 "$SERVICE_SCRIPT_DIR"
    local script
    for script in github-runner-wrapper.sh github-runner-cleanup.sh; do
        [ ! -L "$SERVICE_SCRIPT_DIR/$script" ] || die "Service script must not be a symlink: $script"
        cp "$SCRIPT_DIR/$script" "$SERVICE_SCRIPT_DIR/$script"
        chown root:wheel "$SERVICE_SCRIPT_DIR/$script"
        chmod 755 "$SERVICE_SCRIPT_DIR/$script"
    done
}

set_or_replace_env_var() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    if run_as_runner grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # NOTE: BSD/macOS sed requires the empty '' argument after -i. This
        # script targets macOS only; GNU sed would drop the ''.
        run_as_runner sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        run_as_runner /bin/bash -c 'printf "%s=%s\n" "$2" "$3" >> "$1"' bash "$env_file" "$key" "$value"
    fi
}

# Install the canonical post-job cleanup hook into a runner directory and wire
# it up via ACTIONS_RUNNER_HOOK_JOB_COMPLETED. We copy the single source-of-truth
# script (github-runner-cleanup.sh) rather than duplicating its body here.
configure_job_completed_hook() {
    local runner_dir="$1"
    local env_file="$runner_dir/.env"
    local hook_wrapper="$runner_dir/job-completed-hook.sh"

    run_as_runner cp "$SERVICE_SCRIPT_DIR/github-runner-cleanup.sh" "$hook_wrapper"
    run_as_runner chmod +x "$hook_wrapper"
    run_as_runner touch "$env_file"
    set_or_replace_env_var "$env_file" "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "$hook_wrapper"
}

install_launchd_service() {
    local runner_index="$1"
    local runner_dir="$2"
    local label="${LAUNCHD_LABEL_PREFIX}-${runner_index}"
    local plist_dest="${LAUNCHD_DIR}/${label}.plist"
    local log_base="${RUNNER_HOME}/.github-runner-logs/runner-${runner_index}"
    local isolated_home="${runner_dir}/.home"
    local user_block=""
    local identity_env_block=""
    local runner_path="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    if [ -n "$RUNNER_USER_PREFIX" ]; then
        isolated_home="$RUNNER_HOME"
        runner_path="/opt/homebrew/bin:${runner_path}"
        identity_env_block=$(cat <<EOF
        <key>USER</key>
        <string>${LAUNCHD_USER}</string>
        <key>LOGNAME</key>
        <string>${LAUNCHD_USER}</string>
EOF
)
    fi

    if [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        user_block=$(cat <<EOF
    <key>UserName</key>
    <string>${LAUNCHD_USER}</string>
EOF
)
    fi

    mkdir -p "$LAUNCHD_DIR"
    run_as_runner mkdir -p "${RUNNER_HOME}/.github-runner-logs" "$isolated_home"
    if [ -n "$RUNNER_USER_PREFIX" ]; then
        run_as_runner chmod 700 "${RUNNER_HOME}/.github-runner-logs"
    elif [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        chown "$LAUNCHD_USER" "$isolated_home"
    fi
    chmod +x "$SERVICE_SCRIPT_DIR/github-runner-wrapper.sh"

    cat > "$plist_dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>

${user_block}

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-is</string>
        <string>/bin/bash</string>
        <string>${SERVICE_SCRIPT_DIR}/github-runner-wrapper.sh</string>
        <string>${runner_dir}</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardOutPath</key>
    <string>${log_base}-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${log_base}-stderr.log</string>

    <key>WorkingDirectory</key>
    <string>${runner_dir}</string>

    <key>EnvironmentVariables</key>
    <dict>
${identity_env_block}
        <key>PATH</key>
        <string>${runner_path}</string>
        <key>HOME</key>
        <string>${isolated_home}</string>
        <key>RUNNER_LOG_DIR</key>
        <string>${RUNNER_HOME}/.github-runner-logs</string>
        <key>GH_WRAPPER_FAILURE_WINDOW_SEC</key>
        <string>600</string>
        <key>GH_WRAPPER_FAILURE_THRESHOLD</key>
        <string>5</string>
        <key>GH_WRAPPER_FAILURE_COOLDOWN_SEC</key>
        <string>180</string>
    </dict>
</dict>
</plist>
EOF

    if [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        chown root:wheel "$plist_dest"
    fi
    chmod 644 "$plist_dest"

    if [ "$LAUNCHD_SCOPE" = "daemon" ]; then
        launchctl bootout "system/${label}" >/dev/null 2>&1 || true
        launchctl bootstrap system "$plist_dest"
        launchctl enable "system/${label}" >/dev/null 2>&1 || true
    else
        if launchctl list "$label" >/dev/null 2>&1; then
            launchctl unload "$plist_dest" || true
        fi
        launchctl load "$plist_dest"
    fi

    echo "launchd service ready: $label"
}

# Stop a runner's launchd job in both agent and daemon scopes (best effort).
# Leaves the plist in place; used before recreating/reconfiguring so the running
# process releases the directory and server-side registration.
stop_launchd_job() {
    local runner_index="$1"
    local label="${LAUNCHD_LABEL_PREFIX}-${runner_index}"
    local uid agent_plist
    uid="$(id -u)"
    agent_plist="$HOME/Library/LaunchAgents/${label}.plist"

    launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || true
    [ -f "$agent_plist" ] && launchctl unload "$agent_plist" >/dev/null 2>&1 || true
    launchctl bootout "system/${label}" >/dev/null 2>&1 || true
}

# Stop and delete a runner's launchd service (plist) in both scopes. Daemon
# (system) plists require root; those are skipped with a warning otherwise.
remove_launchd_service() {
    local runner_index="$1"
    local label="${LAUNCHD_LABEL_PREFIX}-${runner_index}"
    local agent_plist="$HOME/Library/LaunchAgents/${label}.plist"
    local daemon_plist="/Library/LaunchDaemons/${label}.plist"
    local found=false

    stop_launchd_job "$runner_index"

    if [ -f "$agent_plist" ]; then
        rm -f "$agent_plist"
        found=true
    fi

    if [ -f "$daemon_plist" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            rm -f "$daemon_plist"
            found=true
        else
            echo "WARN: $daemon_plist needs root to remove; re-run with sudo."
        fi
    fi

    if [ "$found" = true ]; then
        echo "launchd service removed: $label"
    fi
}

DIR_PREFIX=""
COUNT=""
TOKEN=""
TOKEN_FILE=""
TARGET_URL=""
REPO=""
ORG=""
LABELS="hvf"
RUNNER_GROUP=""
NAME_PREFIX="$(hostname -s)-runner"
REPLACE=false
FORCE_RECREATE=false
VERSION=""
INSTALL_LAUNCHD=false
UNINSTALL_LAUNCHD=false
LAUNCHD_LABEL_PREFIX="com.github.runner"
LAUNCHD_SCOPE="agent"
LAUNCHD_USER="${SUDO_USER:-$USER}"
LAUNCHD_DIR=""
RUNNER_HOME=""
RUNNER_USER_PREFIX=""
LAUNCHD_USER_EXPLICIT=false
SERVICE_SCRIPT_DIR="$SCRIPT_DIR"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir-prefix)
            DIR_PREFIX="${2:-}"
            shift 2
            ;;
        --count)
            COUNT="${2:-}"
            shift 2
            ;;
        --token)
            TOKEN="${2:-}"
            shift 2
            ;;
        --token-file)
            TOKEN_FILE="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --org)
            ORG="${2:-}"
            shift 2
            ;;
        --url)
            TARGET_URL="${2:-}"
            shift 2
            ;;
        --labels)
            LABELS="${2:-}"
            shift 2
            ;;
        --runner-group)
            RUNNER_GROUP="${2:-}"
            shift 2
            ;;
        --name-prefix)
            NAME_PREFIX="${2:-}"
            shift 2
            ;;
        --runner-user-prefix)
            RUNNER_USER_PREFIX="${2:-}"
            [ -n "$RUNNER_USER_PREFIX" ] || die "--runner-user-prefix requires a value."
            shift 2
            ;;
        --replace)
            REPLACE=true
            shift
            ;;
        --force-recreate)
            FORCE_RECREATE=true
            shift
            ;;
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --install-launchd)
            INSTALL_LAUNCHD=true
            shift
            ;;
        --uninstall-launchd)
            UNINSTALL_LAUNCHD=true
            shift
            ;;
        --launchd-scope)
            LAUNCHD_SCOPE="${2:-}"
            shift 2
            ;;
        --launchd-user)
            LAUNCHD_USER="${2:-}"
            LAUNCHD_USER_EXPLICIT=true
            shift 2
            ;;
        --launchd-dir)
            LAUNCHD_DIR="${2:-}"
            shift 2
            ;;
        --launchd-label-prefix)
            LAUNCHD_LABEL_PREFIX="${2:-}"
            shift 2
            ;;
        --launch-agents-dir)
            LAUNCHD_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Resolve the registration token from --token-file if provided. Reading it from
# a file keeps the secret out of shell history and this script's argv.
if [ -n "$TOKEN_FILE" ]; then
    [ -f "$TOKEN_FILE" ] || { echo "ERROR: --token-file not found: $TOKEN_FILE"; exit 1; }
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

if { [ -z "$DIR_PREFIX" ] && [ -z "$RUNNER_USER_PREFIX" ]; } || [ -z "$COUNT" ]; then
    echo "ERROR: --dir-prefix and --count are required."
    usage
    exit 1
fi

if [ -n "$RUNNER_USER_PREFIX" ]; then
    [[ "$RUNNER_USER_PREFIX" =~ ^[a-z][a-z0-9_-]*$ ]] \
        || die "--runner-user-prefix must start with a lowercase letter and contain only lowercase letters, digits, '_' or '-'."
    [ "${#RUNNER_USER_PREFIX}" -le $((30 - ${#COUNT})) ] \
        || die "Runner account names must be at most 31 characters."
    [ -z "$DIR_PREFIX" ] || die "--runner-user-prefix cannot be combined with --dir-prefix."
    [ "$LAUNCHD_USER_EXPLICIT" = false ] || die "--runner-user-prefix cannot be combined with --launchd-user."
    [ "$LAUNCHD_SCOPE" = daemon ] || die "--runner-user-prefix requires --launchd-scope daemon."
    [ "$(uname -s)" = Darwin ] || die "--runner-user-prefix is supported only on macOS."
    [ "$(id -u)" -eq 0 ] || die "--runner-user-prefix requires root. Re-run with sudo."
    [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="/Library/LaunchDaemons"
    # Keep daemon definitions outside runner-controlled directories.
    [ "$LAUNCHD_DIR" = /Library/LaunchDaemons ] \
        || die "--runner-user-prefix requires the standard /Library/LaunchDaemons directory."
    [[ "$LAUNCHD_LABEL_PREFIX" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] \
        || die "Invalid --launchd-label-prefix."
    if [ "$UNINSTALL_LAUNCHD" = false ]; then
        [ "$INSTALL_LAUNCHD" = true ] || die "--runner-user-prefix requires --install-launchd."
    fi
fi

if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ]; then
    echo "ERROR: --count must be a positive integer."
    exit 1
fi

# Dedicated teardown mode: stop and remove launchd services, then exit. No token
# or target is needed since nothing is being registered.
if [ "$UNINSTALL_LAUNCHD" = true ]; then
    echo "Uninstalling launchd services for runners 1..$COUNT (label prefix: $LAUNCHD_LABEL_PREFIX)"
    for i in $(seq 1 "$COUNT"); do
        remove_launchd_service "$i"
    done
    echo "launchd teardown complete."
    exit 0
fi

if [ -z "$TOKEN" ]; then
    echo "ERROR: A registration token is required (use --token or --token-file)."
    usage
    exit 1
fi

target_selector_count=0
[ -n "$TARGET_URL" ] && target_selector_count=$((target_selector_count + 1))
[ -n "$REPO" ] && target_selector_count=$((target_selector_count + 1))
[ -n "$ORG" ] && target_selector_count=$((target_selector_count + 1))

if [ "$target_selector_count" -ne 1 ]; then
    echo "ERROR: Provide exactly one of --repo, --org, or --url."
    exit 1
fi

if [ -n "$REPO" ]; then
    TARGET_URL="https://github.com/$REPO"
elif [ -n "$ORG" ]; then
    TARGET_URL="https://github.com/$ORG"
fi

resolve_launchd_layout() {
    case "$LAUNCHD_SCOPE" in
        agent)
            RUNNER_HOME="$HOME"
            [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="$HOME/Library/LaunchAgents"
            ;;
        daemon)
            [ "$(id -u)" -eq 0 ] || { echo "ERROR: --launchd-scope daemon requires root. Re-run with sudo."; exit 1; }
            [ -n "$LAUNCHD_USER" ] || { echo "ERROR: --launchd-user is required for daemon scope."; exit 1; }
            RUNNER_HOME="$(dscl . -read "/Users/${LAUNCHD_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
            [ -n "$RUNNER_HOME" ] || RUNNER_HOME="/Users/${LAUNCHD_USER}"
            [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="/Library/LaunchDaemons"
            ;;
        *)
            echo "ERROR: --launchd-scope must be one of: agent, daemon"
            exit 1
            ;;
    esac
}

if [ "$INSTALL_LAUNCHD" = true ] && [ -z "$RUNNER_USER_PREFIX" ]; then
    resolve_launchd_layout
fi

for cmd in curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64) RUNNER_ARCH="x64" ;;
    arm64) RUNNER_ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -n 1)"
fi

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not determine runner version."
    exit 1
fi

ARCHIVE_NAME="actions-runner-osx-${RUNNER_ARCH}-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${VERSION}/${ARCHIVE_NAME}"

TMP_DIR="$(mktemp -d)"
cleanup_tmp() {
    rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

echo "Using target URL: $TARGET_URL"
echo "Using runner version: $VERSION"
if [ "$INSTALL_LAUNCHD" = true ]; then
    echo "launchd: scope=${LAUNCHD_SCOPE}, dir=${LAUNCHD_DIR}, user=${LAUNCHD_USER}"
fi
echo "Downloading: $DOWNLOAD_URL"
curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE_NAME"

if [ -n "$RUNNER_USER_PREFIX" ]; then
    # Only the public runner archive lives here; service accounts must read it.
    chmod 755 "$TMP_DIR"
    chmod 644 "$TMP_DIR/$ARCHIVE_NAME"
    install_service_scripts
fi

for i in $(seq 1 "$COUNT"); do
    if [ -n "$RUNNER_USER_PREFIX" ]; then
        LAUNCHD_USER="${RUNNER_USER_PREFIX}-${i}"
        RUNNER_HOME="/Users/${LAUNCHD_USER}"
        ensure_runner_account
        runner_dir="${RUNNER_HOME}/actions-runner"
    else
        runner_dir="${DIR_PREFIX}-${i}"
    fi
    runner_name="${NAME_PREFIX}-${i}"
    configured_now=false

    echo ""
    echo "==> Provisioning $runner_dir"

    # Stop any running launchd job for this index before recreating or
    # reconfiguring, so its process releases the directory and registration.
    if [ "$FORCE_RECREATE" = true ] || [ "$REPLACE" = true ]; then
        stop_launchd_job "$i"
    fi

    if [ -d "$runner_dir" ] && [ "$FORCE_RECREATE" = true ]; then
        echo "Removing existing directory: $runner_dir"
        run_as_runner rm -rf "$runner_dir"
    fi

    run_as_runner mkdir -p "$runner_dir"
    if [ -n "$RUNNER_USER_PREFIX" ]; then
        run_as_runner chmod 700 "$runner_dir"
    fi

    if [ -f "$runner_dir/config.sh" ]; then
        echo "Runner files already present in $runner_dir"
    else
        run_as_runner tar -xzf "$TMP_DIR/$ARCHIVE_NAME" -C "$runner_dir"
    fi

    if [ -f "$runner_dir/.runner" ] && [ "$REPLACE" = false ] && [ "$FORCE_RECREATE" = false ]; then
        echo "Runner already configured in $runner_dir (skipping; use --replace to reconfigure)"
        configure_job_completed_hook "$runner_dir"
    else
        # config.sh refuses to reconfigure a directory that still holds a local
        # .runner, even with --replace (that flag only replaces the server-side
        # registration). When --replace is requested, tear down the stale local
        # config first so a fresh token can reconfigure cleanly.
        if [ "$REPLACE" = true ] && [ -f "$runner_dir/.runner" ]; then
            echo "Removing stale local runner config in $runner_dir"
            run_in_runner_dir "$runner_dir" ./config.sh remove --token "$TOKEN" >/dev/null 2>&1 \
                || run_as_runner rm -f "$runner_dir/.runner" "$runner_dir/.credentials" "$runner_dir/.credentials_rsaparams"
        fi

        config_args=(
            --unattended
            --url "$TARGET_URL"
            --token "$TOKEN"
            --name "$runner_name"
        )

        # --replace is also required after --force-recreate: the local dir was
        # wiped without deregistering, so the same-named runner still exists
        # server-side and config.sh would otherwise refuse to register it.
        if [ "$REPLACE" = true ] || [ "$FORCE_RECREATE" = true ]; then
            config_args+=(--replace)
        fi

        if [ -n "$LABELS" ]; then
            config_args+=(--labels "$LABELS")
        fi

        if [ -n "$RUNNER_GROUP" ]; then
            config_args+=(--runnergroup "$RUNNER_GROUP")
        fi

        run_in_runner_dir "$runner_dir" ./config.sh "${config_args[@]}"

        configure_job_completed_hook "$runner_dir"
        configured_now=true
    fi

    if [ "$INSTALL_LAUNCHD" = true ]; then
        install_launchd_service "$i" "$runner_dir"
    fi

    if [ "$configured_now" = true ]; then
        echo "Configured runner: $runner_name"
    fi
done

echo ""
echo "Provisioning complete."
if [ "$INSTALL_LAUNCHD" = true ]; then
    echo "launchd services installed/reloaded for runners 1..$COUNT"
else
    echo "Next step: re-run with --install-launchd to install the launchd services."
fi
