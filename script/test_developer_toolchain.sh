#!/usr/bin/env bash
# Shared test SDK discovery; honor CI's explicit stable Xcode selection.
if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    [[ -d /Library/Developer/CommandLineTools ]] || { echo 'error: no usable macOS toolchain' >&2; exit 2; }
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if [[ -z "${SDKROOT:-}" ]]; then
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    # Local CLT 27 lacks the SwiftUI macro plugins. Its installed 26.5 SDK is
    # usable for the UI checks; an explicitly selected Xcode is never replaced.
    case "$SDKROOT" in
        /Library/Developer/CommandLineTools/SDKs/*)
            if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
                SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
            fi ;;
    esac
    export SDKROOT
fi
