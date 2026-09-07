#!/bin/sh
# dev/ci.sh — the gate plus the M0-specific checks: bundle assembly, the self-test
# running under the hardened runtime with the entitlements, and the bundle's signature.
# Each stage prints a heading; the first failure aborts (set -e).

set -eu

cd "$(dirname "$0")/.."

echo "=================================================================="
echo "1/5  dev/gate.sh"
echo "=================================================================="
dev/gate.sh

echo "=================================================================="
echo "2/5  dev/check-inlining.sh"
echo "=================================================================="
dev/check-inlining.sh

echo "=================================================================="
echo "3/5  dev/make-app-bundle.sh"
echo "=================================================================="
dev/make-app-bundle.sh

echo "=================================================================="
echo "4/5  .build/pellicle.app/Contents/MacOS/pellicle --self-test"
echo "=================================================================="
# This is the milestone's definition of done: the self-test passing here means MAP_JIT
# and dlopen both work under the hardened runtime with the entitlements, not merely in
# an unsigned, unentitled process where both checks pass for an uninteresting reason.
.build/pellicle.app/Contents/MacOS/pellicle --self-test

echo "=================================================================="
echo "5/5  codesign --verify --strict"
echo "=================================================================="
codesign --verify --strict .build/pellicle.app

# TODO(M6): golden-image checks against the canvas's headless render path once the
# canvas exists; there is nothing to render yet in M0.
# TODO(M0 release protocol): the powermetrics/xctrace/soak checks in PLAN.md 4.14's
# release protocol table apply to tagged releases, not this milestone's CI; nothing to
# measure yet with an empty window and no input path.

echo "=================================================================="
echo "ci.sh: all stages passed"
echo "=================================================================="
