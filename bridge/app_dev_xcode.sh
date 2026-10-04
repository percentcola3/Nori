#!/bin/bash
# Privileged, signed bridge: two fixed Xcode actions; never evaluates input.
set -euo pipefail
case "${1:-}" in
    license)
        [[ $# == 1 ]] || exit 2
        /usr/bin/xcodebuild -license accept
        ;;
    select)
        [[ $# == 2 ]] || exit 2
        selected="$2"
        [[ "$selected" == /Applications/*.app/Contents/Developer && "$selected" != *'/../'* && "$selected" != *'/./'* && -x "$selected/usr/bin/xcodebuild" ]] || exit 2
        /usr/bin/xcode-select -s "$selected"
        ;;
    *) exit 2 ;;
esac
