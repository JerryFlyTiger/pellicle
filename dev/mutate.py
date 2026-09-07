#!/usr/bin/env python3
"""dev/mutate.py -- the ad-hoc mutation harness used throughout M1.1.

**What this is not.** It is not the port of `~/My_Projects/reticle/dev/mutate.py`, which
CLAUDE.md still names as a real job: there is no mutation *generation* here, no operator
set, no survivor report. This is the harness the M1.1 loop actually used, kept because it
ran four passes and writing it again next milestone would be waste.

**What it does.** Takes a hardcoded list of `(tag, file, description, old, new)` textual
mutations. For each: restore every file from a backup, apply exactly one replacement
(refusing to proceed unless the pattern matches exactly once), `touch` the file so SwiftPM
rebuilds, run a filtered test, and classify the result as KILLED / SURVIVED / DID NOT
COMPILE. Restores from the backups at the end and prints `git diff` so a failed restore is
visible rather than silent.

**Why it never uses `git checkout --`.** CLAUDE.md forbids it: an agent once restored a
mutation that way and cleared an entire file. Backups are plain file copies.

**How to use it.** Edit `MUTATIONS`, `FILES` and the test filter for the milestone at hand,
then run it from the repo root. Read the results with the two rules M1.1 paid for:

- A SURVIVED mutation is not automatically a coverage gap. Three of M1.1's survivors were
  *equivalent mutants* -- the mutated code computes the same answer -- and the honest
  response is a comment saying the defence cannot be observed, not a test that pretends.
- Cadence matters. Because a `concat`-based rebuild re-folds neighbours, a malformed node
  self-heals in ~0.26 operations: checking invariants after every one of 20,000 operations
  caught 80 violations, every 50 caught 2, every 1,000 caught **0**. A checklist that says
  "run the model test" can report a false pass.
"""
import os, shutil, subprocess, re

REPO = "/Users/jerrychen/My_Projects/pellicle"
BAK = "/private/tmp/claude-501/-Users-jerrychen-My-Projects-swiftemacs/e0d562a1-b61f-458a-9ae8-348e7efad0d4/scratchpad/mutbak2"
FILES = ["Sources/Text/TextSummary.swift", "Sources/Text/Chunk.swift",
         "Sources/Text/SumTree.swift", "Sources/Text/Rope.swift",
         "Tests/TextTests/ropeTests.swift", "Tests/TextTests/sumTreeTests.swift",
         "Tests/TextTests/ropePerfTests.swift", "Tests/TextTests/perfTag.swift"]

MUTATIONS = [
    ("A", "Sources/Text/Rope.swift", "seam merge always declines",
     "guard combinedCount <= 64 else {", "guard combinedCount <= 0 else {"),
    ("B", "Sources/Text/TextSummary.swift", "maxLineLen drops the cross term",
     "maxLineLen: max(lhs.maxLineLen, rhs.maxLineLen, lhs.lastLineLen + rhs.firstLineLen)",
     "maxLineLen: max(lhs.maxLineLen, rhs.maxLineLen)"),
    ("D", "Sources/Text/SumTree.swift", "splitNode loses its predicate(prefix) guard",
     "    if predicate(prefix) {\n        return (.makeLeaf([]), node)\n    }",
     "    // mutated: top guard removed"),
    ("E", "Sources/Text/SumTree.swift", "rewrap splits 2B+1 children as 1/rest",
     "    let mid = children.count / 2", "    let mid = 1"),
    ("F", "Sources/Text/SumTree.swift", "checkInvariants drops the leaf lower bound",
     "            let lowerBound = isRoot ? 0 : branchingFactor",
     "            let lowerBound = 0"),
    ("G", "Sources/Text/SumTree.swift", "checkInvariants drops the empty-leaf check",
     '            if !isRoot && items.isEmpty {', '            if false {'),
    ("K", "Sources/Text/Chunk.swift", "packed chunk summary expands utf16 wrongly",
     "            utf8: Int(utf8), utf16: Int(utf16), scalars: Int(scalars), lines: Int(lines),",
     "            utf8: Int(utf8), utf16: Int(scalars), scalars: Int(scalars), lines: Int(lines),"),
    ("L", "Tests/TextTests/ropeTests.swift", "delete range unbounded again (degeneracy)",
     "        let rawHi = lo + 1 + Int(rng.next() % 64)",
     "        let rawHi = lo + 1 + Int(rng.next() % 1_000_000)"),
]

def restore():
    for f in FILES:
        shutil.copy2(os.path.join(BAK, f.replace("/", "_")), os.path.join(REPO, f))
        os.utime(os.path.join(REPO, f), None)

os.makedirs(BAK, exist_ok=True)
for f in FILES:
    shutil.copy2(os.path.join(REPO, f), os.path.join(BAK, f.replace("/", "_")))
print("backed up", len(FILES), "files\n", flush=True)

results = []
for tag, relpath, desc, old, new in MUTATIONS:
    restore()
    path = os.path.join(REPO, relpath)
    src = open(path).read()
    if src.count(old) != 1:
        results.append((tag, desc, "PATCH DID NOT APPLY (%d matches)" % src.count(old)))
        print("!! %s: %d matches" % (tag, src.count(old)), flush=True)
        continue
    open(path, "w").write(src.replace(old, new))
    os.utime(path, None)
    p = subprocess.run("swift test --filter TextTests 2>&1", shell=True, cwd=REPO,
                       capture_output=True, text=True)
    out = p.stdout
    failed = sorted(set(re.findall(r'✘ Test "([^"]+)" (?:recorded|failed)', out)
                        + re.findall(r'✘ Test (\w+)\(\) (?:recorded|failed)', out)))
    if "error:" in out and "Test run" not in out:
        verdict = "DID NOT COMPILE"
    elif failed:
        verdict = "KILLED by: " + "; ".join(f[:60] for f in failed[:3])
    elif "Fatal error" in out or "Crash" in out:
        verdict = "KILLED (crash)"
    elif "Test run with" in out and "passed" in out:
        verdict = "SURVIVED"
    else:
        verdict = "UNCLEAR"
    results.append((tag, desc, verdict))
    print("%s  %-48s  %s" % (tag, desc, verdict), flush=True)
    open(os.path.join(BAK, "log_%s.txt" % tag), "w").write(out)

restore()
print("\n=== summary ===")
for tag, desc, verdict in results:
    print("%s  %-48s  %s" % (tag, desc, verdict))
d = subprocess.run("git diff --stat -- Sources Tests", shell=True, cwd=REPO,
                   capture_output=True, text=True)
print("\nfiles still differing from index after restore (expected: the 7 fix-round-1 files):")
print(d.stdout.strip()[-400:])
