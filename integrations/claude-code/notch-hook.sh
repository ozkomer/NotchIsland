#!/bin/sh
# Shows Claude Code's state on the island. Called from Claude Code hooks with
# the hook's JSON on stdin:  notch-hook.sh <working|waiting|done|end>
NOTCH="${NOTCH_BIN:-/Applications/NotchIsland.app/Contents/MacOS/NotchIsland}"
[ -x "$NOTCH" ] || exit 0

input=$(cat)
session=$(printf '%s' "$input" | /usr/bin/jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | /usr/bin/jq -r '.cwd // empty' 2>/dev/null)

# One activity per session, named after the folder it works in.
id="claude-$(printf '%s' "${session:-session}" | cut -c1-8)"
title="Claude · $(basename "${cwd:-$PWD}")"

case "$1" in
    working) "$NOTCH" show "$id" "$title" --detail "çalışıyor" --icon sparkles --color orange ;;
    waiting) "$NOTCH" show "$id" "$title" --detail "sizi bekliyor" --icon hand.raised.fill --color yellow ;;
    done)    "$NOTCH" done "$id" "Claude bitti" --silent 1 ;;
    end)     "$NOTCH" clear "$id" ;;
esac >/dev/null 2>&1
exit 0
