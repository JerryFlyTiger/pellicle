#!/bin/sh
# dev/check-inlining.sh — the standing regression test for this project's cross-module
# optimisation convention (PLAN.md 4.2, "Cross-module optimisation").
#
# The convention: the project builds with no `-package-cmo`, no `-enable-library-evolution`
# and no `unsafeFlags`. A cross-module call that a benchmark shows is hot is promoted
# deliberately in the source — the containing *type* gets promoted (not just the member),
# the hot members get `@inlinable`, and anything an inlinable body touches gets
# `@usableFromInline`. Everything else stays `package` and compiles to a real call.
#
# **Promoting the type does not mean making it `public`.** `PLAN.md` 4.2 was amended
# 2026-09-09 (M1.2): `@usableFromInline` on a `package` type is itself a promotion — with
# the hot members `@inlinable`, it inlines across the module boundary with no flags, at the
# same speed as the `public` shape, and it adds no public API surface. `Text` is not a
# package product, so `public` serves no external client and only forfeits the
# `package`-vs-`public` signal. **Default to `@usableFromInline package`; reach for `public`
# only when something outside the package must call it.** `SumTreeCursor` and its supporting
# types ship the `@usableFromInline package` shape, not `public` — see `TextWarmProbe` below.
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
# a plain `package` type is NOT inlined without those flags (0.0763 s); and `@inlinable` on
# a member of an `@usableFromInline package` type — the fourth shape, measured for the
# first time in M1.2 and the one this codebase actually ships — IS inlined with no flags,
# matching the `public` shape (`TextWarmProbe`/`TextHotProbe` below, and `PLAN.md`'s
# 2026-09-09 amendment to 4.2). Hence the convention promotes the *type*, not just the
# member, and `@usableFromInline package` is the promotion to reach for first.

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
    #
    # `where` is reset (to "other", not left holding the previous header's value) on every
    # recognised struct header, and any other header hands the mixing-statement lines that
    # follow it to `other` rather than silently to whatever the last recognised header was.
    # This is what task 2c fixed: before this rewrite, `where` was set once on the cold
    # header and never reset, so anything appended to the file after the cold probe (a
    # fourth shape, say) was miscounted into the cold body. `other != 0` fails below.
    counts=$(awk '
        /^public struct .*HotProbe/                      { where = "hot"; next }
        /^@usableFromInline package struct .*WarmProbe/  { where = "warm"; next }
        /^package struct .*ColdProbe/                     { where = "cold"; next }
        /^(public|package|@usableFromInline package) struct / { where = "other"; next }
        /^        v = \(v /           { n[where]++ }
        END { printf "%d %d %d %d", n["hot"], n["warm"], n["cold"], n["other"] }
    ' "$probe")
    set -- $counts
    hot_n=$1
    warm_n=$2
    cold_n=$3
    other_n=$4
    if [ "$other_n" -gt 0 ]; then
        echo "error: $probe has $other_n mixing statements attributed to an unrecognised" >&2
        echo "       struct header. A shape was added without teaching this counter about" >&2
        echo "       it; see dev/check-inlining.sh task 2c." >&2
        exit 1
    fi
    for pair in "hot:$hot_n" "warm:$warm_n" "cold:$cold_n"; do
        which=${pair%:*}
        n=${pair#*:}
        if [ "$n" -lt 8 ] || [ "$n" -gt 16 ]; then
            echo "error: $probe's $which body has $n mixing statements; the band in which" >&2
            echo "       this check can tell an annotated call from an unannotated one is" >&2
            echo "       8 to 16 statements. See the probe file's header comment." >&2
            exit 1
        fi
    done
    if [ "$hot_n" -ne "$cold_n" ] || [ "$warm_n" -ne "$cold_n" ]; then
        echo "error: $probe's hot ($hot_n), warm ($warm_n) and cold ($cold_n) bodies differ." >&2
        echo "       The three shapes must compute the same thing, or the check is comparing" >&2
        echo "       different computations." >&2
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
warm_text=$(count '4Text.*WarmProbe.*packedByteLength')
warm_lisp=$(count '4Lisp.*WarmProbe.*packedByteLength')
cold_text=$(count '4Text.*ColdProbe.*packedByteLength')
cold_lisp=$(count '4Lisp.*ColdProbe.*packedByteLength')

echo "==> counts: hot text=$hot_text lisp=$hot_lisp (want 0) | warm text=$warm_text lisp=$warm_lisp (want 0) | cold text=$cold_text lisp=$cold_lisp (want >0)"

fail=0

if [ "$hot_text" -ne 0 ] || [ "$hot_lisp" -ne 0 ]; then
    echo "FAIL: a promoted (@inlinable on a public type) cross-module call was NOT inlined."
    echo "      The hot probe symbols are still referenced from Editor's object file, so the"
    echo "      convention in PLAN.md 4.2 is not holding on this toolchain. See"
    echo "      .build/inlining-symbols.txt."
    fail=1
fi

if [ "$warm_text" -ne 0 ] || [ "$warm_lisp" -ne 0 ]; then
    echo "FAIL: the warm shape (@usableFromInline package type, @inlinable package member) —"
    echo "      the shape SumTreeCursor actually ships — was NOT inlined across the module"
    echo "      boundary. The warm probe symbols are still referenced from Editor's object"
    echo "      file. See .build/inlining-symbols.txt."
    fail=1
fi

if [ "$cold_text" -eq 0 ] || [ "$cold_lisp" -eq 0 ]; then
    echo "FAIL: the cold control symbols are missing from Editor's object file. This check"
    echo "      cannot distinguish 'inlined' from 'never emitted', so the pass above would"
    echo "      be meaningless. Either the cold probes were optimised away for an unrelated"
    echo "      reason, or the object file under test is not the one that calls them."
    fail=1
fi

# The probes above answer "does the compiler still do this?" — they say nothing about
# whether SumTreeCursor still asks it to. Deleting one @usableFromInline/@inlinable off the
# real declarations costs 8x (M1.2's fix-round measurement) and leaves every probe green
# and every other test passing, because the probes are a separate, deliberately stable
# file. This block greps the real declarations by name so that specific regression has a
# check of its own, answering "do we still ask it to?".
check_attr() {
    file=$1
    attr=$2
    decl=$3
    # Matches the attribute anywhere on the line immediately above the declaration line, or
    # on the same line (both styles appear in this codebase; see SumTreeCursor.swift vs.
    # SumTree.swift).
    #
    # M1.2 fix round: the original version of this function was `grep -B1 -E "(struct|enum|
    # protocol|func) $decl\b" "$file" | grep -q -- "$attr"`, which matched that pattern
    # *anywhere in the file*, comment prose included. A doc comment that happens to mention
    # both the attribute and the declaration keyword+name near each other (e.g. explaining
    # `@usableFromInline` right next to prose naming `struct SumTreeCursor`) would satisfy
    # both greps despite the real declaration having lost the attribute entirely — a false
    # pass with no compiler check behind it. This awk version only considers lines that are
    # not comments (`//`/`///`), and only treats a line as "the declaration" if it actually
    # starts with (optional attributes/modifiers, then) `struct`/`enum`/`protocol`/`func` —
    # ruling out both a decoy comment standing in for the declaration and a decoy comment
    # standing in for the attribute line above it.
    result=$(awk -v attr="$attr" -v decl="$decl" '
        BEGIN { prevAttr = 0; found = 0 }
        {
            line = $0
            isComment = (line ~ /^[ \t]*\/\//)
            isDecl = !isComment && \
                (line ~ ("(^|[^A-Za-z0-9_])(struct|enum|protocol|func)[ \t]+" decl "([^A-Za-z0-9_]|$)"))
            if (isDecl) {
                hasAttrHere = (index(line, attr) > 0)
                if (hasAttrHere || prevAttr) { found = 1 }
            }
            if (!isComment) { prevAttr = (index(line, attr) > 0) }
        }
        END { print (found ? "yes" : "no") }
    ' "$file")
    if [ "$result" != "yes" ]; then
        echo "FAIL: $file's $decl has lost $attr. This is the promotion" >&2
        echo "      dev/specs/m1.2-promotion-and-guards.md applied; see task 2b." >&2
        fail=1
    fi
}

echo "==> checking the real promoted declarations still carry their attributes"
check_attr Sources/Text/SumTreeCursor.swift '@usableFromInline' 'SumTreeCursor'
check_attr Sources/Text/SumTree.swift '@usableFromInline' 'Node'
check_attr Sources/Text/SumTree.swift '@usableFromInline' 'Summary'
check_attr Sources/Text/SumTree.swift '@usableFromInline' 'Summable'
check_attr Sources/Text/SumTreeCursor.swift '@inlinable' 'next'
check_attr Sources/Text/SumTreeCursor.swift '@inlinable' 'descendLeftmost'
check_attr Sources/Text/SumTreeCursor.swift '@inlinable' 'advanceToNextLeaf'

if [ "$fail" -ne 0 ]; then
    echo "==> check-inlining.sh: assertion FAILED, see messages above"
    exit 1
fi

echo "==> check-inlining.sh: promoted calls inlined, cold calls still real calls"
