#!/bin/sh
# Assemble .build/swiftemacs.app, a minimal, hardened-runtime, ad-hoc-signed macOS app
# bundle around the release binary, so:
#
#   - the Dock shows a real app icon instead of the generic terminal icon a bare
#     executable gets (once assets/icon/swiftemacs.icon exists — M0 has none yet, see
#     the icon step below);
#   - SelfTest.dlopenCheck() (Sources/Platform/SelfTest.swift) has something to find in
#     Contents/Frameworks/, and the hardened runtime + entitlements combination it is
#     testing only exists once code is actually running from a signed bundle — a bare
#     `.build/release/swiftemacs` has no entitlements at all, so MAP_JIT and the dlopen
#     both "work" there for an uninteresting reason (no hardened runtime to deny them).
#
#     dev/make-app-bundle.sh
#
# macOS only. Rebuilds the release binary and the SelfTestProbe dylib, then assembles
# the bundle fresh each run (any previous .build/swiftemacs.app is removed first), so a
# rerun after a code change always reflects the current tree.
#
# Dylib load path (spec asked which route, and why): SelfTest.dlopenCheck() does not
# link libSelfTestProbe.dylib at build time at all — it `dlopen`s it at an *absolute*
# path computed at runtime (Bundle.main.privateFrameworksURL, i.e.
# Contents/Frameworks/, falling back to the running executable's own directory). An
# absolute path always resolves to the bundled copy unambiguously; there is no dyld
# search-path ambiguity to fix for THIS check, and nothing links the dylib, so this
# script sets no rpath and no install name on the bundled copy (Package.swift's App
# target carries no linkerSettings either, per CLAUDE.md's no-unsafeFlags rule). A
# target that later *links* libSelfTestProbe.dylib directly instead of dlopen-ing it
# will need an rpath consumer and a proper install name; that is when to reintroduce
# both, not before.
#
# Signing: there is no code-signing identity on this machine (verified 2026-09-05,
# `security find-identity -v -p codesigning` -> "0 valid identities found"), so every
# signature here is ad-hoc (`codesign -s -`). The entitlements
# (dev/swiftemacs.entitlements) carry two keys, both required by the 2026-09-05 spike
# (dev/spikes/spike_jit.swift) and SelfTest.swift's two checks:
#   - com.apple.security.cs.allow-jit: without it, mmap(..., MAP_JIT, ...) fails EINVAL
#     under the hardened runtime. The Lisp bytecode VM's future JIT path needs this.
#   - com.apple.security.cs.disable-library-validation: without it, the hardened runtime
#     refuses to dlopen an ad-hoc-signed dylib that isn't signed by the same team as the
#     main executable (irrelevant to team ID here specifically because there is no team
#     at all on this machine — every signature is ad-hoc, so nothing is "the same team"
#     unless this entitlement says libraries need not match).

set -eu

if [ "$(uname)" != "Darwin" ]; then
    echo "error: this script is macOS-only (it builds a .app bundle)" >&2
    exit 1
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "==> swift build -c release --product swiftemacs"
swift build -c release --product swiftemacs

echo "==> swift build -c release --product SelfTestProbe"
swift build -c release --product SelfTestProbe

BIN="$ROOT/.build/release/swiftemacs"
DYLIB="$ROOT/.build/release/libSelfTestProbe.dylib"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN was not produced by the release build" >&2
    exit 1
fi
if [ ! -f "$DYLIB" ]; then
    echo "error: $DYLIB was not produced by the release build" >&2
    exit 1
fi

VERSION_FILE="$ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "error: $VERSION_FILE not found" >&2
    exit 1
fi
VERSION=$(tr -d '[:space:]' <"$VERSION_FILE")
if [ -z "$VERSION" ]; then
    echo "error: $VERSION_FILE is empty" >&2
    exit 1
fi

APP="$ROOT/.build/swiftemacs.app"
# Assemble into a temporary sibling directory first, and only replace $APP once signing
# and verification have both succeeded. A failure partway through (copy,
# install_name_tool, codesign, verification) must not leave a fresh-looking but
# unsigned or half-assembled $APP behind: dev/gui-shot.sh only checks that the binary
# exists and is not older than the sources, so a half-built bundle would otherwise look
# fine to it. ACTOOL_TMP is set inside the icon step below; both are removed on any
# non-zero exit, and TMP_APP is a no-op to remove once it has been moved into place.
TMP_APP="$ROOT/.build/swiftemacs.app.tmp.$$"
ACTOOL_TMP=""
cleanup() {
    rm -rf "$TMP_APP"
    if [ -n "$ACTOOL_TMP" ]; then
        rm -rf "$ACTOOL_TMP"
    fi
}
trap cleanup EXIT
rm -rf "$TMP_APP"

MACOS_DIR="$TMP_APP/Contents/MacOS"
FRAMEWORKS_DIR="$TMP_APP/Contents/Frameworks"
RES_DIR="$TMP_APP/Contents/Resources"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RES_DIR"

cp "$BIN" "$MACOS_DIR/swiftemacs"
cp "$DYLIB" "$FRAMEWORKS_DIR/libSelfTestProbe.dylib"

cat >"$TMP_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>swiftemacs</string>
    <key>CFBundleExecutable</key>
    <string>swiftemacs</string>
    <key>CFBundleIdentifier</key>
    <string>app.swiftemacs</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST

# Icon: swiftemacs has no icon artwork yet (recorded M0 gap, closed in M7). Keep the
# actool/.icon step from Reticle's script (dev/make-app-bundle.sh, read as prior art),
# but make it conditional on the artwork existing so this script does not invent any.
ICONPKG="$ROOT/assets/icon/swiftemacs.icon"
if [ -d "$ICONPKG" ]; then
    if ACTOOL=$(xcrun --find actool 2>/dev/null); then
        ACTOOL_TMP=$(mktemp -d)

        if "$ACTOOL" --output-format human-readable-text --notices --warnings \
                --platform macosx --target-device mac --minimum-deployment-target 26.0 \
                --app-icon swiftemacs --output-partial-info-plist "$ACTOOL_TMP/partial.plist" \
                --compile "$ACTOOL_TMP" "$ICONPKG" >"$ACTOOL_TMP/actool.log" 2>&1 \
            && cp "$ACTOOL_TMP/Assets.car" "$RES_DIR/Assets.car.tmp" \
            && mv "$RES_DIR/Assets.car.tmp" "$RES_DIR/Assets.car" \
            && plutil -insert CFBundleIconName -string swiftemacs "$TMP_APP/Contents/Info.plist"
        then
            echo "compiled assets/icon/swiftemacs.icon -> $RES_DIR/Assets.car (actool found at $ACTOOL)"
        else
            rm -f "$RES_DIR/Assets.car.tmp" "$RES_DIR/Assets.car"
            echo "actool step failed: bundle carries no icon. Last output:"
            tail -5 "$ACTOOL_TMP/actool.log" 2>/dev/null || true
        fi

        rm -rf "$ACTOOL_TMP"
        ACTOOL_TMP=""
    else
        echo "actool not found (no Xcode): bundle carries no icon"
    fi
else
    echo "no assets/icon/swiftemacs.icon: bundle carries no icon -- recorded M0 gap, closed in M7"
fi

echo "==> signing $FRAMEWORKS_DIR/libSelfTestProbe.dylib (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime \
    --entitlements "$ROOT/dev/swiftemacs.entitlements" --timestamp=none \
    "$FRAMEWORKS_DIR/libSelfTestProbe.dylib"

echo "==> signing $TMP_APP (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime \
    --entitlements "$ROOT/dev/swiftemacs.entitlements" --timestamp=none \
    "$TMP_APP"

echo "==> codesign --verify --strict --verbose=2"
codesign --verify --strict --verbose=2 "$TMP_APP"

echo "==> entitlements the bundle actually carries:"
codesign -d --entitlements - "$TMP_APP"

# Only now, with signing and verification both successful, replace any previous bundle.
rm -rf "$APP"
mv "$TMP_APP" "$APP"

echo "wrote $APP"
