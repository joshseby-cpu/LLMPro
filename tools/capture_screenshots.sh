#!/usr/bin/env bash
# Capture clean, window-only screenshots of LLMPro's main sections for the README.
#
# PREREQ: Claude.app (or whatever runs this) must have BOTH
#   System Settings → Privacy & Security → Screen Recording  (for screencapture)
#   System Settings → Privacy & Security → Accessibility      (for System Events clicks)
# enabled, and be restarted after granting.
#
# Output: docs/screenshots/<section>.png  (one per main sidebar tab)
#
# How it works: brings LLMPro to the front, finds its window id, then for each
# sidebar section clicks the row via System Events and grabs ONLY that window with
# `screencapture -l <windowid>` (no desktop, no dock, no shadow with -o).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/docs/screenshots"
mkdir -p "$OUT"

APP="LLMPro"
# Sidebar sections to capture: "RowLabel|filename". Row labels must match the
# sidebar text exactly (see RootView.SidebarSection.title).
SECTIONS=(
  "Home|home"
  "Models|models"
  "Lessons|lessons"
  "Teach|teach"
  "Progress|progress"
  "Try it out|chat"
  "Code|code"
  "Practice|practice"
  "Fusion|fusion"
  "Memory|memory"
  "Inspect|inspect"
  "Save & Use|export"
  "Settings|settings"
)

echo "Activating $APP…"
osascript -e "tell application \"$APP\" to activate"
sleep 1.5

# Get the CGWindowID of LLMPro's main window (first on-screen window).
get_window_id() {
  osascript <<'OSA'
tell application "System Events"
  tell process "LLMPro"
    if (count of windows) is 0 then return ""
    return id of window 1
  end tell
end tell
OSA
}

WID="$(get_window_id || true)"
if [[ -z "${WID:-}" ]]; then
  echo "Could not get window id (is Accessibility granted? is the app open?)." >&2
  echo "Falling back to interactive window capture — click the LLMPro window for each shot." >&2
  WID=""
fi

click_row() {  # $1 = row label
  osascript <<OSA
tell application "System Events"
  tell process "LLMPro"
    set frontmost to true
    try
      click (first UI element of outline 1 of scroll area 1 of splitter group 1 of window 1 whose value of attribute "AXValue" contains "$1")
    on error
      -- fallback: click static text by name anywhere in the window
      try
        click (first static text of window 1 whose value is "$1")
      end try
    end try
  end tell
end tell
OSA
}

shoot() {  # $1 = filename (no ext)
  local f="$OUT/$1.png"
  if [[ -n "$WID" ]]; then
    screencapture -x -o -l "$WID" "$f"
  else
    screencapture -x -w "$f"   # interactive window pick
  fi
  echo "  saved $f"
}

for entry in "${SECTIONS[@]}"; do
  label="${entry%%|*}"
  name="${entry##*|}"
  echo "Capturing $label → $name.png"
  click_row "$label" || echo "  (click failed for '$label' — capturing whatever is shown)"
  sleep 1.2
  shoot "$name"
done

echo
echo "Done. ${#SECTIONS[@]} screenshots in $OUT"
echo "Optimize (optional): for f in $OUT/*.png; do sips -Z 1600 \"\$f\" >/dev/null; done"
