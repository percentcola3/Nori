#!/usr/bin/env bash
# Build Nori.app: compile the Swift UI layer, then bundle only the
# vendored shell libraries still used by optional bridge features.  The five
# core operations are implemented by Swift and do not ship or invoke Mole's
# command router or Go helpers.
set +x
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"
BUILD_ARCHS="${SM_BUILD_ARCHS:-$(uname -m)}"
BUILD_OUTPUT_DIR="${SM_OUTPUT_DIR:-$ROOT_DIR/dist}"
REQUESTED_SIGN_IDENTITY="${SM_CODESIGN_IDENTITY:-}"
ALLOW_ADHOC="${SM_ALLOW_ADHOC:-0}"
# Local self-signed development identity created by script/dev_identity.sh.
# It is not an Apple identity, but its designated requirement is stable, so
# its code identity is stable across rebuilds (unlike ad-hoc cdhash requirements).
# Actual privacy-grant retention still requires cross-version macOS validation.
LOCAL_SIGN_LABEL="${SM_LOCAL_SIGN_LABEL:-Nori Local Signing}"
SIGN_IDENTITY=""
SIGN_IDENTITY_LABEL=""
SIGN_IDENTITY_KIND=""
BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/nori-build.XXXXXX")"
trap 'rm -rf "$BUILD_TMP"' EXIT

# Validate the whole request before replacing any existing architecture bundle.
for arch in $BUILD_ARCHS; do
    case "$arch" in
        arm64|x86_64) ;;
        *) echo "error: unsupported architecture: $arch" >&2; exit 2 ;;
    esac
done

case "$ALLOW_ADHOC" in
    0|1) ;;
    *) echo "error: SM_ALLOW_ADHOC must be 0 or 1" >&2; exit 2 ;;
esac

# The local identity lives in its own keychain (see script/dev_identity.sh);
# codesign is pointed at it explicitly so the user's keychain search list is
# never modified.
LOCAL_SIGN_KEYCHAIN="${SM_LOCAL_SIGN_KEYCHAIN:-$HOME/Library/Keychains/NoriLocalSigning.keychain-db}"
LOCAL_SIGN_PASSWORD_FILE="${SM_LOCAL_SIGN_PASSWORD_FILE:-$HOME/Library/Application Support/Nori/signing/keychain-password}"
LOCAL_SIGN_KEYCHAIN_ARGS=()

unlock_local_keychain() {
    [[ -f "$LOCAL_SIGN_KEYCHAIN" && -f "$LOCAL_SIGN_PASSWORD_FILE" ]] || return 1
    /usr/bin/security unlock-keychain -p "$(/usr/bin/head -n 1 "$LOCAL_SIGN_PASSWORD_FILE")" \
        "$LOCAL_SIGN_KEYCHAIN" >/dev/null 2>&1
}

if [[ -n "${SM_TEST_SIGNING_IDENTITIES+x}" ]]; then
    # Test hook: the suite feeds a canned `security find-identity -p codesigning -v`
    # listing so identity selection can be checked without a keychain.
    SIGNING_IDENTITIES="$SM_TEST_SIGNING_IDENTITIES"
else
    SIGNING_IDENTITIES=$(/usr/bin/security find-identity -p codesigning -v 2>/dev/null || true)
    if unlock_local_keychain; then
        # Dedicated keychain first: if a stray copy of the local label exists
        # in the login keychain, the first (usable) record must win.
        SIGNING_IDENTITIES="$(/usr/bin/security find-identity -p codesigning -v "$LOCAL_SIGN_KEYCHAIN" 2>/dev/null || true)"$'\n'"$SIGNING_IDENTITIES"
    fi
fi

identity_record_for() {
    local requested="$1" line="" record_hash="" requested_hash=""
    requested_hash=$(printf '%s' "$requested" | /usr/bin/tr '[:lower:]' '[:upper:]')
    while IFS= read -r line; do
        [[ "$line" == *'"'* ]] || continue
        record_hash=$(printf '%s\n' "$line" | /usr/bin/awk '{print $2}')
        if [[ "$requested" =~ ^[0-9A-Fa-f]{40}$ ]]; then
            record_hash=$(printf '%s' "$record_hash" | /usr/bin/tr '[:lower:]' '[:upper:]')
            [[ "$record_hash" == "$requested_hash" ]] || continue
        else
            [[ "$line" == *"\"$requested\""* ]] || continue
        fi
        printf '%s\n' "$line"
        return 0
    done <<< "$SIGNING_IDENTITIES"
    return 1
}

set_signing_identity_from_record() {
    local record="$1" requested="${2:-}" label=""
    label="${record#*\"}"
    label="${label%%\"*}"
    case "$label" in
        "Apple Development: "*) SIGN_IDENTITY_KIND="development" ;;
        "Developer ID Application: "*) SIGN_IDENTITY_KIND="developer-id" ;;
        "$LOCAL_SIGN_LABEL") SIGN_IDENTITY_KIND="local" ;;
        *)
            echo "error: unsupported signing identity: $label" >&2
            echo "Use Apple Development for local builds, Developer ID Application for releases," >&2
            echo "or script/dev_identity.sh to create the local identity \"$LOCAL_SIGN_LABEL\"." >&2
            exit 2
            ;;
    esac
    SIGN_IDENTITY_LABEL="$label"
    if [[ "$SIGN_IDENTITY_KIND" == "local" ]]; then
        # Sign by hash (a stale copy of the label may linger in another
        # keychain) and only through the dedicated keychain.
        SIGN_IDENTITY=$(printf '%s\n' "$record" | /usr/bin/awk '{print $2}')
        if [[ -z "${SM_TEST_SIGNING_IDENTITIES+x}" && -f "$LOCAL_SIGN_KEYCHAIN" ]]; then
            LOCAL_SIGN_KEYCHAIN_ARGS=(--keychain "$LOCAL_SIGN_KEYCHAIN")
        fi
    else
        SIGN_IDENTITY="${requested:-$label}"
    fi
}

resolve_signing_identity() {
    local record="" line=""
    if [[ "$REQUESTED_SIGN_IDENTITY" == "-" ]]; then
        [[ "$ALLOW_ADHOC" == "1" ]] || {
            echo "error: ad-hoc signing requires explicit SM_ALLOW_ADHOC=1" >&2
            exit 2
        }
        SIGN_IDENTITY="-"
        SIGN_IDENTITY_LABEL="ad-hoc"
        SIGN_IDENTITY_KIND="adhoc"
        return
    fi

    if [[ -n "$REQUESTED_SIGN_IDENTITY" ]]; then
        record=$(identity_record_for "$REQUESTED_SIGN_IDENTITY") || {
            echo "error: requested code-signing identity is not available: $REQUESTED_SIGN_IDENTITY" >&2
            exit 2
        }
        set_signing_identity_from_record "$record" "$REQUESTED_SIGN_IDENTITY"
        return
    fi

    while IFS= read -r line; do
        if [[ "$line" == *'"Apple Development: '* ]]; then
            set_signing_identity_from_record "$line"
            return
        fi
    done <<< "$SIGNING_IDENTITIES"

    # No Apple identity: fall back to the local self-signed development
    # identity, which still gives TCC a stable designated requirement.
    while IFS= read -r line; do
        if [[ "$line" == *"\"$LOCAL_SIGN_LABEL\""* ]]; then
            set_signing_identity_from_record "$line"
            return
        fi
    done <<< "$SIGNING_IDENTITIES"

    if [[ "$ALLOW_ADHOC" == "1" ]]; then
        SIGN_IDENTITY="-"
        SIGN_IDENTITY_LABEL="ad-hoc"
        SIGN_IDENTITY_KIND="adhoc"
        return
    fi

    echo "error: no Apple Development or local signing identity is available" >&2
    echo "Run script/dev_identity.sh to create \"$LOCAL_SIGN_LABEL\", install an Apple Development" >&2
    echo "certificate, or use SM_ALLOW_ADHOC=1 only for CI/tests." >&2
    echo "Ad-hoc GUI builds do not provide a stable identity for macOS privacy grants." >&2
    exit 2
}

resolve_signing_identity
HOST_ENTITLEMENTS=""
case "$SIGN_IDENTITY_KIND" in
    local|adhoc)
        # Sparkle is non-platform code. Self-signed/ad-hoc code has no Apple
        # Team ID, so hardened runtime rejects the framework even when both
        # are signed by the same certificate. This sole host exception was
        # verified with the pinned public release identity; Apple identities
        # retain library validation. See docs/sparkle-build.md.
        HOST_ENTITLEMENTS="$ROOT_DIR/signing/sparkle-selfsigned.entitlements"
        ;;
esac
echo "==> Signing mode: $SIGN_IDENTITY_LABEL"
if [[ "${SM_BUILD_RESOLVE_ONLY:-0}" == "1" ]]; then
    # Test hook: report the resolved identity without compiling anything.
    printf 'kind=%s\nlabel=%s\nidentity=%s\nhost_entitlements=%s\n' \
        "$SIGN_IDENTITY_KIND" "$SIGN_IDENTITY_LABEL" "$SIGN_IDENTITY" "$HOST_ENTITLEMENTS"
    exit 0
fi
if [[ -n "$HOST_ENTITLEMENTS" && ! -f "$HOST_ENTITLEMENTS" ]]; then
    echo "error: Sparkle self-signed host entitlement is missing" >&2
    exit 2
fi

# This verifies the pinned archive and cached contents before returning a path.
# Resolve-only identity tests above never download dependency code.
SPARKLE_DIR="$(/usr/bin/python3 "$ROOT_DIR/script/fetch_sparkle.py")"

if [[ ! -d "$MOLE_SRC/lib" ]]; then
    echo "error: vendored bridge support libraries not found at $MOLE_SRC" >&2
    exit 1
fi

# macOS 27 SDK 的 SwiftUI 把 @State 等属性实现为宏，而宏插件只随完整版 Xcode
# 分发；纯 Command Line Tools 环境会报 "plugin for module 'SwiftUIMacros' not
# found"。探测当前 SDK，失败时回退到仍为非宏实现的 26.x SDK。
SWIFT_SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftui_sdk_usable() {
    /usr/bin/printf 'import SwiftUI\nstruct SwiftUIMacroProbe: View {\n    @State private var flag = false\n    var body: some View { Text(String(flag)) }\n}\n' \
        > "$BUILD_TMP/swiftui-macro-probe.swift"
    SDKROOT="$1" swiftc -typecheck -framework SwiftUI \
        -module-cache-path "$BUILD_TMP/module-cache-probe" \
        "$BUILD_TMP/swiftui-macro-probe.swift" >/dev/null 2>&1
}
if ! swiftui_sdk_usable "$SWIFT_SDKROOT"; then
    for fallback_sdk in macosx26.5 macosx26.0; do
        fallback_root="$(xcrun --sdk "$fallback_sdk" --show-sdk-path 2>/dev/null)" || continue
        [[ -d "$fallback_root" ]] || continue
        if swiftui_sdk_usable "$fallback_root"; then
            echo "==> Default SDK lacks the SwiftUI macro plugin; building with $fallback_root"
            SWIFT_SDKROOT="$fallback_root"
            break
        fi
    done
fi

# Compile and stage one frozen source/resource set. Parallel workspace edits
# must not change compiler inputs halfway through a local update.
SWIFT_SOURCE_DIR="$BUILD_TMP/SimpleMole"
/usr/bin/ditto "$ROOT_DIR/SimpleMole" "$SWIFT_SOURCE_DIR"

sign_one() {
    local target="$1" entitlements="${2:-}" preserve_entitlements="${3:-0}"
    local extra_args=()
    if [[ -n "$entitlements" ]]; then
        extra_args=(--entitlements "$entitlements")
    elif [[ "$preserve_entitlements" == "1" ]]; then
        extra_args=(--preserve-metadata=entitlements)
    fi
    if [[ "$SIGN_IDENTITY_KIND" == "adhoc" ]]; then
        /usr/bin/codesign --force --options runtime \
            ${extra_args[@]+"${extra_args[@]}"} --sign - "$target" >/dev/null
    elif [[ "$SIGN_IDENTITY_KIND" == "developer-id" ]]; then
        /usr/bin/codesign --force --options runtime --timestamp \
            ${extra_args[@]+"${extra_args[@]}"} \
            --sign "$SIGN_IDENTITY" "$target"
    else
        # bash 3.2 + set -u: guard the possibly-empty array expansion.
        /usr/bin/codesign --force --options runtime --timestamp=none \
            ${extra_args[@]+"${extra_args[@]}"} \
            ${LOCAL_SIGN_KEYCHAIN_ARGS[@]+"${LOCAL_SIGN_KEYCHAIN_ARGS[@]}"} \
            --sign "$SIGN_IDENTITY" "$target"
    fi
}

# Keep each architecture in its own bundle; local builds default to this Mac.
for arch in $BUILD_ARCHS; do
    APP_DIR="$BUILD_OUTPUT_DIR/$arch/Nori.app"
    CONTENTS="$APP_DIR/Contents"
    RESOURCES="$CONTENTS/Resources"
    rm -rf "$APP_DIR"
    mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Frameworks" "$RESOURCES"

    echo "==> Compiling Swift app ($arch)"
    SDKROOT="$SWIFT_SDKROOT" swiftc -O -whole-module-optimization -target "$arch-apple-macos13.0" \
        -module-cache-path "$BUILD_TMP/module-cache-$arch" \
        -F "$SPARKLE_DIR" -framework Sparkle \
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
        -framework Cocoa -framework SwiftUI -framework CoreServices -framework Security -framework CryptoKit -framework IOKit -framework ServiceManagement -lsqlite3 \
        "$SWIFT_SOURCE_DIR"/*.swift \
        "$SWIFT_SOURCE_DIR"/L10n/*.swift \
        "$SWIFT_SOURCE_DIR"/Services/*.swift \
        "$SWIFT_SOURCE_DIR"/Views/*.swift \
        -o "$CONTENTS/MacOS/Nori"

    [[ "$(/usr/bin/lipo -archs "$CONTENTS/MacOS/Nori")" == "$arch" ]] || {
        echo "error: expected a single $arch executable" >&2
        exit 2
    }

    # Remove local symbols before signing this architecture's executable.
    /usr/bin/strip -x "$CONTENTS/MacOS/Nori"

    cp "$SWIFT_SOURCE_DIR/Support/Info.plist" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c \
        "Set :SUFeedURL https://github.com/percentcola3/Nori/releases/latest/download/appcast-$arch.xml" \
        "$CONTENTS/Info.plist"

    echo "==> Bundling bridge support libraries from $MOLE_SRC"
    bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$MOLE_SRC" "$RESOURCES"

    if [[ -f "$SWIFT_SOURCE_DIR/Support/AppIcon.icns" ]]; then
        cp "$SWIFT_SOURCE_DIR/Support/AppIcon.icns" "$RESOURCES/AppIcon.icns"
    fi
    if [[ -f "$SWIFT_SOURCE_DIR/Support/HeaderBrandIcon.png" ]]; then
        cp "$SWIFT_SOURCE_DIR/Support/HeaderBrandIcon.png" "$RESOURCES/HeaderBrandIcon.png"
    fi
    if [[ -f "$SWIFT_SOURCE_DIR/Support/MenuBarIconTemplate.png" ]]; then
        cp "$SWIFT_SOURCE_DIR/Support/MenuBarIconTemplate.png" "$RESOURCES/MenuBarIconTemplate.png"
    fi

    cp "$SWIFT_SOURCE_DIR/Support/MenuBarIconTemplate@2x.png" "$RESOURCES/MenuBarIconTemplate@2x.png"
    mkdir -p "$RESOURCES/Licenses"
    cp "$ROOT_DIR/vendor/sparkle/LICENSE" "$RESOURCES/Licenses/Sparkle.txt"
    mkdir -p "$RESOURCES/Nori"
    cp "$SWIFT_SOURCE_DIR/Support/Nori/Animations/"*.svg "$RESOURCES/Nori/"
    cp -R "$SWIFT_SOURCE_DIR/Support/AgentIcons" "$RESOURCES/AgentIcons"

    # Preserve the complete versioned framework and its symlinks. Re-sign
    # nested code inside-out with the host's resolved identity; --deep is used
    # only for verification, never for signing.
    /usr/bin/ditto "$SPARKLE_DIR/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
    SPARKLE_FRAMEWORK="$CONTENTS/Frameworks/Sparkle.framework"
    sign_one "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
    sign_one "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" "" 1
    sign_one "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
    sign_one "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
    sign_one "$SPARKLE_FRAMEWORK"
    sign_one "$CONTENTS/MacOS/Nori" "$HOST_ENTITLEMENTS"
    sign_one "$APP_DIR" "$HOST_ENTITLEMENTS"
    /usr/bin/codesign --verify --deep --strict "$APP_DIR"

    SIGN_DETAILS=$(/usr/bin/codesign -dvvv "$APP_DIR" 2>&1)
    if [[ "$SIGN_IDENTITY_KIND" == "adhoc" ]]; then
        printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -Fq 'Signature=adhoc' || {
            echo "error: expected an explicitly allowed ad-hoc signature" >&2
            exit 2
        }
        echo "warning: ad-hoc signature was explicitly allowed for CI/tests; do not use this build to validate macOS permission persistence" >&2
    else
        printf '%s\n' "$SIGN_DETAILS" | /usr/bin/grep -Fq "Authority=$SIGN_IDENTITY_LABEL" || {
            echo "error: built App is not signed by the resolved identity: $SIGN_IDENTITY_LABEL" >&2
            exit 2
        }
        DESIGNATED_REQUIREMENT=$(/usr/bin/codesign -dr - "$APP_DIR" 2>&1) || {
            echo "error: could not read the App designated requirement" >&2
            exit 2
        }
        [[ -n "$DESIGNATED_REQUIREMENT" ]] || {
            echo "error: App designated requirement is empty" >&2
            exit 2
        }
        if [[ "$SIGN_IDENTITY_KIND" == "local" ]]; then
            # A self-signed leaf has no team; stability comes from the
            # certificate hash pinned in the designated requirement.
            # codesign pins a self-signed cert as `certificate root = H"…"`
            # (it is its own root); chained non-Apple certs use `certificate leaf`.
            printf '%s\n' "$DESIGNATED_REQUIREMENT" | /usr/bin/grep -Eq 'certificate (leaf|root) = H"' || {
                echo "error: local signature did not pin the certificate in its designated requirement" >&2
                exit 2
            }
            echo "==> Signed identity: $SIGN_IDENTITY_LABEL (self-signed; stable code identity, privacy retention requires validation)"
        else
            TEAM_IDENTIFIER=$(printf '%s\n' "$SIGN_DETAILS" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)
            [[ -n "$TEAM_IDENTIFIER" && "$TEAM_IDENTIFIER" != "not set" ]] || {
                echo "error: stable Apple signature is missing a TeamIdentifier" >&2
                exit 2
            }
            echo "==> Signed identity: $SIGN_IDENTITY_LABEL"
            echo "==> Team identifier: $TEAM_IDENTIFIER"
        fi
        echo "==> $DESIGNATED_REQUIREMENT"
    fi

    echo "Built $APP_DIR"
done
