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
