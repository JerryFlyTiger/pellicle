# M1.1b spike: the rope's edit path

Reference prototypes from the architecture review of 2026-09-07, kept because they are
*validated* and re-deriving them is a real job. They are **not product code**, they do not
build as part of the package, and they have not been through the review loop. The design
they support is recorded in `PLAN.md`, in the M1.1b subsection of the M1.1 record.

- `proto-fragment-pushtree.swift` — the `Fragment` + n-ary join. The idea that dissolves the
  obstruction: an underfull node is legal as an *argument* to the join and illegal as a
  *stored* node, so the join never splices an underfull argument as a child, it descends its
  accumulator's right spine until the heights match and splices that argument's children in
  flat, where every one of them is well-formed. Validated over 3,926 split points across
  n in {0,1,5,6,7,12,13,50,144,145,1000,3000,20000} and all 81 height pairs, against the
  *unmodified* `checkInvariants()`: zero violations.
- `proto-path-copy-insert.swift` — the path-copy edit: descend once, rebuild the `h+1` nodes
  on the path, share every other subtree verbatim, propagate a sibling only on overflow.
  Measured at **1.22-1.55 us** for a single-byte insert into a 1 MB rope (1.88 us at 10 MB),
  against ~115 us for the shipped `split`+`concat` path in the same binary.
  **It implements insert only.** Deletion's underflow repair is the hard half and is not here.

Two cautions the review recorded, both learned the expensive way:

1. The prototype's first version handled leaf *overflow* and not *underflow*, and
   `checkInvariants()` caught it (`leaf item count 5 out of bounds [6,12]`). The underflow did
   not come from a deletion — it came from the **chunk-coalescing policy**, which merges the
   edited chunk with its right neighbour and so removes an item. Guarding the coalesce with
   `items.count > B` fixed it.
2. Measure with `-O -wmo`, in one process. `swift build -c release` passes
   `-whole-module-optimization` and `swiftc -O` alone does not, which is worth 2-3x; and
   insert cost varied 94-352 us across separate binaries built from identical source, so
   cross-binary comparisons on this machine are not reliable.
