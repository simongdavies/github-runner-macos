#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: bash $0 [--dry-run] /path/to/ci-setup-workflow" >&2
    exit 2
}

dry_run=false
if [ "${1:-}" = "--dry-run" ]; then
    dry_run=true
    shift
fi
[ "$#" -eq 1 ] || usage
candidate="$(cd "$1" && pwd)"

# Use macOS's bundled YAML parser rather than copying the repair logic here.
prerequisite="$(ruby -ryaml -e '
    action = YAML.safe_load(File.read(ARGV.fetch(0)))
    abort "Expected a composite action" unless action.dig("runs", "using") == "composite"
    steps = action.fetch("runs").fetch("steps").select do |step|
        step["name"] == "Ensure Homebrew is available (macOS)"
    end
    abort "Expected exactly one Homebrew prerequisite step" unless steps.length == 1
    step = steps.first
    unsupported = step.keys - %w[name if run shell]
    abort "Unsupported Homebrew step fields: #{unsupported.join(", ")}" unless unsupported.empty?
    abort "Expected shell: bash" unless step["shell"] == "bash"
    script = step.fetch("run")
    abort "Expected a nonempty run block" unless script.is_a?(String) && !script.strip.empty?
    abort "Actions expressions need an Actions runtime" if script.include?("${{")
    puts script
' "$candidate/action.yml")"

if "$dry_run"; then
    printf '%s\n' "Candidate: $candidate/action.yml" "$prerequisite"
    printf '\n%s\n' "Then apply GITHUB_PATH, run brew install bash, and verify Bash >= 4.2."
    exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This provisioning smoke test must run on macOS; --dry-run only extracts the step." >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    echo "Run as the GitHub runner account, not root." >&2
    exit 1
fi
printf 'Testing %s/action.yml as %s (HOME=%s)\n' "$candidate" "$(id -un)" "$HOME"

scratch="$(mktemp -d)"
trap 'rm -f "$scratch/prerequisite.sh" "$scratch/github-path"; rmdir "$scratch"' EXIT
printf '%s\n' "$prerequisite" > "$scratch/prerequisite.sh"
export GITHUB_PATH="$scratch/github-path"
: > "$GITHUB_PATH"

# Match Actions bash error handling, including the initial macOS system Bash.
/bin/bash --noprofile --norc -e -o pipefail "$scratch/prerequisite.sh"
while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    if [[ "$entry" != /* ]] || [ ! -d "$entry" ]; then
        echo "Invalid GITHUB_PATH directory: $entry" >&2
        exit 1
    fi
    export PATH="$entry:$PATH"
done < "$GITHUB_PATH"
hash -r

echo "Homebrew: $(command -v brew)"
prefix="$(brew --prefix)"
brew install bash
hash -r
if [ "$(command -v bash)" != "$prefix/bin/bash" ]; then
    echo "Expected Homebrew Bash on PATH at $prefix/bin/bash, got $(command -v bash)." >&2
    exit 1
fi
bash --noprofile --norc -c '
    set -euo pipefail
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
        echo "Bash >= 4.2 is required for the pinned Rust setup action." >&2
        exit 1
    fi
    probe=usable
    [[ -v probe ]]
    printf "Homebrew smoke test passed: Bash %s at %s\n" "$BASH_VERSION" "$BASH"
'
