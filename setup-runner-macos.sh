#!/bin/bash
#
# GitHub Actions Runner — macOS LaunchAgent Setup
#
# Purpose: Install and enable the GitHub Actions runner wrapper service(s)
# to start automatically on macOS boot.
#
# Usage:
#   bash scripts/setup-runner-macos.sh [--runner-1] [--runner-2] [--cleanup]
#
# Examples:
#   bash scripts/setup-runner-macos.sh --runner-1 --runner-2     # Install both
#   bash scripts/setup-runner-macos.sh --runner-1                # Install only runner-1
#   bash scripts/setup-runner-macos.sh --cleanup                 # Uninstall all runners
#
# This script:
#   1. Makes the wrapper executable
#   2. Substitutes __HOME__ in plist templates with your actual $HOME path
#   3. Installs plist files to ~/Library/LaunchAgents/
#   4. Loads them via launchctl so they start immediately

set -euo pipefail

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
CLEANUP=false
INSTALL_R1=false
INSTALL_R2=false

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --runner-1) INSTALL_R1=true ;;
        --runner-2) INSTALL_R2=true ;;
        --cleanup) CLEANUP=true ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--runner-1] [--runner-2] [--cleanup]"
            exit 1
            ;;
    esac
done

# If no specific action, show help
if [ "$CLEANUP" = false ] && [ "$INSTALL_R1" = false ] && [ "$INSTALL_R2" = false ]; then
    echo "No action specified. Use:"
    echo "  $0 --runner-1 --runner-2   # Install both runners"
    echo "  $0 --runner-1               # Install runner-1 only"
    echo "  $0 --cleanup                # Uninstall all runners"
    exit 1
fi

# Cleanup function
cleanup_runners() {
    echo "Uninstalling GitHub Actions runners..."
    for label in com.github.runner-1 com.github.runner-2; do
        if launchctl list "$label" &>/dev/null; then
            echo "Unloading $label..."
            launchctl unload "$LAUNCH_AGENTS_DIR/${label}.plist" || true
        fi
        rm -f "$LAUNCH_AGENTS_DIR/${label}.plist"
    done
    echo "Runners uninstalled."
}

# Install function
install_runner() {
    local runner_num="$1"
    local label="com.github.runner-${runner_num}"
    local plist_template="$SCRIPT_DIR/com.github.runner-${runner_num}.plist"
    local plist_dest="$LAUNCH_AGENTS_DIR/${label}.plist"

    if [ ! -f "$plist_template" ]; then
        echo "ERROR: Template not found: $plist_template"
        return 1
    fi

    echo "Installing runner-${runner_num}..."

    # Check if runner directory exists
    if [ ! -d "$HOME/github-runner-${runner_num}" ]; then
        echo "WARNING: Runner directory not found: $HOME/github-runner-${runner_num}"
        echo "         Make sure you've installed the GitHub Actions runner there first."
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    # Create LaunchAgents directory if needed
    mkdir -p "$LAUNCH_AGENTS_DIR"

    # Substitute __HOME__ with actual home directory and install
    sed "s|__HOME__|$HOME|g" "$plist_template" > "$plist_dest"
    chmod 644 "$plist_dest"
    echo "  Installed plist: $plist_dest"

    # Unload old version if running
    if launchctl list "$label" &>/dev/null; then
        echo "  Unloading previous version..."
        launchctl unload "$plist_dest" || true
    fi

    # Load the service
    echo "  Loading service..."
    launchctl load "$plist_dest"
    echo "  ✓ runner-${runner_num} is now running and will auto-start on boot."
}

# Make wrapper executable
if [ -f "$SCRIPT_DIR/github-runner-wrapper.sh" ]; then
    chmod +x "$SCRIPT_DIR/github-runner-wrapper.sh"
    echo "✓ Wrapper script is executable"
else
    echo "ERROR: Wrapper script not found: $SCRIPT_DIR/github-runner-wrapper.sh"
    exit 1
fi

# Execute cleanup or install
if [ "$CLEANUP" = true ]; then
    cleanup_runners
else
    [ "$INSTALL_R1" = true ] && install_runner 1
    [ "$INSTALL_R2" = true ] && install_runner 2
    echo ""
    echo "✓ Setup complete!"
    echo ""
    echo "Monitor runners with:"
    echo "  launchctl list com.github.runner-1"
    echo "  launchctl list com.github.runner-2"
    echo ""
    echo "View logs with:"
    echo "  tail -f ~/.github-runner-logs/runner-1-*.log"
    echo "  tail -f ~/.github-runner-logs/runner-2-*.log"
    echo ""
    echo "To uninstall, run:"
    echo "  bash scripts/setup-runner-macos.sh --cleanup"
fi
