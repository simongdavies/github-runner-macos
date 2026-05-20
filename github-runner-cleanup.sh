#!/bin/bash
#
# GitHub Actions Runner Post-Job Cleanup Hook
#
# This script is automatically invoked by the runner after each job completes
# via the ACTIONS_RUNNER_HOOK_JOB_COMPLETED environment variable.
#
# Purpose: Clean up the _work directory to prevent stale artifacts.
#
# Exit code: 0 = success, non-zero = failure (but job has already completed,
# so this doesn't affect job status — it's logged for diagnostics)

set -u

RUNNER_DIR="${1:?Error: runner directory required}"
LOG_FILE="${RUNNER_DIR}/.cleanup.log"

{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-job cleanup started"
    
    if [ ! -d "$RUNNER_DIR/_work" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] _work directory not found"
        exit 0
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning _work/*..."
    rm -rf "$RUNNER_DIR/_work"/* 2>&1 || {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Cleanup failed (non-fatal)"
        exit 0  # Don't fail the cleanup hook
    }
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup complete"
} >> "$LOG_FILE" 2>&1

exit 0
