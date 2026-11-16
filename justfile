default: check

format:
    shfmt -w -i 4 -ci tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh
    shfmt -w -i 4 -ci macos-runner-maintenance.sh tests/github-runner-wrapper.test.sh tests/macos-runner-maintenance.test.sh

format-check:
    shfmt -d -i 4 -ci tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh
    shfmt -d -i 4 -ci macos-runner-maintenance.sh tests/github-runner-wrapper.test.sh tests/macos-runner-maintenance.test.sh
    git diff --check

syntax:
    for file in bootstrap-tart-runners.sh tart-common.sh tart-runner-loop.sh tart-bake-ubuntu.sh tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh tests/tart-image-retention.test.sh; do bash -n "$file" || exit; done
    bash -n github-runner-wrapper.sh
    bash -n tests/github-runner-wrapper.test.sh
    bash -n macos-runner-maintenance.sh
    bash -n tests/macos-runner-maintenance.test.sh
    bash -n bootstrap-gh-runners.sh
    bash -n tests/bootstrap-gh-runners.test.sh

lint:
    shellcheck -S warning bootstrap-tart-runners.sh tart-runner-loop.sh tart-bake-ubuntu.sh tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh tests/tart-image-retention.test.sh
    shellcheck -S warning -e SC2064 tart-common.sh
    shellcheck -S warning github-runner-wrapper.sh macos-runner-maintenance.sh tests/github-runner-wrapper.test.sh tests/macos-runner-maintenance.test.sh
    shellcheck -S warning bootstrap-gh-runners.sh tests/bootstrap-gh-runners.test.sh

# Update existing per-user macOS services without re-registering or stopping them.
install-macos-wrapper:
    /bin/bash macos-runner-maintenance.sh --install-only

list-macos-runners:
    /bin/bash macos-runner-maintenance.sh --list

# Only after scheduling is paused and every discovered enabled runner is idle.
repair-macos-runners labels="hvf":
    /bin/bash macos-runner-maintenance.sh --repair-drained {{quote(labels)}}

test-image-refresh:
    bash tests/tart-image-refresh.test.sh

test-macos-wrapper:
    bash tests/github-runner-wrapper.test.sh
    bash tests/macos-runner-maintenance.test.sh

test:
    bash tests/bootstrap-gh-runners.test.sh
    bash tests/github-runner-wrapper.test.sh
    bash tests/macos-runner-maintenance.test.sh
    bash tests/tart-image-refresh.test.sh
    bash tests/tart-configure-runners.test.sh
    bash tests/tart-guest-memory.test.sh
    bash tests/tart-image-retention.test.sh

check: format-check syntax lint test