#!/bin/sh
# Creates the three per-state names Xcode's Behaviors need.
cd "$(dirname "$0")" || exit 1
for state in start success fail; do
    ln -sf notch-xcode.sh "notch-xcode-$state.sh"
done
echo "Created notch-xcode-start.sh, notch-xcode-success.sh and notch-xcode-fail.sh in $PWD"
