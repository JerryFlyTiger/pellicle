#!/bin/sh
# dev/gate.sh — the pellicle definition of done (CLAUDE.md, "Build and verification").
#
# Read the test result from .build/test.log, never from `$?` after a pipe: the exit code
# of `tee` is always 0.
set -eu

cd "$(dirname "$0")/.."

echo "==> swift format lint --strict --recursive Sources Tests"
swift format lint --strict --recursive Sources Tests

echo "==> swift build -c debug"
swift build -c debug

echo "==> swift build -c release"
swift build -c release

echo "==> swift test --parallel"
mkdir -p .build
swift test --parallel 2>&1 | tee .build/test.log

# The whole-process malloc counter in TextTests cannot be measured while other suites are
# allocating in the same process (see the test's own doc comment for the two in-suite
# repairs that were measured and refuted). It is skipped by the parallel run above and run
# here alone, in its own process.
echo "==> swift test --filter cursorTraversalAllocatesNothing (alone; whole-process counter)"
PELLICLE_ALLOC_PROBE=1 swift test --filter cursorTraversalAllocatesNothing 2>&1 |
    tee .build/alloc-probe.log

# Check the test's own result line, not the run summary: swift-testing prints "Test run
# with 1 test in 1 suite passed" for a *skipped* test too, so the summary alone cannot tell
# "ran and passed" from "silently did not run" — which is the whole failure mode of gating a
# test on an environment variable.
# Both clauses are load-bearing, each shown by deleting it and watching this script pass
# something it should have caught. Without the first, `--filter cursorTraversal` — which
# matches this test and `cursorTraversalSharesLeafStorage` — exits 0 on a log reading "Test
# run with 2 tests", because the second clause's line is present. Without the second, a
# skipped probe exits 0, because swift-testing prints "Test run with 1 test in 1 suite
# passed" for a skipped test too. A third clause rejecting this test's "skipped" line was
# written and then removed, by the same method: with it gone, skipping the probe still fails
# here, since a skipped test never prints "passed".
if ! grep -q "Test run with 1 test .* passed" .build/alloc-probe.log ||
    ! grep -q 'Test "cursor traversal allocates.*" passed' .build/alloc-probe.log; then
    echo "==> gate.sh: the allocation probe did not run and pass — the filter selected other"
    echo "    than exactly this one test, or the test was skipped, or it ran and failed; the"
    echo "    numbers are in .build/alloc-probe.log"
    exit 1
fi

if grep -q "Test run with 0 tests" .build/test.log; then
    echo "==> gate.sh: swift test reported zero tests — see .build/test.log"
    exit 1
elif grep -q "Test run with .* passed" .build/test.log && ! grep -q "Test run with .* failed" .build/test.log; then
    echo "==> gate.sh: all stages passed"
    exit 0
else
    echo "==> gate.sh: swift test did not report a clean pass — see .build/test.log"
    exit 1
fi
