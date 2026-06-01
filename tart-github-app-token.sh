#!/bin/bash
#
# tart-github-app-token.sh — Mint a short-lived GitHub Actions runner
# registration token from a GitHub App.
#
# Ephemeral VM runners need a *fresh* registration token on every boot. Rather
# than keeping a long-lived registration secret (or a broad PAT) on the host,
# we authenticate as a GitHub App: the host holds only the App's private key,
# and each iteration mints a token that lives for a few minutes.
#
# Flow:
#   1. Build a signed JWT (RS256) from the App private key + App ID (~9 min TTL).
#   2. Resolve the App installation for the target repo/org.
#   3. Exchange the JWT for a short-lived installation access token.
#   4. Use that token to request a runner registration token.
#
# The script can be run directly (prints the registration token to stdout) or
# sourced to call mint_registration_token directly.
#
# Required GitHub App permissions:
#   - Repository scope: "Administration: Read & write"
#   - Organization scope: "Self-hosted runners: Read & write"
#
# Usage:
#   tart-github-app-token.sh --app-id <id> --private-key <pem> \
#       (--repo <owner/repo> | --org <org>)
#
# Configuration may also come from the environment:
#   GH_APP_ID, GH_APP_PRIVATE_KEY, GH_RUNNER_REPO, GH_RUNNER_ORG

set -euo pipefail

# GitHub REST API base and the API version header value we pin against.
GITHUB_API_BASE="https://api.github.com"
GITHUB_API_VERSION="2022-11-28"

# JWT lifetime in seconds. GitHub rejects anything over 10 minutes; we use 9 to
# leave margin for host/GitHub clock skew.
JWT_TTL_SECONDS=540
# Backdate the issued-at claim to tolerate the host clock running slightly fast.
JWT_CLOCK_SKEW_SECONDS=60

# Base64url encoding (no padding), as required by the JWT spec.
base64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# Build and sign a JWT for the GitHub App.
make_app_jwt() {
    local app_id="$1"
    local private_key="$2"

    local now iat exp header payload signing_input signature
    now="$(date +%s)"
    iat=$(( now - JWT_CLOCK_SKEW_SECONDS ))
    exp=$(( now + JWT_TTL_SECONDS ))

    header='{"alg":"RS256","typ":"JWT"}'
    payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id")"

    signing_input="$(printf '%s' "$header" | base64url).$(printf '%s' "$payload" | base64url)"
    signature="$(printf '%s' "$signing_input" \
        | openssl dgst -sha256 -sign "$private_key" -binary \
        | base64url)"

    printf '%s.%s' "$signing_input" "$signature"
}

# Resolve the App installation id for the configured repo or org scope.
get_installation_id() {
    local jwt="$1" repo="$2" org="$3"
    local path

    if [ -n "$repo" ]; then
        path="/repos/${repo}/installation"
    else
        path="/orgs/${org}/installation"
    fi

    curl -fsS \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
        "${GITHUB_API_BASE}${path}" \
        | jq -r '.id'
}

# Exchange the App JWT for a short-lived installation access token.
get_installation_token() {
    local jwt="$1" installation_id="$2"

    curl -fsS -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
        "${GITHUB_API_BASE}/app/installations/${installation_id}/access_tokens" \
        | jq -r '.token'
}

# Request a runner registration token using an installation access token.
get_registration_token() {
    local token="$1" repo="$2" org="$3"
    local path

    if [ -n "$repo" ]; then
        path="/repos/${repo}/actions/runners/registration-token"
    else
        path="/orgs/${org}/actions/runners/registration-token"
    fi

    curl -fsS -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
        "${GITHUB_API_BASE}${path}" \
        | jq -r '.token'
}

# High-level helper: mint a registration token end to end.
# Args: app_id private_key_path repo org   (exactly one of repo/org non-empty)
mint_registration_token() {
    local app_id="$1" private_key="$2" repo="$3" org="$4"

    local jwt installation_id installation_token registration_token

    jwt="$(make_app_jwt "$app_id" "$private_key")"

    installation_id="$(get_installation_id "$jwt" "$repo" "$org")"
    if [ -z "$installation_id" ] || [ "$installation_id" = "null" ]; then
        echo "Failed to resolve GitHub App installation id" >&2
        return 1
    fi

    installation_token="$(get_installation_token "$jwt" "$installation_id")"
    if [ -z "$installation_token" ] || [ "$installation_token" = "null" ]; then
        echo "Failed to obtain installation access token" >&2
        return 1
    fi

    registration_token="$(get_registration_token "$installation_token" "$repo" "$org")"
    if [ -z "$registration_token" ] || [ "$registration_token" = "null" ]; then
        echo "Failed to obtain runner registration token" >&2
        return 1
    fi

    printf '%s\n' "$registration_token"
}

# When executed directly, parse arguments and print a registration token.
main() {
    local app_id="${GH_APP_ID:-}"
    local private_key="${GH_APP_PRIVATE_KEY:-}"
    local repo="${GH_RUNNER_REPO:-}"
    local org="${GH_RUNNER_ORG:-}"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --app-id) app_id="${2:-}"; shift 2 ;;
            --private-key) private_key="${2:-}"; shift 2 ;;
            --repo) repo="${2:-}"; shift 2 ;;
            --org) org="${2:-}"; shift 2 ;;
            -h|--help)
                grep '^#' "$0" | sed 's/^# \{0,1\}//'
                exit 0
                ;;
            *) echo "Unknown argument: $1" >&2; exit 1 ;;
        esac
    done

    for cmd in curl openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Required command not found: $cmd" >&2; exit 1; }
    done

    [ -n "$app_id" ] || { echo "ERROR: --app-id (or GH_APP_ID) is required." >&2; exit 1; }
    [ -n "$private_key" ] || { echo "ERROR: --private-key (or GH_APP_PRIVATE_KEY) is required." >&2; exit 1; }
    [ -f "$private_key" ] || { echo "ERROR: Private key file not found: $private_key" >&2; exit 1; }

    if { [ -n "$repo" ] && [ -n "$org" ]; } || { [ -z "$repo" ] && [ -z "$org" ]; }; then
        echo "ERROR: Provide exactly one of --repo or --org." >&2
        exit 1
    fi

    mint_registration_token "$app_id" "$private_key" "$repo" "$org"
}

# Only run main when executed directly, so the file can also be sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
