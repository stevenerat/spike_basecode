#!/usr/bin/env bash
# =============================================================================
# setup-fll-laptop-linux.sh
#
# SYNOPSIS
#   Standardized setup script for Bolton Robotics FLL chapter laptops --
#   Linux (Fedora; should also work on recent Fedora releases and RHEL-family).
#
# DESCRIPTION
#   Run this script ONCE per donated laptop, while logged in as the
#   student team account (which has sudo privileges via `wheel` group).
#
#   Pass the team number as the first argument, or run with no arguments
#   to see the team menu and be prompted.
#
#   The script:
#     1. Installs core software (Git, Python 3.12, VS Code, Chrome,
#        gh CLI) via dnf, adding the Microsoft and Google RPM repos
#     2. Writes a chapter-standard .gitconfig to the user's home directory
#     3. Installs VS Code extensions and configures user settings
#     4. Sets Chrome as default web browser via xdg-settings
#     5. Applies a light set of GNOME "quiet" defaults
#     6. Configures power management via gsettings (don't sleep
#        aggressively on AC)
#     7. Creates the team's repo folder, .desktop launchers in
#        ~/.local/share/applications and ~/Desktop, and Desktop README
#     8. Launches GitHub Desktop (shiftkey Linux fork, installed via
#        Flatpak in step 1) and pauses for the user to authenticate
#        and clone the team's fork -- same UX as the Windows/macOS
#        chapter scripts
#     9. Configures the cloned repo: upstream remote, Python venv,
#        pybricks + pybricksdev packages, VS Code workspace settings
#
#   What it does NOT do (these are interactive or out of scope):
#     - Sign in to Chrome with the team Gmail (Chrome requires a Google
#       account; outlook.com teams skip this step)
#     - Install the Pybricks firmware on the SPIKE Prime hub
#     - Install GitKraken or any other alternative git GUI (the chapter
#       standard on Linux is GitHub Desktop, shiftkey Flatpak fork, for
#       parity with Windows and macOS chapter laptops)
#     - Apply Fedora system updates (run `sudo dnf upgrade --refresh`
#       separately if the laptop has been idle for months)
#
#   NEW TEAM SUPPORT
#     If the team number is not in the known-teams list, the script will
#     prompt for the team's email, display name, and GitHub username. No
#     script edit needed to set up a new team. You can optionally add
#     the team to the known-teams list afterward so it appears in the
#     menu next time.
#
# NOTES
#   Author:   Steven Erat with Claude (Bolton Robotics chapter)
#   Audience: FLL chapter coaches provisioning team laptops on Linux
#   Tested on: Fedora (GNOME / Wayland)
#
#   Run from a terminal:
#       chmod +x setup-fll-laptop-linux.sh
#       ./setup-fll-laptop-linux.sh 27041
# =============================================================================

set -eo pipefail

# -----------------------------------------------------------------------------
# Color helpers
# -----------------------------------------------------------------------------
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
GRAY='\033[90m'
WHITE='\033[97m'
RESET='\033[0m'

cecho() { printf "%b%s%b\n" "$1" "$2" "$RESET"; }

# -----------------------------------------------------------------------------
# Flatpak helpers
# -----------------------------------------------------------------------------

# reinstall_flatpak_user APP_ID [REMOTE]
# Fully wipes and reinstalls a user-scope Flatpak app. Safe on first install
# too. Useful when an app has misbehaved after a major OS upgrade and a clean
# reset is wanted. Portable across flatpak versions -- avoids the 1.10+
# `--delete-data` flag that older Fedora releases reject as unknown.
# Not called by default; first-run provisioning shouldn't wipe data.
reinstall_flatpak_user() {
    local app_id="$1"
    local remote="${2:-flathub}"
    flatpak uninstall --user -y "$app_id" 2>/dev/null || true
    rm -rf "$HOME/.var/app/$app_id"
    flatpak install --user -y "$remote" "$app_id"
}

# =============================================================================
# TEAM SELECTION
# =============================================================================

team_is_known() {
    case "$1" in
        18300|19991|27041|27042|62070) return 0 ;;
        *) return 1 ;;
    esac
}

team_default_name() {
    case "$1" in
        27041) echo "Thought Process" ;;
        *)     echo "" ;;
    esac
}

team_default_email() {
    case "$1" in
        18300) echo "fss.fll.18300@outlook.com" ;;
        19991) echo "fss.fll.19991@outlook.com" ;;
        27041) echo "fss.fll.27041@gmail.com"   ;;
        27042) echo "fss.fll.27042@gmail.com"   ;;
        62070) echo "fss.fll.62070@outlook.com" ;;
        *)     echo "" ;;
    esac
}

TEAM_NUMBER="${1:-}"

if [[ -z "$TEAM_NUMBER" ]]; then
    echo
    cecho "$CYAN" "Bolton Robotics FLL -- known teams:"
    for t in 18300 19991 27041 27042 62070; do
        name="$(team_default_name "$t")"
        [[ -z "$name" ]] && name="(unnamed)"
        echo "  $t  $name"
    done
    echo "  (or enter any other 5-digit number for a new team)"
    echo
    read -r -p "Enter team number for this laptop: " TEAM_NUMBER
fi

if ! team_is_known "$TEAM_NUMBER"; then
    echo
    cecho "$YELLOW" "Team $TEAM_NUMBER is NOT in the known teams list."
    cecho "$YELLOW" "This will set up the laptop as a NEW team."
    cecho "$YELLOW" "(If you meant an existing team, this is a good moment to check for a typo.)"
    read -r -p "Continue setup for new team $TEAM_NUMBER? (Y/n) " confirm
    if [[ -n "$confirm" && ! "$confirm" =~ ^[Yy] ]]; then
        cecho "$RED" "Cancelled. Run the script again with the correct team number."
        exit 1
    fi

    echo
    cecho "$CYAN" "Enter team email."
    cecho "$CYAN" "Chapter standard format examples (do not press Enter to accept -- type the actual email):"
    cecho "$GRAY" "  fss.fll.${TEAM_NUMBER}@gmail.com"
    cecho "$GRAY" "  fss.fll.${TEAM_NUMBER}@outlook.com"
    read -r -p "Team email: " NEW_EMAIL
    while [[ -z "$NEW_EMAIL" || "$NEW_EMAIL" != *"@"* ]]; do
        cecho "$YELLOW" "Email is required and must contain '@'."
        read -r -p "Team email: " NEW_EMAIL
    done

    echo
    read -r -p "Team display name (optional; press Enter to skip): " NEW_NAME

    echo
    DEFAULT_GH_USER="fssfll$TEAM_NUMBER"
    read -r -p "GitHub username (press Enter for '$DEFAULT_GH_USER'): " NEW_GH_USER
    [[ -z "$NEW_GH_USER" ]] && NEW_GH_USER="$DEFAULT_GH_USER"

    TEAM_NAME="$NEW_NAME"
    TEAM_EMAIL="$NEW_EMAIL"
    GITHUB_USER="$NEW_GH_USER"
else
    TEAM_NAME="$(team_default_name "$TEAM_NUMBER")"
    TEAM_EMAIL="$(team_default_email "$TEAM_NUMBER")"
    GITHUB_USER="fssfll$TEAM_NUMBER"
fi

[[ -z "$TEAM_NAME" ]] && TEAM_NAME="Bolton Robotics Team $TEAM_NUMBER"

GIT_USER_NAME="Bolton Robotics FLL Team $TEAM_NUMBER"
GIT_USER_EMAIL="$TEAM_EMAIL"
FORK_URL="https://github.com/$GITHUB_USER/spike_basecode.git"
UPSTREAM_URL="https://github.com/stevenerat/spike_basecode.git"

REPOS_ROOT="$HOME/repos"
REPO_PATH="$REPOS_ROOT/spike_basecode"
DESKTOP_PATH="$HOME/Desktop"
APPS_PATH="$HOME/.local/share/applications"
GIT_CONFIG_PATH="$HOME/.gitconfig"

# =============================================================================
# PRELIMINARIES
# =============================================================================

if [[ "$(uname -s)" != "Linux" ]]; then
    cecho "$RED" "This script targets Linux. Detected: $(uname -s)"
    cecho "$RED" "Use setup-fll-laptop.ps1 (Windows) or setup-fll-laptop-mac.sh (macOS) instead."
    exit 1
fi

# Lightly sanity-check the distro. dnf-based is the only currently-tested
# target; on apt-based distros the package install section needs adapting.
if ! command -v dnf >/dev/null 2>&1; then
    cecho "$RED" "dnf not found. This script targets Fedora / RHEL-family Linux."
    cecho "$RED" "On Debian/Ubuntu you'd swap 'dnf install' for 'apt install' and adjust repo setup -- not done here."
    exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
    cecho "$RED" "Do NOT run this script with sudo or as root."
    cecho "$RED" "Run as the student/team user. You'll be prompted for the admin password when needed."
    exit 1
fi

# Desktop folder may not exist on a fresh GNOME install with desktop icons
# disabled (the Fedora default). Create it so our .desktop launchers have
# somewhere to land; the user can enable Desktop Icons NG to see them.
mkdir -p "$DESKTOP_PATH" "$APPS_PATH" "$REPOS_ROOT"

echo
cecho "$CYAN" "==============================================================="
cecho "$CYAN" " FLL Laptop Setup (Linux) -- Team $TEAM_NUMBER ($TEAM_NAME)"
cecho "$CYAN" " Email:  $TEAM_EMAIL"
cecho "$CYAN" " GitHub: $GITHUB_USER"
cecho "$CYAN" "==============================================================="
echo

cecho "$GRAY" "This script needs sudo for package installation. You may be prompted now."
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
echo

# =============================================================================
# 1. SOFTWARE INSTALLATION VIA DNF
# =============================================================================

cecho "$YELLOW" "[1/9] Installing core software via dnf..."

# 1a. Add the Microsoft VS Code repo (idempotent: rpm --import and a
#     dnf repo file are both safe to re-apply).
if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
    cecho "$GRAY" "  Adding Microsoft VS Code repo..."
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
else
    cecho "$GRAY" "  Microsoft VS Code repo already configured."
fi

# 1b. Install Google Chrome from Google's RPM. Installing the RPM also
#     adds Google's repo for future updates, so we only need to do this
#     once per laptop. Skip if already installed.
if ! rpm -q google-chrome-stable >/dev/null 2>&1; then
    cecho "$GRAY" "  Installing Google Chrome..."
    sudo dnf install -y \
        https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm
else
    cecho "$GRAY" "  Google Chrome already installed."
fi

# 1c. Install the rest via dnf. `dnf install -y` is idempotent (returns
#     0 if all packages are already present). flatpak is included so we
#     can install GitHub Desktop (shiftkey fork) in step 1d.
dnf_packages=(
    "git"
    "python3.12"
    "code"
    "flatpak"
)
cecho "$GRAY" "  Installing: ${dnf_packages[*]}"
sudo dnf install -y "${dnf_packages[@]}"

# 1d. Install GitHub Desktop (shiftkey community Linux fork) via
#     Flatpak. This is the chapter standard GUI git client on Linux --
#     functionally identical UX to GitHub Desktop on Windows/macOS.
#
#     Flathub is added at the user level (no sudo). On a Fedora
#     Workstation that already has Flathub enabled system-wide this is
#     a harmless duplicate; on a minimal install it's the only path to
#     Flathub apps.
cecho "$GRAY" "  Ensuring Flathub remote is configured (user-level)..."
flatpak remote-add --if-not-exists --user flathub \
    https://flathub.org/repo/flathub.flatpakrepo

if ! flatpak --user info io.github.shiftey.Desktop >/dev/null 2>&1; then
    cecho "$GRAY" "  Installing GitHub Desktop (shiftkey fork) from Flathub..."
    flatpak install --user -y flathub io.github.shiftey.Desktop
else
    cecho "$GRAY" "  GitHub Desktop (shiftkey fork) already installed."
fi

# Resolve binary paths for later use.
PYTHON_BIN="$(command -v python3.12 || true)"
if [[ -z "$PYTHON_BIN" ]]; then
    cecho "$RED" "python3.12 install appears to have failed."
    exit 1
fi

cecho "$GREEN" "  Software install complete."
echo

# =============================================================================
# 2. GIT CONFIGURATION (.gitconfig)
# =============================================================================

cecho "$YELLOW" "[2/9] Writing chapter-standard .gitconfig..."

# Adapted from the chapter .gitconfig template with Linux-specific
# adjustments:
#   - credential.helper = cache with an 8-hour timeout. GitHub Desktop
#     manages its own credentials in the system secret store (GNOME
#     Keyring), so git CLI usage is mostly the coach's fallback path;
#     the cache helper avoids re-prompting during long sessions
#     without writing tokens to disk.
#   - core.autocrlf = false: the repo's .gitattributes drives EOL
#     behavior, same as on Mac and Windows.
#
# Re-running this script OVERWRITES the .gitconfig file -- any manual
# edits will be lost.

cat > "$GIT_CONFIG_PATH" <<EOF
# ~/.gitconfig -- FLL chapter laptop (Linux)
# Generated by setup-fll-laptop-linux.sh -- re-running the script overwrites this file.

[user]
    name = $GIT_USER_NAME
    email = $GIT_USER_EMAIL

[init]
    defaultBranch = main

[pull]
    rebase = false                   # Default to merge on pull, not rebase

[credential]
    helper = cache --timeout=28800   # 8h in-memory cache; Desktop owns secrets

[color]
    ui = auto

[color "status"]
    added = green
    changed = yellow
    untracked = red

[color "diff"]
    meta = cyan
    frag = magenta
    old = red
    new = green

[color "branch"]
    current = yellow bold
    local = green
    remote = cyan

[core]
    editor = code --wait
    pager = less -FRSX
    autocrlf = false

[help]
    autocorrect = 20

[merge]
    conflictstyle = diff3

[blame]
    coloring = highlightRecent

[diff]
    tool = vimdiff

[difftool]
    prompt = false

[alias]
    st = status -sb
    lg = log --graph --decorate --oneline --all
    lga = log --graph --decorate --pretty=oneline --abbrev-commit --all
    undo = reset --soft HEAD~1
EOF

cecho "$GREEN" "  .gitconfig written to $GIT_CONFIG_PATH"
cecho "$GREEN" "  Configured for $GIT_USER_NAME <$GIT_USER_EMAIL>."
echo

# =============================================================================
# 3. VS CODE EXTENSIONS AND USER SETTINGS
# =============================================================================

cecho "$YELLOW" "[3/9] Installing VS Code extensions and configuring user settings..."

vscode_extensions=(
    "ms-python.python"
    "ms-python.vscode-pylance"
    "eamodio.gitlens"
)

if command -v code >/dev/null 2>&1; then
    for ext in "${vscode_extensions[@]}"; do
        cecho "$GRAY" "  Installing extension: $ext"
        code --install-extension "$ext" --force >/dev/null
    done
else
    cecho "$YELLOW" "  'code' CLI not on PATH -- skipping extension install."
    cecho "$YELLOW" "  Open VS Code once, then re-run this script."
fi

# User settings on Linux live under ~/.config/Code/User/. Workspace
# settings (per-repo, including the venv interpreter) are written in
# Section 9 after the repo is cloned.
VSCODE_SETTINGS_DIR="$HOME/.config/Code/User"
VSCODE_SETTINGS_PATH="$VSCODE_SETTINGS_DIR/settings.json"

mkdir -p "$VSCODE_SETTINGS_DIR"

cat > "$VSCODE_SETTINGS_PATH" <<'EOF'
{
    "terminal.integrated.defaultProfile.linux": "bash",
    "editor.formatOnSave": true,
    "files.trimTrailingWhitespace": true,
    "files.insertFinalNewline": true,
    "telemetry.telemetryLevel": "off",
    "update.showReleaseNotes": false,
    "workbench.startupEditor": "none",
    "explorer.confirmDragAndDrop": false
}
EOF

cecho "$GREEN" "  VS Code configured."
echo

# =============================================================================
# 4. BROWSER DEFAULTS
# =============================================================================

cecho "$YELLOW" "[4/9] Configuring browser defaults..."

# xdg-settings is the standard cross-desktop way to set the default
# browser on Linux. The argument is the .desktop file name (which the
# Chrome RPM installs at /usr/share/applications/google-chrome.desktop).
if command -v xdg-settings >/dev/null 2>&1; then
    if xdg-settings set default-web-browser google-chrome.desktop 2>/dev/null; then
        cecho "$GRAY" "  Default browser set to Google Chrome."
    else
        cecho "$YELLOW" "  Could not set Chrome as default via xdg-settings."
        cecho "$YELLOW" "  Set it manually: Settings > Default Applications > Web > Google Chrome."
    fi
else
    cecho "$YELLOW" "  xdg-settings not available; set Chrome as default manually in GNOME Settings."
fi

cecho "$GREEN" "  Browser default configured."
echo

# =============================================================================
# 5. QUIET GNOME -- LIGHT-TOUCH DEFAULTS
# =============================================================================

cecho "$YELLOW" "[5/9] Quieting GNOME defaults..."

# gsettings is per-user; no sudo needed. Each line is safely re-runnable.
# Most GNOME defaults are already reasonable, so this section is light.
if command -v gsettings >/dev/null 2>&1; then
    # Don't ask for confirmation when deleting from Files (Nautilus) --
    # they go to Trash, so the confirm dialog is purely friction.
    gsettings set org.gnome.nautilus.preferences confirm-trash false 2>/dev/null || true

    # Show hidden files toggle stays default (off); kids don't need it.

    # Disable the "Welcome to Fedora" / first-run tour for new users on
    # this laptop. Harmless if it's already been dismissed.
    gsettings set org.gnome.shell welcome-dialog-last-shown-version "999.0" 2>/dev/null || true

    cecho "$GRAY" "  GNOME preferences applied."
else
    cecho "$YELLOW" "  gsettings not available; skipping GNOME tweaks."
fi

cecho "$GREEN" "  GNOME quieted."
echo

# =============================================================================
# 6. POWER MANAGEMENT
# =============================================================================

cecho "$YELLOW" "[6/9] Configuring power management..."

# Don't sleep aggressively while plugged in at meetings.
# All gsettings values are per-user (no sudo).
#   idle-delay:                 seconds before screen blank (30 min = 1800)
#   sleep-inactive-ac-timeout:  seconds before suspend on AC (60 min = 3600)
#   sleep-inactive-ac-type:     'suspend' is the default; leaving alone
#                               so the laptop *does* eventually sleep
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.session idle-delay 1800 2>/dev/null || true
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 3600 2>/dev/null || true
    cecho "$GRAY" "  Power plan: screen blank 30min, suspend 60min on AC."
else
    cecho "$YELLOW" "  gsettings not available; configure power settings manually in GNOME Settings > Power."
fi

cecho "$GREEN" "  Power management configured."
echo

# =============================================================================
# 7. REPO FOLDER, DESKTOP SHORTCUTS, README
# =============================================================================

cecho "$YELLOW" "[7/9] Creating .desktop launchers and Desktop README..."

# Helper: write a .desktop file in $APPS_PATH (always discoverable via
# Activities overview) and a duplicate in $DESKTOP_PATH (visible only
# if the Desktop Icons NG extension is enabled).
make_desktop_entry() {
    local filename="$1"
    local content="$2"

    local apps_file="$APPS_PATH/$filename"
    local desktop_file="$DESKTOP_PATH/$filename"

    echo "$content" > "$apps_file"
    chmod +x "$apps_file"

    cp "$apps_file" "$desktop_file"
    chmod +x "$desktop_file"

    # Modern GNOME requires the user's "trust" metadata for desktop icons.
    # gio handles this gracefully even if the user has DING disabled.
    gio set "$desktop_file" metadata::trusted true 2>/dev/null || true
}

# Open Team N Code -- launch VS Code on the repo folder
make_desktop_entry "fll-team-${TEAM_NUMBER}-code.desktop" "[Desktop Entry]
Type=Application
Name=Open Team $TEAM_NUMBER Code
Comment=Open the Team $TEAM_NUMBER repo in VS Code
Exec=code \"$REPO_PATH\"
Icon=visual-studio-code
Terminal=false
Categories=Development;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: Open Team $TEAM_NUMBER Code"

# Team N Repo Folder -- open the folder in Files (Nautilus)
make_desktop_entry "fll-team-${TEAM_NUMBER}-folder.desktop" "[Desktop Entry]
Type=Application
Name=Team $TEAM_NUMBER Repo Folder
Comment=Open the Team $TEAM_NUMBER repo folder in Files
Exec=xdg-open \"$REPO_PATH\"
Icon=folder
Terminal=false
Categories=Utility;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: Team $TEAM_NUMBER Repo Folder"

# Terminal (Team N) -- spawn an interactive shell in the repo folder
# (useful for running pybricksdev). Terminal=true tells GNOME to wrap
# the Exec in the user's preferred terminal emulator.
make_desktop_entry "fll-team-${TEAM_NUMBER}-terminal.desktop" "[Desktop Entry]
Type=Application
Name=Terminal (Team $TEAM_NUMBER)
Comment=Open a terminal in the Team $TEAM_NUMBER repo folder
Exec=bash -c \"cd '$REPO_PATH' && exec bash --login\"
Icon=utilities-terminal
Terminal=true
Categories=System;TerminalEmulator;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: Terminal (Team $TEAM_NUMBER)"

# GitHub Desktop launcher. The Flatpak install registers its own
# .desktop entry under the system applications path, but we duplicate
# a Desktop-visible launcher for parity with the team workflow shortcuts.
make_desktop_entry "fll-team-${TEAM_NUMBER}-github-desktop.desktop" "[Desktop Entry]
Type=Application
Name=GitHub Desktop
Comment=Launch GitHub Desktop (shiftkey Linux fork)
Exec=flatpak run io.github.shiftey.Desktop
Icon=io.github.shiftey.Desktop
Terminal=false
Categories=Development;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: GitHub Desktop"

# Desktop README -- GitHub Desktop oriented (chapter standard on
# Linux is the shiftkey Flatpak fork; git CLI is for technical coaches).
cat > "$DESKTOP_PATH/README - Team $TEAM_NUMBER.txt" <<EOF
TEAM $TEAM_NUMBER - $TEAM_NAME
==========================================

YOUR CODE LIVES IN:
  $REPO_PATH

EVERYDAY WORKFLOW (use GitHub Desktop):

  Get the latest code from your team's repo:
    1. Open GitHub Desktop
    2. Click "Fetch origin" (top bar)
    3. Click "Pull origin" if updates appear

  Save your changes:
    1. Open GitHub Desktop
    2. Review changed files in the "Changes" tab
    3. Type a summary message at the bottom-left
    4. Click "Commit to main"
    5. Click "Push origin" in the top bar

  Pull chapter updates (when Steve announces changes):
    1. Go to https://github.com/$GITHUB_USER/spike_basecode
    2. If GitHub shows "This branch is N commits behind", click "Sync fork"
    3. In GitHub Desktop, click "Fetch origin" then "Pull origin"

  Run code on the SPIKE hub:
    Open the 'Terminal (Team $TEAM_NUMBER)' shortcut, then run:
      python3.12 -m pybricksdev run ble --name <hub-name> main.py

QUESTIONS?
  Talk to your coach, or contact Steve.

YOUR TEAM'S GITHUB:
  https://github.com/$GITHUB_USER/spike_basecode

CHAPTER UPSTREAM (where updates come from):
  $UPSTREAM_URL

NOTE FOR TECHNICAL COACHES:
  GitHub Desktop on Linux is the shiftkey community Flatpak fork
  (io.github.shiftey.Desktop). Functionally it behaves like the
  Windows/macOS official build. If you prefer the CLI, all the
  Desktop operations have direct git equivalents:
      git pull / git fetch upstream / git push origin main
EOF

cecho "$GREEN" "  Launchers and README created."
echo

# =============================================================================
# 8. GITHUB DESKTOP AUTHENTICATION AND REPO CLONE (INTERACTIVE PAUSE)
# =============================================================================

cecho "$YELLOW" "[8/9] GitHub Desktop authentication and repository clone..."

if [[ -d "$REPO_PATH/.git" ]]; then
    cecho "$GRAY" "  Repository already cloned at $REPO_PATH -- skipping clone step."
else
    if flatpak --user info io.github.shiftey.Desktop >/dev/null 2>&1; then
        # Launch in background so the script can continue to its prompt.
        ( flatpak run io.github.shiftey.Desktop >/dev/null 2>&1 & )
        cecho "$GRAY" "  GitHub Desktop launched."
    else
        cecho "$YELLOW" "  GitHub Desktop Flatpak not found -- launch it manually from Activities."
    fi

    echo
    cecho "$CYAN" "  MANUAL STEPS in GitHub Desktop:"
    cecho "$CYAN" "    1. Sign in to GitHub (if not already signed in)."
    cecho "$CYAN" "       Use the team's GitHub account: $GITHUB_USER"
    cecho "$CYAN" "    2. File > Clone Repository > URL tab"
    cecho "$CYAN" "         URL:        $FORK_URL"
    cecho "$CYAN" "         Local path: $REPO_PATH"
    cecho "$CYAN" "       Click Clone."
    cecho "$CYAN" "    3. When asked 'How are you planning to use this fork?':"
    cecho "$CYAN" "         Select 'For my own purposes'."
    cecho "$CYAN" "         Do NOT select 'To contribute to the parent project'."
    cecho "$CYAN" "         (Team repos are downstream-only; chapter updates flow one direction.)"
    echo
    read -r -p "  Press Enter after the clone is complete: " _

    if [[ ! -d "$REPO_PATH/.git" ]]; then
        echo
        cecho "$RED" "ERROR: Clone not detected at $REPO_PATH."
        echo
        cecho "$YELLOW" "If you'd rather clone from the command line, open a terminal and run:"
        cecho "$GRAY"   "  git clone $FORK_URL \"$REPO_PATH\""
        cecho "$YELLOW" "Then re-run this script -- it is safe to re-run."
        exit 1
    fi
    cecho "$GREEN" "  Clone detected at $REPO_PATH."
fi
echo

# =============================================================================
# 9. POST-CLONE REPO SETUP -- UPSTREAM, VENV, PACKAGES, WORKSPACE SETTINGS
# =============================================================================

cecho "$YELLOW" "[9/9] Configuring repo: upstream remote, Python venv, packages, VS Code workspace..."

pushd "$REPO_PATH" >/dev/null

# 9a. Add upstream remote if not configured.
if ! git remote | grep -q '^upstream$'; then
    git remote add upstream "$UPSTREAM_URL"
    cecho "$GRAY" "  Added upstream remote: $UPSTREAM_URL"
else
    cecho "$GRAY" "  Upstream remote already configured -- skipping."
fi

# 9b. Create .venv if not present.
VENV_PYTHON="$REPO_PATH/.venv/bin/python"
if [[ ! -x "$VENV_PYTHON" ]]; then
    cecho "$GRAY" "  Creating Python virtual environment in .venv..."
    "$PYTHON_BIN" -m venv .venv
    if [[ ! -x "$VENV_PYTHON" ]]; then
        cecho "$RED" "Failed to create .venv. Check that python3.12 is installed (try: sudo dnf reinstall python3.12)."
        popd >/dev/null
        exit 1
    fi
else
    cecho "$GRAY" "  Python venv already exists -- skipping creation."
fi

# 9c. Upgrade pip inside the venv.
cecho "$GRAY" "  Upgrading pip in .venv..."
"$VENV_PYTHON" -m pip install --upgrade pip --quiet

# 9d. Install pybricks and pybricksdev.
cecho "$GRAY" "  Installing pybricks and pybricksdev..."
"$VENV_PYTHON" -m pip install pybricks pybricksdev --quiet
cecho "$GRAY" "  Packages installed."

# 9e. Write workspace .vscode/settings.json so VS Code auto-selects the venv.
WORKSPACE_SETTINGS_DIR="$REPO_PATH/.vscode"
WORKSPACE_SETTINGS_PATH="$WORKSPACE_SETTINGS_DIR/settings.json"
VENV_PYTHON_RELATIVE=".venv/bin/python"

mkdir -p "$WORKSPACE_SETTINGS_DIR"

if [[ -f "$WORKSPACE_SETTINGS_PATH" ]]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$WORKSPACE_SETTINGS_PATH" "$VENV_PYTHON_RELATIVE" <<'PYEOF'
import json, sys
path, venv = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("settings.json root is not an object")
except Exception as e:
    sys.stderr.write(f"Could not parse {path}: {e}\n")
    sys.exit(2)
data["python.defaultInterpreterPath"] = venv
with open(path, "w") as f:
    json.dump(data, f, indent=4)
    f.write("\n")
PYEOF
        if [[ $? -eq 0 ]]; then
            cecho "$GRAY" "  Merged python.defaultInterpreterPath into existing .vscode/settings.json"
        else
            cecho "$YELLOW" "  Could not parse existing .vscode/settings.json; leaving it untouched."
            cecho "$YELLOW" "  Set the interpreter manually in VS Code:"
            cecho "$YELLOW" "  Ctrl+Shift+P -> Python: Select Interpreter -> .venv"
        fi
    else
        cecho "$YELLOW" "  python3 not available for merge; leaving existing .vscode/settings.json untouched."
    fi
else
    cat > "$WORKSPACE_SETTINGS_PATH" <<EOF
{
    "python.defaultInterpreterPath": "$VENV_PYTHON_RELATIVE"
}
EOF
    cecho "$GRAY" "  Wrote .vscode/settings.json with Python interpreter path."
fi

popd >/dev/null

cecho "$GREEN" "  Repo setup complete."
echo

# =============================================================================
# DONE
# =============================================================================

cecho "$CYAN" "==============================================================="
cecho "$CYAN" " Setup complete for Team $TEAM_NUMBER ($TEAM_NAME)"
cecho "$CYAN" "==============================================================="
echo
cecho "$YELLOW" "REMAINING MANUAL STEPS:"
cecho "$WHITE" "  1. (Optional) Sign in to Chrome with $TEAM_EMAIL"
echo         "       Note: Chrome requires a Google account."
echo         "       Outlook.com teams cannot sign in to Chrome -- skip this step."
cecho "$WHITE" "  2. Find the team shortcuts:"
echo         "       Press the Super (Windows) key and type 'Open Team' --"
echo         "       the three launchers appear in the Activities overview."
echo         "       Right-click any one to 'Add to Favorites' (dash pin)."
echo         "       Desktop icons require the 'Desktop Icons NG' extension."
cecho "$WHITE" "  3. Launch VS Code via 'Open Team $TEAM_NUMBER Code'."
echo         "       Verify the venv shows in the bottom-right status bar"
echo         "       (should display '.venv': Python 3.12.x). If it doesn't:"
echo         "       Ctrl+Shift+P -> Python: Select Interpreter -> .venv"
cecho "$WHITE" "  4. Open menu.py in VS Code and confirm pybricks imports do not"
echo         "       trigger 'Import could not be resolved' errors."
cecho "$WHITE" "  5. Connect to a SPIKE Prime hub and run a test program:"
echo         "         python3.12 -m pybricksdev run ble --name <hub-name> main.py"
cecho "$WHITE" "  6. GitHub Desktop is the chapter-standard GUI client on Linux."
echo         "       The Flatpak fork (io.github.shiftey.Desktop) was installed in step 1."
echo         "       Pin it to the dash from Activities for easy daily access."
echo
cecho "$GRAY" "If anything went wrong, the script is safe to re-run."
echo
