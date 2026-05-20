# macOS GitHub Actions Runner Setup

This repo automates multi-runner setup on macOS:
- download and extract the GitHub runner package
- create numbered runner directories from a prefix
- configure each runner against a repo or org
- run them under launchd with restart behavior
- clean each runner work directory after every job

## Scripts

- bootstrap-gh-runners.sh: Creates directories, downloads runner binaries, extracts, and runs config.sh in unattended mode.
- github-runner-wrapper.sh: Crash-recovery wrapper around run.sh.
- launchd plists are generated automatically by bootstrap when using --install-launchd.

## GitHub Requirements (from official docs)

- macOS 11+ supported.
- x64 and ARM64 runner architectures supported.
- Registration token is time-limited (typically 1 hour).
- Runner machine must be able to reach GitHub over outbound HTTPS on port 443.

Reference docs:
- https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners
- https://docs.github.com/en/actions/reference/runners/self-hosted-runners
- https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/removing-self-hosted-runners

## 1) Get Setup Values from GitHub UI

In your repository or organization:
1. Go to Settings -> Actions -> Runners.
2. Click New self-hosted runner.
3. Select macOS and the correct architecture for your Mac.
4. Copy the URL target and registration token shown by GitHub.

Important:
- Do not commit tokens to git.
- If a token expires, generate a new one and rerun bootstrap.

## 2) One Command: Bootstrap + Hook Env + launchd

Organization example:

```bash
bash bootstrap-gh-runners.sh \
  --dir-prefix "$HOME/github-runner" \
  --count 2 \
  --org your-org \
  --token "YOUR_REGISTRATION_TOKEN" \
  --labels "self-hosted,macos,arm64" \
  --replace \
  --install-launchd
```

Repository example:

```bash
bash bootstrap-gh-runners.sh \
  --dir-prefix "$HOME/github-runner" \
  --count 2 \
  --repo owner/repo \
  --token "YOUR_REGISTRATION_TOKEN" \
  --labels "self-hosted,macos,arm64" \
  --replace \
  --install-launchd
```

What this creates:
- $HOME/github-runner-1
- $HOME/github-runner-2

Common flags:
- --runner-group <name>: Org or enterprise runner group.
- --name-prefix <prefix>: Base name for runners.
- --force-recreate: Deletes existing directories before reinstall.
- --install-launchd: Installs/reloads launchd services for all runners 1..N.
- --launchd-label-prefix <prefix>: Custom launchd label prefix (default: com.github.runner).
- --launch-agents-dir <dir>: Custom LaunchAgents directory (default: ~/Library/LaunchAgents).
- --version x.y.z: Pins runner version instead of latest.

Incremental behavior:
- If prefix-1 and prefix-2 already exist and are configured, and you run with --count 4, the script skips 1/2 and sets up 3/4.
- It also ensures ACTIONS_RUNNER_HOOK_JOB_COMPLETED is present in each runner .env and writes job-completed-hook.sh.
- With --install-launchd, it installs/reloads services com.github.runner-1 .. com.github.runner-4.

## 3) Verify

```bash
launchctl list com.github.runner-1
launchctl list com.github.runner-2
```

If you used count 4, also check:

```bash
launchctl list com.github.runner-3
launchctl list com.github.runner-4
```

Expected in runner terminal/logs after startup:
- Connected to GitHub
- Listening for Jobs

## Logs

```bash
tail -f ~/.github-runner-logs/runner-1-*.log
tail -f ~/.github-runner-logs/runner-2-*.log
tail -f ~/github-runner-1/.cleanup.log
tail -f ~/github-runner-2/.cleanup.log
```

## Restart / Stop / Uninstall

Restart runners (example for 1..4):

```bash
for i in 1 2 3 4; do
  launchctl unload ~/Library/LaunchAgents/com.github.runner-${i}.plist || true
done
for i in 1 2 3 4; do
  launchctl load ~/Library/LaunchAgents/com.github.runner-${i}.plist
done
```

Remove launchd services for arbitrary 1..N (example for 1..4):

```bash
for i in 1 2 3 4; do
  launchctl unload ~/Library/LaunchAgents/com.github.runner-${i}.plist || true
  rm -f ~/Library/LaunchAgents/com.github.runner-${i}.plist
done
```

Remove runner registration from GitHub:
- Use the Remove flow in GitHub Settings -> Actions -> Runners for each runner.
- If you still have machine access, use the remove command GitHub provides in that UI.

---

**Questions?** Check the logs in `~/.github-runner-logs/` — they're usually the source of truth.
