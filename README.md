# macOS GitHub Actions Runner Auto-Restart Setup

This directory contains scripts to automatically start and restart GitHub Actions runners on macOS, with graceful shutdown on machine sleep/restart.

## What It Does

- **Wrapper script** (`github-runner-wrapper.sh`): Infinite-loops the runner's `./run.sh`, catching crashes and restarting with a 5-second backoff.
- **Launchd plists** (`com.github.runner-1.plist`, `com.github.runner-2.plist`): Configure macOS to start the runners at login and keep them alive.
- **Setup script** (`setup-runner-macos.sh`): Installs the plists and enables the services.

### Features

✅ Auto-restarts runner on crash  
✅ Survives `./run.sh` exit with any code  
✅ Graceful shutdown on `SIGTERM` (machine sleep/shutdown)  
✅ Post-job cleanup via GitHub's official hook mechanism  
✅ Logs to `~/.github-runner-logs/`  
✅ Starts automatically on macOS boot  

## Prerequisites

1. GitHub Actions runners already installed in `$HOME/github-runner-1` and/or `$HOME/github-runner-2`.
2. `./run.sh` exists and is executable in each runner directory.
3. macOS (tested on Big Sur+; should work on any recent version).

### Step 1: Install the Launchd Services

The setup script automatically handles post-job cleanup configuration—no manual steps needed.

### Option A: Install Both Runners

```bash
bash setup-runner-macos.sh --runner-1 --runner-2
```

### Option B: Install Runner-1 Only

```bash
bash setup-runner-macos.sh --runner-1
```

### Option C: Install Runner-2 Only

```bash
bash setup-runner-macos.sh --runner-2
```

The setup script will:
1. Make `github-runner-wrapper.sh` executable
2. Create a self-contained hook script in each runner directory (`job-completed-hook.sh`)
3. Configure the `.env` file to use the hook
4. Substitute your actual `$HOME` path into the plist templates
5. Copy plist files to `~/Library/LaunchAgents/`
6. Load them via `launchctl`

### What Happens After Each Job

After each job completes, the GitHub Actions runner automatically invokes the hook at `$HOME/github-runner-N/job-completed-hook.sh`. This hook:
- Determines its runner directory from its own location
- Cleans up the `_work/*` directory to remove job artifacts
- Logs cleanup activities to `.cleanup.log` in the runner directory

This happens without any arguments being passed to the hook (which is a GitHub Actions requirement).

## Monitoring and Logs

Monitor runner status:
```bash
launchctl list com.github.runner-1
launchctl list com.github.runner-2
```

View runner logs:
```bash
tail -f ~/.github-runner-logs/runner-1.log
tail -f ~/.github-runner-logs/runner-2.log
```

View cleanup logs:
```bash
tail -f ~/github-runner-1/.cleanup.log
tail -f ~/github-runner-2/.cleanup.log
```

## Uninstall

To uninstall all runners:
```bash
bash setup-runner-macos.sh --cleanup
```

This will:
1. Unload the services via `launchctl`
2. Remove the plist files from `~/Library/LaunchAgents/`
3. Leave your runner directories intact (in case you want to use them manually)

## Cleanup of `_work` Directory

Post-job cleanup is handled via `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`, which is GitHub's official mechanism. The cleanup script runs automatically after every job completes, clearing the `_work` directory to prevent stale artifacts from accumulating.

## Monitoring

### Check Status

```bash
launchctl list com.github.runner-1
launchctl list com.github.runner-2
```

Output shows:
- `PID` (process ID) — running process or `-`
- Exit code from last run (0 = clean exit, `-` = still running)

### View Logs

```bash
# Tail both stdout and stderr for runner-1
tail -f ~/.github-runner-logs/runner-1-*.log

# Tail runner-2
tail -f ~/.github-runner-logs/runner-2-*.log

# All runner logs
tail -f ~/.github-runner-logs/*.log
```

## Uninstallation

```bash
bash scripts/setup-runner-macos.sh --cleanup
```

This will:
- Unload both runners from launchd
- Remove their plist files
- Runners will stop immediately

## How It Works

### Wrapper Loop

```
Start wrapper
  ↓
cd to runner directory
  ↓
./run.sh (runs until crash, job completion, or signal)
  ↓
Capture exit code
  ↓
Log result
  ↓
Sleep 5 seconds (interruptible)
  ↓
Loop back to ./run.sh
```

**Cleanup flow** (when runner is healthy):

```
Job completes
  ↓
GitHub Actions runner triggers ACTIONS_RUNNER_HOOK_JOB_COMPLETED
  ↓
github-runner-cleanup.sh runs (defined in runner's .env)
  ↓
_work/* is removed
  ↓
Next job can start clean
```

## Architecture: Wrapper + Hook

Two complementary mechanisms keep runners healthy:

| Component | When | Purpose |
|-----------|------|---------|
| **Wrapper** (launchd) | Crash recovery | Auto-restarts `./run.sh` if it dies, with 5s backoff |
| **Cleanup hook** (GitHub official) | After each job | Removes `_work/*` artifacts via `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` |

**Normal operation**: Jobs complete → Hook cleanup fires → `_work` cleared → Next job runs clean  
**On crash**: Runner crashes → Wrapper restarts it → Next job runs → Cleanup fires

The hook is the primary cleanup mechanism; the wrapper is the safety net for crashes.

### Graceful Shutdown

When macOS shuts down or the user logs out:

1. launchd sends `SIGTERM` to the wrapper
2. Wrapper's signal handler logs the shutdown and exits cleanly
3. `./run.sh` may also receive `SIGTERM` and should handle gracefully (standard GitHub runner behavior)

### Logs

All output (including the wrapper's restarts and the runner's own logs) goes to:

- `~/.github-runner-logs/runner-1-stdout.log` — main output
- `~/.github-runner-logs/runner-1-stderr.log` — errors (usually merged into stdout)

The wrapper also logs its own state changes (start, crash, restart, shutdown) to the same file.

## Troubleshooting

### Runners not starting on boot?

```bash
# Check if plist is loaded
launchctl list com.github.runner-1

# If not loaded, load manually
launchctl load ~/Library/LaunchAgents/com.github.runner-1.plist

# Check for errors
cat ~/.github-runner-logs/runner-1-stderr.log
```

### Runner keeps crashing?

1. Check `~/.github-runner-logs/runner-*-*.log` for the actual error
2. Verify `$HOME/github-runner-1/run.sh` exists and is executable
3. Try running it manually: `cd $HOME/github-runner-1 && ./run.sh`

### Want to stop a runner temporarily?

```bash
launchctl unload ~/Library/LaunchAgents/com.github.runner-1.plist
```

To restart it:

```bash
launchctl load ~/Library/LaunchAgents/com.github.runner-1.plist
```

### Need to edit the plist?

```bash
# Unload first
launchctl unload ~/Library/LaunchAgents/com.github.runner-1.plist

# Edit
nano ~/Library/LaunchAgents/com.github.runner-1.plist

# Reload
launchctl load ~/Library/LaunchAgents/com.github.runner-1.plist
```

## Implementation Notes

- `KeepAlive` with `SuccessfulExit: false` tells launchd: "Restart this if it dies for ANY reason (including clean exits)." This is intentional — we want the wrapper loop to run forever.
- The wrapper traps `SIGTERM` to shut down gracefully on system shutdown, rather than fighting launchd.
- `RunAtLoad: true` means the service starts immediately when the plist is loaded (first install) and also at each login.
- The wrapper uses `set -euo pipefail` but deliberately unsets `-e` around `wait` so a non-zero exit doesn't kill the script.

## Files

- `github-runner-wrapper.sh` — Main restart loop script (universal for both runners)
- `com.github.runner-1.plist` — launchd config for runner-1 (template)
- `com.github.runner-2.plist` — launchd config for runner-2 (template)
- `setup-runner-macos.sh` — Installation and management script

---

**Questions?** Check the logs in `~/.github-runner-logs/` — they're usually the source of truth.
