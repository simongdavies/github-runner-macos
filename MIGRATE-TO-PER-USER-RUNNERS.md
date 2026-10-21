# Switch existing macOS runners to separate users

This guide switches macOS runners installed by `bootstrap-gh-runners.sh` from
one shared user to one user per runner. It does not change Tart/Ubuntu runners.

The new runners replace the existing names in GitHub. Old runner folders are
left in place; their caches, credentials and per-user tools are not copied.

Run everything **on the Mac, in the same Terminal window**, as the user who
installed the old runners. Use `sudo` only where shown. That user needs
administrator access.

## 1. Get the updated script

Open Terminal in your checkout of this repository. Check for local changes:

```bash
git status --short
```

If this prints anything, save your changes before switching branches.
Otherwise, get the branch containing the new option:

```bash
git fetch origin &&
git switch simongdavies-per-runner-macos-users &&
git pull --ff-only
```

Once the feature is merged, an updated `main` also works. Confirm that:

```bash
bash bootstrap-gh-runners.sh --help
```

lists `--runner-user-prefix`.

## 2. Set the values for your existing runners

In GitHub, open your repository or organisation's **Settings > Actions >
Runners**. Note the existing runner names, custom labels and runner group.

Edit these values before pasting them into Terminal. The example uses three
runners installed with the original defaults:

```bash
RUNNER_COUNT=3
OLD_DIR_PREFIX="$HOME/github-runner"
RUNNER_NAME_PREFIX="$(hostname -s)-runner"
SERVICE_LABEL_PREFIX="com.github.runner"
RUNNER_LABELS="hvf"
RUNNER_GROUP=""
TARGET_URL="https://github.com/YOUR-ORG"
NEW_USER_PREFIX="gha-macos"
TOKEN_FILE="$HOME/runner-registration-token"
```

| Value | What to use |
| --- | --- |
| `RUNNER_COUNT` | Your existing number of runners, numbered from 1. |
| `OLD_DIR_PREFIX` | Your original `--dir-prefix`, without the `-1` suffix. |
| `RUNNER_NAME_PREFIX` | Your existing GitHub runner names without their `-1`, `-2`, etc. suffixes. For `build-mac-runner-1`, use `build-mac-runner`. |
| `SERVICE_LABEL_PREFIX` | Your original `--launchd-label-prefix`, or `com.github.runner` if you did not change it. |
| `RUNNER_LABELS` | Your original custom labels, separated by commas. The default was `hvf`. Do not include GitHub's automatic `self-hosted`, `macOS` or `ARM64` labels. |
| `RUNNER_GROUP` | Your existing runner group, or leave empty to use the default. Leave empty for repository runners. |
| `TARGET_URL` | The same organisation or repository URL as before: `https://github.com/YOUR-ORG` or `https://github.com/OWNER/REPO`. |
| `NEW_USER_PREFIX` | The new account names will be `gha-macos-1`, `gha-macos-2`, etc. These must not be existing personal accounts. |

**Check the runner name prefix carefully.** `--replace` matches runners by
name. A different prefix creates additional registrations instead of replacing
your existing ones.

This guide assumes the standard startup-service directories:
`~/Library/LaunchAgents` and `/Library/LaunchDaemons`. If you originally used a
custom `--launchd-dir`, its services must also be stopped and removed from that
location before continuing; the uninstall commands below only remove services
from the standard directories.

## 3. Let current jobs finish

Temporarily prevent workflows from sending new jobs to these runners. Wait
until none of the runners is executing a job.

Do not run the remaining steps while a job is still running.

## 4. Get a registration token and save it to a file

In the same GitHub **Settings > Actions > Runners** page:

1. Click **New self-hosted runner**.
2. Select **macOS** and **ARM64**.
3. Find the setup command containing `./config.sh ... --token ...`.
4. Copy **only the token after `--token`**, not the whole command.

In Terminal, run:

```bash
(umask 077; touch "$TOKEN_FILE" && chmod 600 "$TOKEN_FILE" && cat > "$TOKEN_FILE")
```

Paste the token, press **Enter**, then press **Ctrl+D**. This creates the file
that `--token-file` reads, with permissions allowing only your user to read or
write it. Do not put the token in this repository or commit it.

Registration tokens expire after **one hour**. If it expires, repeat this step
with a fresh token.

## 5. Stop the old runners and remove their startup services

Run both commands. The first handles runners that started when you logged in;
the second handles runners that started at boot:

```bash
bash bootstrap-gh-runners.sh \
  --dir-prefix "$OLD_DIR_PREFIX" \
  --count "$RUNNER_COUNT" \
  --launchd-label-prefix "$SERVICE_LABEL_PREFIX" \
  --uninstall-launchd

sudo bash bootstrap-gh-runners.sh \
  --dir-prefix "$OLD_DIR_PREFIX" \
  --count "$RUNNER_COUNT" \
  --launchd-label-prefix "$SERVICE_LABEL_PREFIX" \
  --uninstall-launchd
```

A warning that a system service needs root during the first command is
expected; the second command handles it. These commands do not delete your old
runner folders or remove registrations from GitHub.

If you also started any runners manually in Terminal, stop those with
**Ctrl+C**. Check that the old runners show **Offline** in GitHub before
continuing.

## 6. Create the users and replacement runners

```bash
sudo bash bootstrap-gh-runners.sh \
  --runner-user-prefix "$NEW_USER_PREFIX" \
  --count "$RUNNER_COUNT" \
  --url "$TARGET_URL" \
  --name-prefix "$RUNNER_NAME_PREFIX" \
  --labels "$RUNNER_LABELS" \
  --runner-group "$RUNNER_GROUP" \
  --token-file "$TOKEN_FILE" \
  --launchd-label-prefix "$SERVICE_LABEL_PREFIX" \
  --replace \
  --install-launchd \
  --launchd-scope daemon
```

Bootstrap creates the accounts, installs the runners and starts them
immediately. Each runner also starts automatically after reboot, under its own
non-admin user. Nobody needs to log in.

For runner 1 with `NEW_USER_PREFIX="gha-macos"`:

| Purpose | Folder |
| --- | --- |
| User folder | `/Users/gha-macos-1` |
| Runner files | `/Users/gha-macos-1/actions-runner` |
| Logs | `/Users/gha-macos-1/.github-runner-logs` |

Do not add `--dir-prefix`, `--launchd-user` or `--force-recreate` to this
command. Do not manually remove the old GitHub registrations: `--replace`
replaces them using the same names.

If bootstrap fails, keep workflows paused and read the error before retrying.
It refuses unrelated accounts and existing homes it did not create. A failure
partway through account creation needs manual inspection; do not delete an
account or its files just to make the command pass.

## 7. Check the new runners before resuming normal jobs

Refresh GitHub's runner list. The same runner names should return as **Idle**,
with the same custom labels and runner group.

Check which users are running them:

```bash
ps -axo user:32,pid,command | grep '[g]ithub-runner-wrapper.sh'
```

The user column should show `gha-macos-1`, `gha-macos-2`, etc. (or your chosen
prefix), not the old shared user or `root`.

If runner 1 does not connect, inspect its logs:

```bash
sudo tail -n 50 "/Users/${NEW_USER_PREFIX}-1/.github-runner-logs/runner-1-stdout.log"
sudo tail -n 50 "/Users/${NEW_USER_PREFIX}-1/.github-runner-logs/runner-1-stderr.log"
```

Run one normal workflow on the new runners before resuming the rest. Tools or
credentials previously installed only in the old user's home need setting up
under the new accounts. Do not grant the new accounts sudo access to work
around missing tools.

After a successful job, allow normal workflows to run again.

## 8. Remove the temporary token file

```bash
rm -f "$TOKEN_FILE"
```

Keep the old runner folders until you are satisfied with the new setup. Do not
restart the old installations or run their `config.sh remove`: the GitHub
runner names now belong to the new installations. Going back requires
registering the old runners again with a fresh registration token.

Separate users reduce interference between runners. They do not provide a
fresh machine for each job: files outside `_work` can still persist between
jobs under the same runner user.
