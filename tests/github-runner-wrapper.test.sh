#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

new_case() {
    export HOME="$TEST_ROOT/$1"
    export TEST_EVENTS="$HOME/events"
    export TEST_LINK_STATUS=0 TEST_CLANG_STATUS=0
    mkdir -p "$HOME/bin" "$HOME/runner" "$HOME/.homebrew/bin" "$HOME/.homebrew/opt/llvm/bin"
    : >"$TEST_EVENTS"
    touch "$HOME/runner/run.sh"
    cat >"$HOME/.homebrew/bin/brew" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$HOMEBREW_NO_AUTO_UPDATE" == 1 ]]
[[ "$*" == 'link --force llvm' ]]
echo link >> "$TEST_EVENTS"
exit "$TEST_LINK_STATUS"
MOCK
    cat >"$HOME/.homebrew/opt/llvm/bin/clang" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$*" == --version ]]
echo clang >> "$TEST_EVENTS"
exit "$TEST_CLANG_STATUS"
MOCK
    cat >"$HOME/bin/caffeinate" <<'MOCK'
#!/bin/bash
set -euo pipefail
echo runner >> "$TEST_EVENTS"
kill -TERM "$PPID"
MOCK
    chmod +x "$HOME/.homebrew/bin/brew" "$HOME/.homebrew/opt/llvm/bin/clang" "$HOME/bin/caffeinate"
}

run_wrapper() {
    PATH="$HOME/bin:$PATH" bash "$SCRIPT_DIR/github-runner-wrapper.sh" "$HOME/runner" >"$HOME/output" 2>&1
}

new_case linked
run_wrapper
[[ "$(cat "$TEST_EVENTS")" == $'link\nclang\nrunner' ]]

new_case lock-failure
export TEST_LINK_STATUS=1
if run_wrapper; then
    echo 'FAIL: linking failure must prevent runner startup' >&2
    exit 1
fi
[[ "$(cat "$TEST_EVENTS")" == link ]]
grep -Fq 'lsof +D' "$HOME/output"
grep -Fq -- '--force does not bypass locks' "$HOME/output"

new_case compiler-failure
export TEST_CLANG_STATUS=1
if run_wrapper; then
    echo 'FAIL: compiler failure must prevent runner startup' >&2
    exit 1
fi
[[ "$(cat "$TEST_EVENTS")" == $'link\nclang' ]]

new_case no-private-brew
rm "$HOME/.homebrew/bin/brew"
run_wrapper
[[ "$(cat "$TEST_EVENTS")" == runner ]]

new_case no-private-llvm
rm -rf "$HOME/.homebrew/opt/llvm"
run_wrapper
[[ "$(cat "$TEST_EVENTS")" == runner ]]

echo 'PASS: private LLVM startup linking, failure handling and runners without private LLVM'
