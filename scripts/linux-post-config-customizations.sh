
Linux Gnome desktop customizations · SH
#!/usr/bin/env bash
#
# linux-post-config-customizations.sh
# ------------------------------------------------------------------
# Bolton FLL post-provisioning customizations that setup-fll-laptop-linux.sh
# does NOT perform: left-pinned dock, team wallpaper, and seeded bookmarks.
#
# Run this AFTER setup-fll-laptop-linux.sh has finished (repo cloned to
# ~/repos/spike_basecode and Chrome installed).
#
# Run as the FLL user, NOT root, in a terminal on the laptop's own desktop
# session (gsettings/dconf need the live GNOME session). It will prompt for
# sudo only for the package install and the Chrome policy file.
#
# Usage:  ./bolton-customizations.sh <TeamNumber>     # team number optional
# ------------------------------------------------------------------
set -euo pipefail
 
TEAM="${1:-}"
REPO="$HOME/repos/spike_basecode"
ASSET_BASE="https://raw.githubusercontent.com/stevenerat/spike_basecode/main/assets"
 
log() { printf '\n\033[1;34m[bolton]\033[0m %s\n' "$*"; }
 
# ------------------------------------------------------------------
# 1. Dock — Dash to Dock, pinned left, always visible (no autohide)
# ------------------------------------------------------------------
configure_dock() {
  log "Dock: installing Dash to Dock, pinning left, disabling autohide"
  if ! rpm -q gnome-shell-extension-dash-to-dock >/dev/null 2>&1; then
    sudo dnf install -y gnome-shell-extension-dash-to-dock
  fi
  gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null || true
 
  local DTD=/org/gnome/shell/extensions/dash-to-dock
  dconf write $DTD/dock-position "'LEFT'"
  dconf write $DTD/dock-fixed    true      # always visible on the desktop
  dconf write $DTD/autohide      false
  dconf write $DTD/intellihide   false
}
 
# ------------------------------------------------------------------
# 2. Desktop background — team-specific if it exists, else generic
# ------------------------------------------------------------------
set_background() {
  local dir="$HOME/.local/share/backgrounds"; mkdir -p "$dir"
  local name="laptop_background.png"
  if [ -n "$TEAM" ] && curl -sfI "$ASSET_BASE/laptop_background_${TEAM}.png" >/dev/null 2>&1; then
    name="laptop_background_${TEAM}.png"
  fi
  log "Background: $name"
  curl -sfL "$ASSET_BASE/$name" -o "$dir/$name"
  gsettings set org.gnome.desktop.background picture-uri      "file://$dir/$name"
  gsettings set org.gnome.desktop.background picture-uri-dark "file://$dir/$name"
  gsettings set org.gnome.desktop.background picture-options  'zoom'
}
 
# ------------------------------------------------------------------
# 3. Bookmarks — Chrome ManagedBookmarks policy (matches lockdown approach)
#    Read-only "FLL" folder on the bookmarks bar. file:// links need the repo
#    cloned first, so this runs after the script's clone step.
# ------------------------------------------------------------------
install_bookmarks() {
  log "Bookmarks: writing Chrome managed policy"
  local docs="$REPO/docs"
 
  # Only include the team GitHub link when the team number is known
  local team_bm=""
  if [ -n "$TEAM" ]; then
    team_bm='    { "name": "Team GitHub", "url": "https://github.com/fssfll'"${TEAM}"'" },
'
  fi
 
  sudo mkdir -p /etc/opt/chrome/policies/managed
  sudo tee /etc/opt/chrome/policies/managed/fll_bookmarks.json >/dev/null <<JSON
{
  "BookmarkBarEnabled": true,
  "ManagedBookmarks": [
    { "toplevel_name": "FLL" },
${team_bm}    { "name": "Chapter Docs",              "url": "https://fssfll.github.io/fssfll/spike/" },
    { "name": "Student VS Code + Git",     "url": "file://${docs}/student_vscode_git_use_guide.html" },
    { "name": "Getting Started w/ GitHub", "url": "file://${docs}/fss_fll_getting_started_with_github.html" },
    { "name": "GitHub Comic Book (PDF)",   "url": "file://${docs}/bolton_robotics_explorer_github_comic_book.pdf" }
  ]
}
JSON
}
 
main() {
  if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as the FLL user, not root." >&2
    exit 1
  fi
  configure_dock
  set_background
  install_bookmarks
  log "Done. Log out and back in for the dock and wallpaper to appear."
}
 
main "$@"
 

