#!/bin/sh
# Screenshot the GUI front end, so a claim about how it renders can be checked by
# looking rather than by trusting a comment.
#
#     dev/gui-shot.sh [FILE-TO-OPEN] [OUTPUT.png]
#
# Defaults to opening nothing and writing to gui-shot.png in the current directory.
# Launches the editor, waits for its window to appear, captures only that window, and
# kills the process. FILE-TO-OPEN is accepted and passed through to the binary, but M0
# opens no file yet -- the app ignores it; the argument exists so this script's call
# shape does not have to change once M6 makes it meaningful.
#
# Ported from Reticle's dev/gui-shot.sh (~/My_Projects/reticle/dev/gui-shot.sh); the
# design and the guards below are unchanged from there because they encode a real
# incident (see below), just retargeted at swiftemacs's SwiftPM/app-bundle layout.
#
# Why this must run the BUNDLED, SIGNED binary and not a bare .build/release/swiftemacs:
# the two hardened-runtime entitlements this whole self-test story exists to prove
# (com.apple.security.cs.allow-jit, com.apple.security.cs.disable-library-validation)
# only exist on .build/swiftemacs.app -- a bare .build/release/swiftemacs has no
# entitlements and no hardened runtime at all, so a screenshot of it proves nothing
# about the bundle a user would actually run. If the bundle is missing or stale, this
# script tells the caller to run dev/make-app-bundle.sh rather than silently falling
# back to an unsigned binary.
#
# macOS only, and it needs one permission that cannot be granted from a script:
#
#     System Settings -> Privacy & Security -> Screen Recording
#
# Grant it to the terminal (or whichever app runs this), then restart that app.
# Without it `screencapture` exits with "could not create image from rect" and this
# script tells you so rather than writing a misleading blank file. Note that locating
# the window needs no permission at all -- only the pixels do.
#
# The binary this script runs must actually be current, or a screenshot proves nothing.
# Reticle's own incident (2026-09-03, recorded in its dev/gui-shot.sh header): a fix
# landed, a component test suite was run afterward (which relinks that component's own
# test binaries but does NOT relink the root app binary), and gui-shot ran a 1.5-hour-old
# binary built BEFORE the fix. The resulting "after" screenshot differed from the
# "before" one by only 200 pixels, which read as "the fix did nothing" -- the fix was
# fine; the binary was stale. Hence the staleness gate below: refuse to run at all if any
# Sources/**/*.swift, *.c or *.h file is newer than the bundled binary, naming the
# offending file.

set -eu

FILE=${1:-}
OUT=${2:-gui-shot.png}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="${TMPDIR:-/tmp}/swiftemacs-gui-shot"

if [ "$(uname)" != "Darwin" ]; then
    echo "error: this script is macOS-only (it uses screencapture)" >&2
    exit 1
fi

APP="$ROOT/.build/swiftemacs.app"
BIN="$APP/Contents/MacOS/swiftemacs"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found -- run dev/make-app-bundle.sh first" >&2
    exit 1
fi

# Staleness gate: if any source file that could change the binary is newer than the
# binary itself, a screenshot from it proves nothing about the current code -- see this
# script's header comment for the incident that made this necessary.
STALE=$(find "$ROOT/Sources" \( -name '*.swift' -o -name '*.c' -o -name '*.h' \) \
    -newer "$BIN" -print -quit)
if [ -n "$STALE" ]; then
    echo "error: $BIN is older than $STALE -- run dev/make-app-bundle.sh first" >&2
    exit 1
fi

# Rebuild the locator only when it is missing or older than its source.
if [ ! -x "$HELPER" ] || [ "$ROOT/dev/gui-shot.swift" -nt "$HELPER" ]; then
    swiftc -O -o "$HELPER" "$ROOT/dev/gui-shot.swift"
fi

"$BIN" "$FILE" >/dev/null 2>&1 &
APP_PID=$!
# Kill the editor however we leave this script, including on error.
trap 'kill $APP_PID 2>/dev/null || true' EXIT INT TERM

INFO=""
i=0
while [ $i -lt 15 ]; do
    if ! kill -0 $APP_PID 2>/dev/null; then
        echo "error: the editor exited before a window appeared" >&2
        exit 1
    fi
    INFO=$("$HELPER" swiftemacs 2>/dev/null || true)
    [ -n "$INFO" ] && break
    sleep 1
    i=$((i + 1))
done

if [ -z "$INFO" ]; then
    echo "error: no window found after 15s" >&2
    exit 1
fi

# shellcheck disable=SC2086
set -- $INFO
WINDOW_ID=$1

if screencapture -x -o -l"$WINDOW_ID" "$OUT" 2>/dev/null && [ -s "$OUT" ]; then
    echo "wrote $OUT ($(($(wc -c <"$OUT") / 1024)) KB, window ${4}x${5})"
else
    rm -f "$OUT"
    cat >&2 <<'MSG'
error: screencapture could not read the window.

This is the Screen Recording permission, not a bug here -- the window was
found, only its pixels are gated. Grant it in

    System Settings -> Privacy & Security -> Screen Recording

to the app running this script, restart that app, and run this again.
MSG
    exit 1
fi
