#!/bin/zsh
# Uninstalls Editor Workflow from this Mac: every installed copy, the login item,
# the launch agent, preferences and caches. Optional: your library data.
# Your footage, copied folders and Resolve projects are never touched.
# Usage: double-click, or  ./Uninstall\ Editor\ Workflow.command [--yes] [--purge]
set -u

APP_NAME="Editor Workflow"
BUNDLE_ID="app.editorworkflow.mac"
SUPPORT="$HOME/Library/Application Support/EditorWorkflow"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

ASSUME_YES=0
PURGE=0
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge)  PURGE=1 ;;
    --help|-h)
      print -r -- "usage: $0 [--yes]   remove without asking"
      print -r -- "       $0 --purge  also delete templates, history and logs"
      exit 0 ;;
  esac
done

say()  { print -r -- "$@" }
step() { say "  - $1" }
done_() { say "  done: $1" }

# 1. Find every copy of the app: any version, any place it may have been unzipped.
typeset -a copies
copies=(/Applications/"$APP_NAME"*.app(N)
        ~/Applications/"$APP_NAME"*.app(N)
        ~/Downloads/"$APP_NAME"*.app(N)
        ~/Desktop/"$APP_NAME"*.app(N))
typeset -a found
found=()
for c in "${copies[@]}"; do
  [[ -e "$c" ]] || continue
  duplicate=0
  for f in "${found[@]}"; do [[ "$f" == "$c" ]] && duplicate=1; done
  (( duplicate )) || found+=("$c")
done

say "Uninstall $APP_NAME"
say ""
if (( ${#found} )); then
  say "Copies found:"
  for f in "${found[@]}"; do say "  $f"; done
else
  say "No app copy found (data may still be installed)."
fi
[[ -d "$SUPPORT" ]] && say "Library data: $SUPPORT"
say "Footage, copied folders and Resolve projects are kept."
say ""

ask() {  # $1 = question, $2 = default (y/n), empty answer takes the default
  (( ASSUME_YES )) && return 0
  local reply
  print -n "$1"
  read -r reply
  if [[ -z "$reply" ]]; then [[ "$2" == y ]]; else [[ "$reply" == [Yy]* ]]; fi
}

PURGE_DATA=0
if (( PURGE )); then
  PURGE_DATA=1
elif [[ -d "$SUPPORT" ]]; then
  ask "Delete your library too (templates, project history, logs)? [y/N] " n && PURGE_DATA=1
fi
ask "Remove $APP_NAME now? [Y/n] " y || {
  say "Cancelled. Nothing was removed."
  exit 1
}
say ""

# 2. Stop it if a copy we are about to remove is running (main app, menu bar companion, panel).
#    A build folder left running elsewhere is the developer's, not this uninstaller's to stop.
if (( ${#found} )); then
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1
  pkill -x EditorWorkflow >/dev/null 2>&1
  sleep 1
fi

# 3. Every app copy.
for f in "${found[@]}"; do
  rm -rf "$f" 2>/dev/null && step "removed $f"
done
(( ${#found} )) || say "  (no app copy to remove)"

# 4. Open at login: the launch agent file, then the app's registration.
[[ -f "$AGENT" ]] && rm -f "$AGENT" && step "removed launch agent"
# The system login item entry (SMAppService) dies with the app bundle; macOS clears it on the
# next pass. If it still shows, System Settings › General › Login Items holds a Remove button.

# 5. Preferences, caches, saved state.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && step "removed preferences"
rm -rf "$HOME/Library/Preferences/$BUNDLE_ID.plist" 2>/dev/null
rm -rf "$HOME/Library/Caches/$BUNDLE_ID" 2>/dev/null && step "removed caches"
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" 2>/dev/null

# 6. Library data (your templates, history, logs) — only when asked.
if (( PURGE_DATA )); then
  rm -rf "$SUPPORT" 2>/dev/null && step "removed library data"
else
  [[ -d "$SUPPORT" ]] && say "  kept library data: $SUPPORT"
fi

say ""
say "$APP_NAME is uninstalled."
(( PURGE_DATA )) || say "To finish removing your data later: rm -rf \"$SUPPORT\""
say ""
say "Press Return to close."
(( ASSUME_YES )) || read -r
# This file travels in /Applications beside the app: once the app is gone, it goes too.
case "$0" in
  /Applications/*.command) rm -f "$0" 2>/dev/null ;;
esac
exit 0
