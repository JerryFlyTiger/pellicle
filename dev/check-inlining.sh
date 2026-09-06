#!/bin/sh
# dev/check-inlining.sh — the standing regression test for this project's cross-module
# optimisation convention (PLAN.md 4.2, "Cross-module optimisation").
#
# The convention: the project builds with no `-package-cmo`, no `-enable-library-evolution`
# and no `unsafeFlags`. A cross-module call that a benchmark shows is hot is promoted
# deliberately in the source — the type becomes `public`, the hot members get `@inlinable`,
# and anything an inlinable body touches gets `@usableFromInline`. Everything else stays
# `package` and compiles to a real call.
#
# This script checks that the compiler actually did what the source says, from one stock
# `swift build -c release`:
#
#   - the *hot* (promoted) symbols must NOT appear as undefined references in the calling
#     module's object file: they were inlined;
#   - the *cold* symbols MUST appear: they were not.
#
# The second assertion is what gives the first one teeth. Without it, an object file in
# which nothing at all was emitted — or a probe the optimiser deleted outright — would
# pass. Both directions are checked against the same object file from the same build, so
# no second build and no environment toggle is needed.
#
# Measured facts behind the convention (this machine, Swift 6.3.3, 100M iterations):
# `@inlinable` on a member of a `public` type is inlined across modules with no flags at
# all (0.0135 s) and matches what `-enable-library-evolution -Xfrontend -package-cmo
# -Xfrontend -allow-non-resilient-access` achieves (0.0133 s); `@inlinable` on a member of
# a `package` type is NOT inlined without those flags (0.0763 s). Hence the convention
# promotes the *type*, not just the member.

set -eu

cd "$(dirname "$0")/.."

echo "==> swift build -c release"
swift build -c release

# The probe bodies must stay inside the band where the `@inlinable` annotation is the only
# thing that decides whether the call is inlined. Measured on this machine (Swift 6.3.3,
# -O -wmo, a public struct member called across a module boundary): a four-statement body
# is inlined annotated or not, an 8-to-16-statement body only when annotated, a
# 24-statement body never. Outside that band this check is vacuous in one direction or
# permanently red in the other, so refuse to run rather than report a meaningless pass.
# Counted here, next to the check that depends on it, because a Swift test cannot read its
# own source.
for probe in Sources/Text/InliningProbe.swift Sources/Lisp/InliningProbe.swift; do
    # Counted per body, not summed and halved: a mutation that shortens only the hot body
    # leaves the total unchanged enough to pass an averaged check while the hot probe has
    # dropped out of the band. Each struct is counted on its own.
    counts=$(awk '
        /^public struct .*HotProbe/  { where = "hot" }
        /^package struct .*ColdProbe/ { where = "cold" }
        /^        v = \(v /          { n[where]++ }
        END { printf "%d %d", n["hot"], n["cold"] }
    ' "$probe")
    hot_n=${counts% *}
    cold_n=${counts#* }
    for pair in "hot:$hot_n" "cold:$cold_n"; do
        which=${pair%:*}
        n=${pair#*:}
        if [ "$n" -lt 8 ] || [ "$n" -gt 16 ]; then
            echo "error: $probe's $which body has $n mixing statements; the band in which" >&2
            echo "       this check can tell an annotated call from an unannotated one is" >&2
            echo "       8 to 16 statements. See the probe file's header comment." >&2
            exit 1
        fi
    done
    if [ "$hot_n" -ne "$cold_n" ]; then
        echo "error: $probe's hot body ($hot_n statements) and cold body ($cold_n) differ." >&2
        echo "       The two shapes must compute the same thing, or the check is comparing" >&2
        echo "       two different computations." >&2
        exit 1
    fi
    echo "==> $probe: $hot_n mixing statements in each body (band is 8-16)"
done

# Addressed by an explicit glob rather than by walking the whole of .build. Two reasons:
# a debug build (-Onone) also produces an InliningProbe.swift.o and nothing is inlined at
# -Onone, so a debug object under test would report a failure that is not real; and a
# side-by-side build under another --build-path (the 2026-09-05 CMO spike did exactly
# that, leaving .build/cmo-check-with and -without behind) would otherwise be a second
# match. More than one candidate is an error, never a silent pick.
set -- .build/*/release/Editor.build/InliningProbe.swift.o
if [ "$#" -gt 1 ]; then
    echo "error: more than one candidate object; disambiguate before trusting this check:" >&2
    printf '       %s\n' "$@" >&2
    exit 1
fi
OBJ=$1
if [ ! -f "$OBJ" ]; then
    echo "error: $OBJ does not exist after a release build" >&2
    exit 1
fi
echo "==> object under test: $OBJ"

nm "$OBJ" > .build/inlining-symbols.txt
echo "==> undefined cross-module symbols in that object:"
grep ' U ' .build/inlining-symbols.txt || echo "    (none)"

# Matched by module tag plus the probe type and selector rather than the full mangling, so
# an unrelated mangling detail change does not turn this into a false failure.
count() { grep -cE "$1" .build/inlining-symbols.txt || true; }

hot_text=$(count '4Text.*HotProbe.*packedByteLength')
hot_lisp=$(count '4Lisp.*HotProbe.*packedByteLength')
cold_text=$(count '4Text.*ColdProbe.*packedByteLength')
cold_lisp=$(count '4Lisp.*ColdProbe.*packedByteLength')

echo "==> counts: hot text=$hot_text lisp=$hot_lisp (want 0) | cold text=$cold_text lisp=$cold_lisp (want >0)"

fail=0

if [ "$hot_text" -ne 0 ] || [ "$hot_lisp" -ne 0 ]; then
    echo "FAIL: a promoted (@inlinable on a public type) cross-module call was NOT inlined."
    echo "      The hot probe symbols are still referenced from Editor's object file, so the"
    echo "      convention in PLAN.md 4.2 is not holding on this toolchain. See"
    echo "      .build/inlining-symbols.txt."
    fail=1
fi

if [ "$cold_text" -eq 0 ] || [ "$cold_lisp" -eq 0 ]; then
    echo "FAIL: the cold control symbols are missing from Editor's object file. This check"
    echo "      cannot distinguish 'inlined' from 'never emitted', so the pass above would"
    echo "      be meaningless. Either the cold probes were optimised away for an unrelated"
    echo "      reason, or the object file under test is not the one that calls them."
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "==> check-inlining.sh: assertion FAILED, see messages above"
    exit 1
fi

echo "==> check-inlining.sh: promoted calls inlined, cold calls still real calls"
