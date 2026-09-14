#!/usr/bin/env bash
# =============================================================================
# reconfigure-fll-laptop-linux.sh
#
# SYNOPSIS
#   Re-team an already-provisioned Bolton Robotics FLL chapter laptop --
#   Linux (Fedora; should also work on recent Fedora releases and RHEL-family).
#
#   Takes a laptop that setup-fll-laptop-linux.sh previously configured for
#   one FLL team and switches it to a DIFFERENT team number, in place.
#
# DESCRIPTION
#   Run this ONCE on a laptop that is being handed from an old team to a new
#   one, while logged in as the student/team account (sudo via `wheel`).
#
#   Pass the NEW team number as the first argument. The OLD team number is
#   auto-detected from the existing team launchers (or ~/.gitconfig); pass it
#   as the second argument to override detection.
#
#   The script:
#     1. Safety-checks the existing ~/repos/spike_basecode clone for
#        uncommitted or unpushed work and makes you confirm the re-team
#     2. Removes the existing FLL codebase under ~/repos/spike_basecode
#     3. Logs out of GitHub (gh CLI, git credential cache) and walks you
#        through signing the OLD team out of GitHub Desktop
#     4. Rewrites ~/.gitconfig with the NEW team's identity
#     5. Swaps the team-numbered VS Code / Files / Terminal / GitHub Desktop
#        launchers (Activities + Desktop) and the Desktop README from the
#        old number to the new one
#     6. Repoints any dash (favorites) pins from the old launchers to the new
#     7. Launches GitHub Desktop and pauses for you to sign in as the NEW
#        team and clone its fork -- same UX as setup-fll-laptop-linux.sh
#     8. Configures the fresh clone (upstream remote, Python venv, pybricks +
#        pybricksdev, VS Code workspace settings) and runs the post-config
#        customizations, which set the NEW team's desktop background and
#        bookmarks
#
#   What it does NOT do (interactive, destructive, or out of scope):
#     - Reinstall core software. That is already present from the original
#       provisioning; this script assumes VS Code, Chrome, Python 3.12,
#       Flatpak, and GitHub Desktop are installed. Run
#       setup-fll-laptop-linux.sh instead if the laptop was never provisioned.
#     - Touch anything in the cloud. It only signs the OLD team OUT of this
#       laptop (GitHub Desktop, gh CLI, credential cache). The old team's
#       GitHub account, email, and remote fork are left completely alone --
#       that team number usually keeps running on other laptops, so its
#       cloud presence must stay intact.
#     - Wipe the OLD team's browser profile / Chrome sign-in. Sign the old
#       Google account out of Chrome manually if the laptop is changing hands.
#     - Empty the trash. The removed repo goes where `rm -rf` sends it (gone);
#       nothing is recoverable, which is why step 1 checks for unsaved work.
#
# NOTES
#   Author:   Steven Erat with Claude (Bolton Robotics chapter)
#   Audience: FLL chapter coaches re-teaming a laptop on Linux
#   Tested on: Fedora (GNOME / Wayland)
#
#   Run from a terminal:
#       chmod +x reconfigure-fll-laptop-linux.sh
#       ./reconfigure-fll-laptop-linux.sh 27042            # auto-detect old team
#       ./reconfigure-fll-laptop-linux.sh 27042 27041      # old team explicit
# =============================================================================

set -eo pipefail

# -----------------------------------------------------------------------------
# Color helpers  (identical palette to setup-fll-laptop-linux.sh)
# -----------------------------------------------------------------------------
CYAN='\033[36m'
YELLOW='\033[33m'
GREEN='\033[32m'
RED='\033[31m'
GRAY='\033[90m'
WHITE='\033[97m'
RESET='\033[0m'

cecho() { printf "%b%s%b\n" "$1" "$2" "$RESET"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# remap_favorites <favorite-apps-array-string>
# Rewrites a GNOME `favorite-apps` gsettings array (a Python-repr list of
# .desktop filenames), replacing the old team's launcher filenames with the
# new team's. Reads OLD_T / NEW_T from the environment. Prints the rewritten
# array; on any parse failure prints the input unchanged. Defined at top level
# (not inside a command substitution) so the double quotes in the Python body
# don't unbalance a surrounding quoted context.
remap_favorites() {
    python3 - "$1" <<'PYEOF'
import ast, os, sys
try:
    favs = ast.literal_eval(sys.argv[1])
    if not isinstance(favs, list):
        raise ValueError
except Exception:
    print(sys.argv[1])          # leave it untouched if we can't parse it
    sys.exit(0)
old, new = os.environ["OLD_T"], os.environ["NEW_T"]
mapped = [f.replace(f"fll-team-{old}-", f"fll-team-{new}-") for f in favs]
# de-dupe while preserving order (a new launcher may already be pinned)
seen, out = set(), []
for f in mapped:
    if f not in seen:
        seen.add(f); out.append(f)
print("[" + ", ".join("'" + f.replace("'", "\\'") + "'" for f in out) + "]")
PYEOF
}

# =============================================================================
# TEAM SELECTION  (same known-teams logic as setup-fll-laptop-linux.sh so the
# new-team identity is resolved identically)
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

REPOS_ROOT="$HOME/repos"
REPO_PATH="$REPOS_ROOT/spike_basecode"
DESKTOP_PATH="$HOME/Desktop"
APPS_PATH="$HOME/.local/share/applications"
GIT_CONFIG_PATH="$HOME/.gitconfig"

# Detect the OLD team number from the launchers this laptop already has.
# Launchers are named fll-team-<N>-code.desktop; fall back to the team number
# embedded in ~/.gitconfig ("Bolton Robotics FLL Team <N>").
detect_old_team() {
    local f base
    for f in "$APPS_PATH"/fll-team-*-code.desktop; do
        [[ -e "$f" ]] || continue
        base="${f##*/}"           # fll-team-27041-code.desktop
        base="${base#fll-team-}"  # 27041-code.desktop
        base="${base%-code.desktop}"
        if [[ "$base" =~ ^[0-9]+$ ]]; then
            echo "$base"
            return 0
        fi
    done
    if [[ -f "$GIT_CONFIG_PATH" ]]; then
        base="$(grep -oE 'Bolton Robotics FLL Team [0-9]+' "$GIT_CONFIG_PATH" 2>/dev/null | grep -oE '[0-9]+$' | head -n1)"
        [[ -n "$base" ]] && { echo "$base"; return 0; }
    fi
    return 1
}

NEW_TEAM_NUMBER="${1:-}"
OLD_TEAM_NUMBER="${2:-}"

# Resolve the OLD team number (auto-detect unless supplied).
if [[ -z "$OLD_TEAM_NUMBER" ]]; then
    OLD_TEAM_NUMBER="$(detect_old_team || true)"
fi

if [[ -z "$NEW_TEAM_NUMBER" ]]; then
    echo
    cecho "$CYAN" "Bolton Robotics FLL -- re-team this laptop."
    if [[ -n "$OLD_TEAM_NUMBER" ]]; then
        cecho "$GRAY" "  This laptop is currently set up for team $OLD_TEAM_NUMBER."
    else
        cecho "$YELLOW" "  Could not auto-detect the current team on this laptop."
    fi
    echo
    cecho "$CYAN" "Known teams:"
    for t in 18300 19991 27041 27042 62070; do
        name="$(team_default_name "$t")"
        [[ -z "$name" ]] && name="(unnamed)"
        echo "  $t  $name"
    done
    echo "  (or enter any other 5-digit number for a new team)"
    echo
    read -r -p "Enter the NEW team number for this laptop: " NEW_TEAM_NUMBER
fi

if [[ ! "$NEW_TEAM_NUMBER" =~ ^[0-9]+$ ]]; then
    cecho "$RED" "New team number must be numeric. Got: '$NEW_TEAM_NUMBER'"
    exit 1
fi

if [[ -z "$OLD_TEAM_NUMBER" ]]; then
    echo
    cecho "$YELLOW" "The current (old) team number could not be detected automatically."
    cecho "$YELLOW" "It is used only to remove the old launchers and Desktop README."
    read -r -p "Enter the OLD team number (press Enter to skip old-launcher cleanup): " OLD_TEAM_NUMBER
fi

if [[ -n "$OLD_TEAM_NUMBER" && "$OLD_TEAM_NUMBER" == "$NEW_TEAM_NUMBER" ]]; then
    cecho "$RED" "Old and new team numbers are the same ($NEW_TEAM_NUMBER). Nothing to re-team."
    cecho "$GRAY" "If you only want to refresh config, re-run setup-fll-laptop-linux.sh instead."
    exit 1
fi

# Resolve NEW team identity (known team -> defaults; otherwise prompt, exactly
# like setup-fll-laptop-linux.sh does for a brand-new team).
if ! team_is_known "$NEW_TEAM_NUMBER"; then
    echo
    cecho "$YELLOW" "Team $NEW_TEAM_NUMBER is NOT in the known teams list."
    cecho "$YELLOW" "This will re-team the laptop as a NEW team."
    cecho "$YELLOW" "(If you meant an existing team, this is a good moment to check for a typo.)"
    read -r -p "Continue re-teaming to new team $NEW_TEAM_NUMBER? (Y/n) " confirm
    if [[ -n "$confirm" && ! "$confirm" =~ ^[Yy] ]]; then
        cecho "$RED" "Cancelled. Run the script again with the correct team number."
        exit 1
    fi

    echo
    cecho "$CYAN" "Enter team email."
    cecho "$CYAN" "Chapter standard format examples (do not press Enter to accept -- type the actual email):"
    cecho "$GRAY" "  fss.fll.${NEW_TEAM_NUMBER}@gmail.com"
    cecho "$GRAY" "  fss.fll.${NEW_TEAM_NUMBER}@outlook.com"
    read -r -p "Team email: " NEW_EMAIL
    while [[ -z "$NEW_EMAIL" || "$NEW_EMAIL" != *"@"* ]]; do
        cecho "$YELLOW" "Email is required and must contain '@'."
        read -r -p "Team email: " NEW_EMAIL
    done

    echo
    read -r -p "Team display name (optional; press Enter to skip): " NEW_NAME

    echo
    DEFAULT_GH_USER="fssfll$NEW_TEAM_NUMBER"
    read -r -p "GitHub username (press Enter for '$DEFAULT_GH_USER'): " NEW_GH_USER
    [[ -z "$NEW_GH_USER" ]] && NEW_GH_USER="$DEFAULT_GH_USER"

    TEAM_NAME="$NEW_NAME"
    TEAM_EMAIL="$NEW_EMAIL"
    GITHUB_USER="$NEW_GH_USER"
else
    TEAM_NAME="$(team_default_name "$NEW_TEAM_NUMBER")"
    TEAM_EMAIL="$(team_default_email "$NEW_TEAM_NUMBER")"
    GITHUB_USER="fssfll$NEW_TEAM_NUMBER"
fi

[[ -z "$TEAM_NAME" ]] && TEAM_NAME="Bolton Robotics Team $NEW_TEAM_NUMBER"

GIT_USER_NAME="Bolton Robotics FLL Team $NEW_TEAM_NUMBER"
GIT_USER_EMAIL="$TEAM_EMAIL"
FORK_URL="https://github.com/$GITHUB_USER/spike_basecode.git"
UPSTREAM_URL="https://github.com/stevenerat/spike_basecode.git"

# =============================================================================
# PRELIMINARIES
# =============================================================================

if [[ "$(uname -s)" != "Linux" ]]; then
    cecho "$RED" "This script targets Linux. Detected: $(uname -s)"
    exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
    cecho "$RED" "Do NOT run this script with sudo or as root."
    cecho "$RED" "Run as the student/team user. You'll be prompted for the admin password when needed."
    exit 1
fi

mkdir -p "$DESKTOP_PATH" "$APPS_PATH" "$REPOS_ROOT"

echo
cecho "$CYAN" "==============================================================="
cecho "$CYAN" " FLL Laptop RE-TEAM (Linux)"
cecho "$CYAN" "   From team: ${OLD_TEAM_NUMBER:-<unknown>}"
cecho "$CYAN" "   To team:   $NEW_TEAM_NUMBER ($TEAM_NAME)"
cecho "$CYAN" "   Email:     $TEAM_EMAIL"
cecho "$CYAN" "   GitHub:    $GITHUB_USER"
cecho "$CYAN" "==============================================================="
echo

# =============================================================================
# 1. SAFETY CHECK -- UNSAVED WORK IN THE OLD CLONE, THEN CONFIRM
# =============================================================================

cecho "$YELLOW" "[1/8] Checking the existing clone for unsaved work..."

WORK_AT_RISK=0
if [[ -d "$REPO_PATH/.git" ]]; then
    pushd "$REPO_PATH" >/dev/null

    # Uncommitted changes in the working tree / index (offline, no network).
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        WORK_AT_RISK=1
        cecho "$RED" "  ! Uncommitted changes exist in $REPO_PATH:"
        git status --short 2>/dev/null | sed 's/^/      /'
    fi

    # Commits on any local branch that are not on any remote (offline check).
    UNPUSHED="$(git log --branches --not --remotes --oneline 2>/dev/null || true)"
    if [[ -n "$UNPUSHED" ]]; then
        WORK_AT_RISK=1
        cecho "$RED" "  ! Local commits that were never pushed to a remote:"
        printf '%s\n' "$UNPUSHED" | sed 's/^/      /'
    fi

    popd >/dev/null

    if [[ "$WORK_AT_RISK" -eq 1 ]]; then
        echo
        cecho "$YELLOW" "  The old team has work that is NOT on GitHub. Deleting this clone"
        cecho "$YELLOW" "  will LOSE it permanently. If in doubt, stop now and have the old"
        cecho "$YELLOW" "  team push (GitHub Desktop: Commit, then Push origin) before re-teaming."
        echo
        read -r -p "  Type DELETE to confirm you want to discard the above and continue: " gate
        if [[ "$gate" != "DELETE" ]]; then
            cecho "$RED" "  Cancelled. Nothing has been changed."
            exit 1
        fi
    else
        cecho "$GRAY" "  No uncommitted or unpushed work found -- safe to remove."
    fi
else
    cecho "$GRAY" "  No existing clone at $REPO_PATH -- nothing to preserve."
fi

echo
cecho "$YELLOW" "  This will reconfigure THIS laptop from team ${OLD_TEAM_NUMBER:-<unknown>} to team $NEW_TEAM_NUMBER:"
cecho "$WHITE" "    - delete $REPO_PATH"
cecho "$WHITE" "    - log out of GitHub and sign in as $GITHUB_USER"
cecho "$WHITE" "    - clone $FORK_URL"
cecho "$WHITE" "    - swap the team shortcuts, README, wallpaper, and bookmarks"
echo
read -r -p "  Type the NEW team number ($NEW_TEAM_NUMBER) to proceed: " proceed
if [[ "$proceed" != "$NEW_TEAM_NUMBER" ]]; then
    cecho "$RED" "  Confirmation did not match. Cancelled. Nothing has been changed."
    exit 1
fi
cecho "$GREEN" "  Confirmed. Re-teaming in place."
echo

# =============================================================================
# 2. LOG OUT OF GITHUB (ON THIS LAPTOP ONLY)
# =============================================================================
#
# This only clears the old team's stored sign-in ON THIS MACHINE. The team's
# GitHub account and its fork in the cloud are never touched -- the old team
# number typically keeps running on other laptops.

cecho "$YELLOW" "[2/8] Logging out of the old team's GitHub on this laptop..."

# 2a. gh CLI (only if installed and actually signed in). Coaches who use the
#     CLI fallback may have an active gh session tied to the old team.
if command -v gh >/dev/null 2>&1; then
    if gh auth status --hostname github.com >/dev/null 2>&1; then
        gh auth logout --hostname github.com 2>/dev/null \
            && cecho "$GRAY" "  gh CLI signed out of github.com." \
            || cecho "$YELLOW" "  gh CLI logout reported an issue -- check 'gh auth status' manually."
    else
        cecho "$GRAY" "  gh CLI not signed in -- nothing to do."
    fi
else
    cecho "$GRAY" "  gh CLI not installed -- skipping."
fi

# 2b. Flush the 8-hour in-memory git credential cache configured in .gitconfig,
#     so the old team's PAT can't be silently reused.
git credential-cache exit 2>/dev/null || true
cecho "$GRAY" "  Cleared git credential cache."

# 2c. GitHub Desktop stores its account + token in the app config and the GNOME
#     Keyring; there is no reliable CLI to sign it out. Do it in the app.
echo
cecho "$CYAN" "  MANUAL STEP in GitHub Desktop (sign the OLD team out):"
cecho "$CYAN" "    1. Open GitHub Desktop."
cecho "$CYAN" "    2. File > Options > Accounts > Sign out (of ${OLD_TEAM_NUMBER:+fssfll$OLD_TEAM_NUMBER}${OLD_TEAM_NUMBER:-the old team account})."
cecho "$CYAN" "    You'll sign in as the NEW team ($GITHUB_USER) in step 7."
if flatpak --user info io.github.shiftey.Desktop >/dev/null 2>&1; then
    ( flatpak run io.github.shiftey.Desktop >/dev/null 2>&1 & )
    cecho "$GRAY" "  GitHub Desktop launched."
fi
read -r -p "  Press Enter once the old team is signed out of GitHub Desktop: " _
echo

# =============================================================================
# 3. REMOVE THE OLD FLL CODEBASE
# =============================================================================

cecho "$YELLOW" "[3/8] Removing the old FLL codebase..."

# Belt-and-suspenders: only ever remove the known chapter repo path, and only
# if it looks like our clone (has a .git) or is empty. Never touch anything else.
if [[ -d "$REPO_PATH" ]]; then
    if [[ -d "$REPO_PATH/.git" || -z "$(ls -A "$REPO_PATH" 2>/dev/null)" ]]; then
        rm -rf "$REPO_PATH"
        cecho "$GRAY" "  Removed $REPO_PATH"
    else
        cecho "$RED" "  $REPO_PATH exists but is not a git clone. Leaving it untouched for safety."
        cecho "$RED" "  Inspect it, then remove it by hand and re-run this script."
        exit 1
    fi
else
    cecho "$GRAY" "  $REPO_PATH already absent -- nothing to remove."
fi
cecho "$GREEN" "  Old codebase removed."
echo

# =============================================================================
# 4. REWRITE ~/.gitconfig FOR THE NEW TEAM
# =============================================================================

cecho "$YELLOW" "[4/8] Rewriting .gitconfig for the new team identity..."

# Same template as setup-fll-laptop-linux.sh; only the [user] block differs
# between teams. Re-running OVERWRITES the file -- manual edits are lost.
cat > "$GIT_CONFIG_PATH" <<EOF
# ~/.gitconfig -- FLL chapter laptop (Linux)
# Generated by reconfigure-fll-laptop-linux.sh -- re-running overwrites this file.

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

cecho "$GREEN" "  .gitconfig now identifies $GIT_USER_NAME <$GIT_USER_EMAIL>."
echo

# =============================================================================
# 5. SWAP TEAM LAUNCHERS AND DESKTOP README
# =============================================================================

cecho "$YELLOW" "[5/8] Swapping team shortcuts and Desktop README..."

# Helper: write a .desktop file in $APPS_PATH (Activities) and a duplicate in
# $DESKTOP_PATH (Desktop Icons NG). Identical to setup-fll-laptop-linux.sh.
make_desktop_entry() {
    local filename="$1"
    local content="$2"
    local apps_file="$APPS_PATH/$filename"
    local desktop_file="$DESKTOP_PATH/$filename"

    echo "$content" > "$apps_file"
    chmod +x "$apps_file"
    cp "$apps_file" "$desktop_file"
    chmod +x "$desktop_file"
    gio set "$desktop_file" metadata::trusted true 2>/dev/null || true
}

# 5a. Remove the OLD team's launchers + README (both locations), if we know the
#     old number. Track the old launcher filenames for the favorites fix-up.
OLD_LAUNCHERS=()
if [[ -n "$OLD_TEAM_NUMBER" ]]; then
    for kind in code folder terminal github-desktop; do
        fname="fll-team-${OLD_TEAM_NUMBER}-${kind}.desktop"
        OLD_LAUNCHERS+=("$fname")
        rm -f "$APPS_PATH/$fname" "$DESKTOP_PATH/$fname"
    done
    rm -f "$DESKTOP_PATH/README - Team $OLD_TEAM_NUMBER.txt"
    cecho "$GRAY" "  Removed team $OLD_TEAM_NUMBER launchers and README."
else
    cecho "$YELLOW" "  Old team unknown -- leaving any old launchers in place."
fi

# 5b. Create the NEW team's launchers (same four as the setup script).
make_desktop_entry "fll-team-${NEW_TEAM_NUMBER}-code.desktop" "[Desktop Entry]
Type=Application
Name=Open Team $NEW_TEAM_NUMBER Code
Comment=Open the Team $NEW_TEAM_NUMBER repo in VS Code
Exec=code \"$REPO_PATH\"
Icon=visual-studio-code
Terminal=false
Categories=Development;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: Open Team $NEW_TEAM_NUMBER Code"

make_desktop_entry "fll-team-${NEW_TEAM_NUMBER}-folder.desktop" "[Desktop Entry]
Type=Application
Name=Team $NEW_TEAM_NUMBER Repo Folder
Comment=Open the Team $NEW_TEAM_NUMBER repo folder in Files
Exec=xdg-open \"$REPO_PATH\"
Icon=folder
Terminal=false
Categories=Utility;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: Team $NEW_TEAM_NUMBER Repo Folder"

make_desktop_entry "fll-team-${NEW_TEAM_NUMBER}-terminal.desktop" "[Desktop Entry]
Type=Application
Name=Terminal (Team $NEW_TEAM_NUMBER)
Comment=Open a terminal in the Team $NEW_TEAM_NUMBER repo folder
Exec=bash -c \"cd '$REPO_PATH' && exec bash --login\"
Icon=utilities-terminal
Terminal=true
Categories=System;TerminalEmulator;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: Terminal (Team $NEW_TEAM_NUMBER)"

make_desktop_entry "fll-team-${NEW_TEAM_NUMBER}-github-desktop.desktop" "[Desktop Entry]
Type=Application
Name=GitHub Desktop
Comment=Launch GitHub Desktop (shiftkey Linux fork)
Exec=flatpak run io.github.shiftey.Desktop
Icon=io.github.shiftey.Desktop
Terminal=false
Categories=Development;
StartupNotify=true"
cecho "$GRAY" "  Created launcher: GitHub Desktop"

# 5c. Rewrite the Desktop README for the new team (same content as setup).
cat > "$DESKTOP_PATH/README - Team $NEW_TEAM_NUMBER.txt" <<EOF
TEAM $NEW_TEAM_NUMBER - $TEAM_NAME
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
    Open the 'Terminal (Team $NEW_TEAM_NUMBER)' shortcut, then run:
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

cecho "$GREEN" "  Shortcuts and README now reference team $NEW_TEAM_NUMBER."
echo

# =============================================================================
# 6. REPOINT DASH FAVORITES FROM OLD LAUNCHERS TO NEW
# =============================================================================

cecho "$YELLOW" "[6/8] Updating dash (favorites) pins..."

# If the old launchers were pinned to the dash, the favorite-apps gsettings
# array still points at the old filenames (now deleted) and would show blanks.
# Rewrite it, mapping each old team launcher to its new-team counterpart.
if [[ ${#OLD_LAUNCHERS[@]} -gt 0 ]] && command -v gsettings >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    CURRENT_FAVS="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo '[]')"
    NEW_FAVS="$(OLD_T="$OLD_TEAM_NUMBER" NEW_T="$NEW_TEAM_NUMBER" remap_favorites "$CURRENT_FAVS")"
    if [[ "$NEW_FAVS" != "$CURRENT_FAVS" ]]; then
        gsettings set org.gnome.shell favorite-apps "$NEW_FAVS" 2>/dev/null \
            && cecho "$GRAY" "  Repointed dash pins to the team $NEW_TEAM_NUMBER launchers." \
            || cecho "$YELLOW" "  Could not update favorites; re-pin the launchers manually if needed."
    else
        cecho "$GRAY" "  No old team launchers were pinned -- nothing to repoint."
    fi
else
    cecho "$GRAY" "  Skipping favorites update (old team unknown or gsettings/python3 unavailable)."
fi
cecho "$GREEN" "  Dash pins handled."
echo

# =============================================================================
# 7. GITHUB DESKTOP SIGN-IN AS NEW TEAM AND CLONE (INTERACTIVE PAUSE)
# =============================================================================

cecho "$YELLOW" "[7/8] Sign in as the new team and clone its fork..."

if [[ -d "$REPO_PATH/.git" ]]; then
    cecho "$GRAY" "  Repository already present at $REPO_PATH -- skipping clone."
else
    if flatpak --user info io.github.shiftey.Desktop >/dev/null 2>&1; then
        ( flatpak run io.github.shiftey.Desktop >/dev/null 2>&1 & )
        cecho "$GRAY" "  GitHub Desktop launched."
    else
        cecho "$YELLOW" "  GitHub Desktop Flatpak not found -- launch it manually from Activities."
    fi

    echo
    cecho "$CYAN" "  MANUAL STEPS in GitHub Desktop:"
    cecho "$CYAN" "    1. Sign in to GitHub as the NEW team account: $GITHUB_USER"
    cecho "$CYAN" "    2. File > Clone Repository > URL tab"
    cecho "$CYAN" "         URL:        $FORK_URL"
    cecho "$CYAN" "         Local path: $REPO_PATH"
    cecho "$CYAN" "       Click Clone."
    cecho "$CYAN" "    3. When asked 'How are you planning to use this fork?':"
    cecho "$CYAN" "         Select 'For my own purposes'."
    cecho "$CYAN" "         Do NOT select 'To contribute to the parent project'."
    echo
    read -r -p "  Press Enter after the clone is complete: " _

    if [[ ! -d "$REPO_PATH/.git" ]]; then
        echo
        cecho "$RED" "ERROR: Clone not detected at $REPO_PATH."
        cecho "$YELLOW" "If you'd rather clone from the command line, run:"
        cecho "$GRAY"   "  git clone $FORK_URL \"$REPO_PATH\""
        cecho "$YELLOW" "Then re-run this script -- it is safe to re-run."
        exit 1
    fi
    cecho "$GREEN" "  Clone detected at $REPO_PATH."
fi
echo

# =============================================================================
# 8. CONFIGURE THE FRESH CLONE + POST-CONFIG CUSTOMIZATIONS
# =============================================================================

cecho "$YELLOW" "[8/8] Configuring repo (upstream, venv, packages, workspace) and post-config..."

PYTHON_BIN="$(command -v python3.12 || command -v python3 || true)"
if [[ -z "$PYTHON_BIN" ]]; then
    cecho "$RED" "  No python3.12/python3 on PATH. Install Python 3.12 and re-run this script."
    exit 1
fi

pushd "$REPO_PATH" >/dev/null

# 8a. Upstream remote.
if ! git remote | grep -q '^upstream$'; then
    git remote add upstream "$UPSTREAM_URL"
    cecho "$GRAY" "  Added upstream remote: $UPSTREAM_URL"
else
    cecho "$GRAY" "  Upstream remote already configured -- skipping."
fi

# 8b. Fresh .venv for the new clone. (Old venv died with the old repo.)
VENV_PYTHON="$REPO_PATH/.venv/bin/python"
if [[ ! -x "$VENV_PYTHON" ]]; then
    cecho "$GRAY" "  Creating Python virtual environment in .venv..."
    "$PYTHON_BIN" -m venv .venv
    if [[ ! -x "$VENV_PYTHON" ]]; then
        cecho "$RED" "Failed to create .venv. Check that Python 3.12 is installed."
        popd >/dev/null
        exit 1
    fi
else
    cecho "$GRAY" "  Python venv already exists -- skipping creation."
fi

# 8c. pip upgrade + pybricks packages.
cecho "$GRAY" "  Upgrading pip and installing pybricks + pybricksdev..."
"$VENV_PYTHON" -m pip install --upgrade pip --quiet
"$VENV_PYTHON" -m pip install pybricks pybricksdev --quiet
cecho "$GRAY" "  Packages installed."

# 8d. VS Code workspace settings -> select the venv interpreter.
WORKSPACE_SETTINGS_DIR="$REPO_PATH/.vscode"
WORKSPACE_SETTINGS_PATH="$WORKSPACE_SETTINGS_DIR/settings.json"
VENV_PYTHON_RELATIVE=".venv/bin/python"
mkdir -p "$WORKSPACE_SETTINGS_DIR"

if [[ -f "$WORKSPACE_SETTINGS_PATH" ]] && command -v python3 >/dev/null 2>&1; then
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
        cecho "$GRAY" "  Merged python.defaultInterpreterPath into .vscode/settings.json"
    else
        cecho "$YELLOW" "  Could not parse .vscode/settings.json; set the interpreter manually in VS Code."
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

# 8e. Post-config customizations: NEW team wallpaper + bookmarks (+ dock, venv
#     hook -- both idempotent). Reuse the existing script so the wallpaper and
#     bookmark logic stay in one place; fall back to an inline wallpaper set if
#     that script isn't alongside this one.
POST_CONFIG="$SCRIPT_DIR/linux-post-config-customizations.sh"
if [[ -f "$POST_CONFIG" ]]; then
    cecho "$GRAY" "  Running post-config customizations for team $NEW_TEAM_NUMBER..."
    cecho "$GRAY" "  (sets the team wallpaper and bookmarks; may prompt for sudo)"
    bash "$POST_CONFIG" "$NEW_TEAM_NUMBER" \
        || cecho "$YELLOW" "  Post-config script returned non-zero -- review its output above."
else
    cecho "$YELLOW" "  linux-post-config-customizations.sh not found next to this script."
    cecho "$YELLOW" "  Setting the team wallpaper inline; bookmarks were NOT updated."
    ASSET_BASE="https://raw.githubusercontent.com/stevenerat/spike_basecode/main/assets"
    BG_DIR="$HOME/.local/share/backgrounds"; mkdir -p "$BG_DIR"
    BG_NAME="laptop_background.png"
    if curl -sfI "$ASSET_BASE/laptop_background_${NEW_TEAM_NUMBER}.jpg" >/dev/null 2>&1; then
        BG_NAME="laptop_background_${NEW_TEAM_NUMBER}.jpg"
    fi
    if curl -sfL "$ASSET_BASE/$BG_NAME" -o "$BG_DIR/$BG_NAME"; then
        gsettings set org.gnome.desktop.background picture-uri      "file://$BG_DIR/$BG_NAME" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-uri-dark "file://$BG_DIR/$BG_NAME" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-options  'zoom' 2>/dev/null || true
        cecho "$GRAY" "  Wallpaper set to $BG_NAME."
    else
        cecho "$YELLOW" "  Could not download wallpaper; set it manually in Settings > Background."
    fi
fi

cecho "$GREEN" "  Repo and post-config complete."
echo

# =============================================================================
# DONE
# =============================================================================

cecho "$CYAN" "==============================================================="
cecho "$CYAN" " Re-team complete: now set up for Team $NEW_TEAM_NUMBER ($TEAM_NAME)"
cecho "$CYAN" "==============================================================="
echo
cecho "$YELLOW" "REMAINING MANUAL STEPS:"
cecho "$WHITE" "  1. If the old team was signed in to Chrome, sign that Google account"
echo         "       out (Chrome > Profile > Sign out) and sign in as $TEAM_EMAIL"
echo         "       (Gmail teams only; Chrome does not accept Outlook accounts)."
cecho "$WHITE" "  2. Confirm the dash pins now show the team $NEW_TEAM_NUMBER launchers."
echo         "       If any are blank, right-click > Remove, then re-pin from Activities"
echo         "       (Super, type 'Open Team')."
cecho "$WHITE" "  3. Launch VS Code via 'Open Team $NEW_TEAM_NUMBER Code' and verify the"
echo         "       bottom-right status bar shows the .venv Python 3.12 interpreter."
cecho "$WHITE" "  4. Log out and back in so the wallpaper and any dock changes apply."
cecho "$WHITE" "  5. Connect a SPIKE Prime hub and run a test program:"
echo         "         python3.12 -m pybricksdev run ble --name <hub-name> main.py"
echo
cecho "$GRAY" "If anything went wrong, the script is safe to re-run."
echo
