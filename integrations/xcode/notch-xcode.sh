#!/bin/sh
# Shows Xcode builds on the island. Add it in Xcode > Settings > Behaviors:
#   Build > Starts    -> Run: notch-xcode.sh   (copy as notch-xcode-start.sh, or pass the state by name)
#   Build > Succeeds  -> Run: notch-xcode.sh
#   Build > Fails     -> Run: notch-xcode.sh
# Xcode cannot pass arguments to a behavior script, so the state comes from the
# file name: link this file as notch-xcode-start.sh, notch-xcode-success.sh and
# notch-xcode-fail.sh (make-links.sh does that) and pick the matching one.
NOTCH="${NOTCH_BIN:-/Applications/NotchIsland.app/Contents/MacOS/NotchIsland}"
[ -x "$NOTCH" ] || exit 0

project="${XcodeProject:-${XcodeWorkspace:-Xcode}}"
project="${project%.*}"
id="xcode-$project"

case "$(basename "$0")" in
    *start*)   "$NOTCH" show "$id" "$project" --detail "derleniyor" --icon hammer.fill --color blue ;;
    *success*) "$NOTCH" done "$id" "Derlendi" ;;
    *fail*)    "$NOTCH" fail "$id" "Derleme hatası" ;;
esac >/dev/null 2>&1
exit 0
