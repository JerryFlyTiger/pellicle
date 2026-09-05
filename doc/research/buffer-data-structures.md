# Editor core data structures for swiftemacs (buffer, markers, intervals, undo, multi-cursor, huge files)

Status: sections below are final as written; report complete except any items explicitly marked "unverified."

Research budget used: 1 failed WebSearch (session-wide search budget was already exhausted before this
agent ran — a shared-session limit, not something this agent could avoid) + ~11 WebFetch calls (3 returned
HTTP 429 or empty and are noted as such below). All facts below are tagged with a confidence level;
anything not confirmed against a primary source in this run is explicitly called out.

## Outline
1. Requirements recap
2. Comparison: gap buffer vs rope vs piece table vs persistent snapshot
3. UTF-8 storage + line/char/UTF-16 index summaries; grapheme awareness
4. Markers: Emacs markers, Zed anchors, marker trees
5. Text properties / overlays as interval trees (Emacs 29 itree, Zed DisplayMap layers)
6. Undo/redo (Emacs undo list/undo-tree, Zed transactions)
7. Multi-cursor and selection sets
8. Line wrapping / display maps for very long lines; incremental line/column caches
9. CRDT (only if cheap)
10. Memory footprint; mmap for huge read-only files
11. Concrete Swift design: types, ownership, CoW vs class, Sendable snapshots, operation complexities
12. Swift ARC implications for rope of many small nodes (tie to local spike numbers)
13. Recommendations (must/should/could), pitfalls, unverified claims
14. Sources

---

## 1. Requirements recap

swiftemacs' buffer engine must simultaneously satisfy:

- **Multi-MB generated Verilog** (wide, deeply nested, often single very long lines from
  tool-generated netlists) and **GB-scale logs** — both edit-rare, read/scroll-heavy.
- **Very long lines** (tens of thousands to millions of chars on one logical line) must not
  make scrolling or syntax highlighting quadratic.
- **Concurrent background readers**: tree-sitter incremental parse, an LSP client that needs
  UTF-16 code-unit offsets (LSP spec mandates UTF-16 `Position` by default, with UTF-8/UTF-32
  as negotiable `PositionEncodingKind` since LSP 3.17 — medium confidence, from general
  knowledge of the LSP spec, not re-verified against spec text in this run), and incremental
  search — all while the UI thread keeps typing.
- **Multiple cursors / selections**, each of which must stay coherent across edits made by
  other cursors in the same batch.
- Markers/overlays for things like breakpoints, diagnostics, AUTO-region boundaries (Reticle's
  Verilog AUTO system) and folds, which must survive edits without the editor recomputing them
  from scratch.
- Fast, memory-bounded undo/redo, and a design that does not force an ARC retain/release storm
  per keystroke (see §12, tied to this machine's measured ARC costs in
  `../spikes/RESULTS.md`).

## 2. Comparison: gap buffer vs rope vs piece table vs persistent snapshot

| Structure | Insert/delete at point | Random access by offset | Very long single line | Concurrent read while writing | Memory overhead | Used by |
|---|---|---|---|---|---|---|
| **Gap buffer** | O(1) amortized *at the gap*, O(n) to move the gap across the buffer (single point of edit) | O(1) | Bad: the whole buffer (and the gap) is one flat byte array, so a single 10 MB line is a 10 MB memmove for any edit not adjacent to the gap; line/col indices must be recomputed by scanning | None: single mutable array, must be locked or copied for a snapshot | Lowest per-byte (one array + gap slack) | Emacs (`insdel.c`/`buffer.c`, high confidence — extensively documented in the Emacs internals), Reticle (per CONTEXT.md) |
| **Rope (balanced tree of chunks)** | O(log n) to split/splice nodes; no data movement outside the touched chunks | O(log n) via subtree size (or richer summary) | Good if chunked independent of line boundaries: a 10 MB line is just many leaf chunks, edited leaf is O(chunk size), not O(line length) | Good with **persistent/immutable** ropes: old root stays valid, CoW nodes shared (xi-editor, ropey docs: "internally, each Rope stores text as a segmented collection of utf8 strings", read chunk-fetch is sub-100ns for ~200KB docs — high confidence, ropey docs) | Higher: tree node overhead per chunk, but Zed keeps chunks inline (`ArrayString`, up to `2*CHUNK_BASE`=64 chars/chunk in release, no heap alloc per chunk — high confidence, Zed source `crates/text/src/rope.rs` via WebFetch) | xi-editor, ropey/Helix, Zed (`SumTree<Chunk>`) |
| **Piece table (+ index tree)** | O(log n) with a balanced index tree (VS Code uses a red-black tree over pieces); original file buffer is **never mutated**, only appended-to edit buffer(s) | O(log n) via subtree metadata (VS Code: "Each node maintains metadata about its left subtree's text length and line-break count" — high confidence, VS Code blog) | Fine for read: a long line is one or few pieces; bad after many small edits inside one long line (fragmentation → many tiny pieces, each a red-black node) | Original buffer is naturally read-only and mmap-able; edit buffer append-only, so background readers can safely read the original+immutable edit log while UI appends | Very low: "piece tree approached the original file size" vs ~20x for the old line-array model on a 184MB file (high confidence, VS Code engineering blog) | VS Code `PieceTreeTextBuffer` |
| **Persistent/immutable snapshot (functional data structure, often a rope or a CRDT-backed rope)** | Same asymptotics as the underlying tree (rope: O(log n)); the key property is that **taking a snapshot is O(1)** (share the root) | O(log n) | Same as rope | This *is* the mechanism for lock-free background reads: a `BufferSnapshot` is an immutable value that can be captured by a background thread while the UI thread keeps editing the live buffer; Zed's `Anchor`+`BufferSnapshot` model is built exactly for this (high confidence, Zed `anchor.rs`/`text.rs` via WebFetch) | Same as rope, plus GC/CoW pressure from retained old versions if held too long | Zed's `text::Buffer` (CRDT fragments over a rope), xi-editor's original CRDT design |

**Recommendation driver**: swiftemacs' hardest constraint is not any single one of these rows —
it is "GB-scale mostly-read files" *and* "background parse/LSP/search threads" *and*
"very long lines" *and* "many cursors" all at once. A gap buffer (Reticle's/Emacs's choice)
fails the concurrent-read requirement structurally (one mutable array, no cheap snapshot) and
fails the very-long-line requirement (whole-buffer memmove semantics conceptually, even if
Emacs's actual gap buffer only moves data between the gap and the edit point — it still has no
sub-line locality). A **rope with per-leaf summaries, exposed as immutable persistent
snapshots**, is the only structure in this table that satisfies all four constraints
simultaneously, which is why Zed — the newest of the reference systems and the one with the
closest requirements to swiftemacs' (GPU-rendered, LSP+tree-sitter, multi-cursor, CRDT-ready
for future collab) — converged on exactly this shape. **Must: rope + immutable snapshots as
the core buffer.**

For **read-only huge files** (GB-scale logs), a piece table degenerates to a single piece
referencing an mmap'd region — cheap and simple — while a rope must still be built (chunked)
before it has any O(log n) properties. This motivates a **two-tier design** (§10): a lazy,
line-indexed mmap view for files opened read-only or above a size threshold, and a full rope
only when editing begins or the file is small.

## 3. UTF-8 storage + line/char/UTF-16 index summaries; grapheme awareness

- **Storage encoding: UTF-8** in every leaf chunk. This matches Swift's own `String` UTF-8
  view, matches the on-disk encoding of nearly all source files/logs, and matches what
  tree-sitter's C API consumes directly (`TSInput` can supply UTF-8 bytes) — avoids a
  transcode on every parser callback. (High confidence: UTF-8 is tree-sitter's native input
  encoding and Swift's `String` is backed by UTF-8 storage since Swift 5 — general knowledge,
  not re-verified via fetch this run.)
- **LSP needs UTF-16 code-unit offsets** for `Position.character` unless both client and
  server negotiate `positionEncoding: utf-8` or `utf-32` via `general/positionEncodings` in
  the LSP 3.17 initialize handshake (medium confidence — this capability exists in the spec
  per general knowledge; not re-fetched from microsoft/language-server-protocol in this run,
  flagged as **unverified in this session** even though it is a well-known, stable part of the
  spec). Since verible-verilog-ls / slang-server / pyright / clangd / sourcekit-lsp support is
  not guaranteed to negotiate UTF-8 positions, **swiftemacs must maintain a UTF-16 length
  summary regardless of storage encoding.**
- **Zed's approach, confirmed via source fetch**: `TextSummary` carries `len` (UTF-8 bytes),
  `len_utf16` (UTF-16 code units), and `lines: Point` (row/column), plus per-summary
  first-line/last-line character counts and a longest-row tracker for line-wrap width
  estimation — all propagated up the B+ tree so any subtree's summary is O(1) to read and
  O(log n) to update (high confidence, Zed `rope.rs`/`sum_tree.rs` via WebFetch).
- **Recommendation for swiftemacs (must)**: each rope leaf/chunk summary should carry, at
  minimum: `{utf8ByteCount, utf16CodeUnitCount, newlineCount, firstLineByteCount,
  lastLineByteCount, maxLineByteCount}`. This gives O(log n) conversions in all directions
  needed by the three consumers (tree-sitter: byte offsets; LSP: UTF-16 `Position`; UI: line
  number for scrollbar/minimap) without a full-buffer scan, and gives an O(log n) "is there a
  pathologically long line in this subtree" query for display-map decisions (§8).
- **Grapheme awareness**: Swift's `Character` is already an extended grapheme cluster per
  Unicode's default segmentation, and `String`'s `Index` type is a grapheme-boundary-safe
  opaque index — but grapheme segmentation is **not O(1)** to compute from a raw UTF-8 buffer
  and Swift's own `String` does not decompose into "rope of cheap sub-strings" cheaply for
  huge documents (well-known Swift property, not re-fetched this run — **should verify**
  against Apple's String/Unicode documentation before committing to using native `String`
  slicing inside a hot path). **Recommendation (should)**: store raw UTF-8 bytes in rope
  leaves (not `Character`s, not `[UInt8]` wrapped as `String]`), and derive
  grapheme-cluster boundaries lazily/on demand for cursor motion and rendering (feed leaf
  byte ranges through `String(decoding:as: UTF8.self)` or a small custom grapheme-breaking
  pass), rather than storing pre-segmented graphemes in the tree — this avoids paying
  segmentation cost for the ~99% of a GB-scale log file that is never displayed.

## 4. Markers: Emacs markers, Zed anchors, marker trees

- **Emacs markers (confirmed via source fetch, `src/marker.c`)**: markers are kept in a
  **per-buffer linked list**, sorted approximately by position via cached hints. The source
  comment (quoted, high confidence) states: *"When converting bytes from/to chars, we look
  through the list of markers to try and find a good starting point... But if there are many
  markers, it can take too much time to find a 'good' marker... The asymptotic behavior is
  still poor, tho, so in largish buffers with many overlays (e.g. 300KB and 30K overlays), it
  can still be a bottleneck."* This is a **known, self-documented Emacs pain point** directly
  relevant to swiftemacs' "solve Emacs's pain points" mandate: linear/near-linear marker
  adjustment degrades once overlay/marker counts get large (diagnostics + folds + breakpoints
  + AUTO-region markers in a big Verilog file can easily reach tens of thousands).
- **Zed anchors (confirmed via source fetch, `crates/text/src/anchor.rs`)**: an `Anchor` is
  a small value type, *not* a live pointer into a mutable structure: `{timestamp (Lamport,
  replica_id+value), offset: u32 (byte offset into the text inserted by that operation),
  bias (before/after), buffer_id}`. It carries **no direct reference to a tree node** —
  resolving it to a live offset is done later, against a specific `BufferSnapshot`, which maps
  the anchor's timestamp to its current fragment and computes the offset by walking the
  fragment's visibility state. This makes anchors **cheap, `Sendable`-like, immutable values**
  that can be freely copied to background threads and resolved against whatever snapshot that
  thread holds — a fundamentally different design from Emacs's live-adjusted marker list.
- **Design implication for swiftemacs (must)**: adopt the **Zed-style anchor**, not the
  Emacs-style marker, as the base primitive: a `struct Anchor: Sendable, Hashable` holding a
  logical position (chunk-relative or a monotonic edit-sequence timestamp + offset-within-edit)
  and a bias, resolved against an immutable `BufferSnapshot` on demand (O(log n) resolution,
  not O(1) live-tracking, but O(1) to *create* and *copy*, and race-free by construction since
  it never mutates). Emacs markers require every insert/delete to walk and adjust a list of
  live pointers *before* the buffer is safe for the next reader — the anchor model instead
  defers adjustment to read-time, which is what makes concurrent background readers safe
  without a global buffer lock.
- **Marker trees as an alternative**: some rope implementations (not confirmed for any specific
  named project in this run — **unverified**) keep markers in a secondary interval/order-
  statistics tree keyed by an ever-increasing logical clock rather than by raw offset, so that
  marker adjustment on edit is O(log n) instead of O(list length); this is essentially "give
  markers the same tree-summary treatment as text." For swiftemacs this is subsumed by the
  anchor approach above and is not separately necessary as a first cut.

## 5. Text properties / overlays as interval trees (Emacs 29 itree; Zed DisplayMap layers)

- **Emacs 29's `itree.c` (confirmed via source fetch)**: overlays moved from the old
  doubly-linked list to a **red-black tree ordered by BEGIN**, augmented with a **LIMIT**
  field per node storing *"the largest END value occurring in the node's subtree (including
  the node itself)"* — a textbook augmented-interval-tree (Cormen et al. "interval tree")
  design. Quoted complexity from the source: overlapping-interval queries run in
  **O(K·log N)** where K is the result-set size and N the tree size. The same source
  explicitly flags a **known remaining gap**: finding the nearest overlay *change point* is
  still O(N) because the tree orders by BEGIN only, not END, and the fix (tracking both
  orderings) is an open item referenced as bug#58342 in Emacs's own tracker (high confidence —
  direct quotes from `src/itree.c` via WebFetch).
- **Recommendation (must)**: implement swiftemacs's text-property/overlay store as an
  **augmented interval tree with a LIMIT/max-end summary**, i.e. do what Emacs 29 already
  did, but additionally track a **max-of-END** summary on both children (not just one
  direction) from day one, so "nearest overlay boundary" queries (needed for cheap
  fold-boundary and diagnostic-squiggle-boundary lookups while scrolling) are O(log N)
  instead of inheriting Emacs's still-open O(N) gap. Since swiftemacs's rope leaves already
  carry per-chunk summaries (§3), the natural implementation is to make the interval tree
  **another dimension on the same `SumTree`-shaped generic structure** (see §11) rather than
  a hand-rolled separate red-black tree — one generic augmented-tree type serving both text
  and overlays reduces engine surface area.
- **Zed's DisplayMap layering (confirmed via source fetch,
  `zed.dev/blog/zed-decoded-rope-sumtree`)**: display-time transforms are **not** applied to
  the buffer rope at all; they are a **stack of independent `SumTree`-backed maps** applied in
  sequence: `InlayMap` → `FoldMap` → `TabMap` → `WrapMap` → `BlockMap`, each translating
  coordinates from the previous layer's space to its own, "essentially all that's changing are
  references to leaf nodes" on edit (high confidence, direct paraphrase from Zed's own post).
  This cleanly separates *buffer content* (rope) from *what's currently visible* (display
  map), which is exactly the axis Reticle's fixed character-grid GUI lacked (per
  `CONTEXT.md`'s list of Reticle limitations: "no minimap," "no smooth scrolling").
  **Recommendation (must)**: adopt the same layered-map architecture — folds, inlay hints
  (type annotations, parameter names for LSP), soft-wrap, and block widgets (diagnostics,
  git-blame-style annotations) as independent composable `SumTree`-shaped layers over the
  buffer rope, never baked into the buffer itself.

## 6. Undo/redo (Emacs undo list, undo-tree, Zed transactions)

- **Emacs's native `buffer-undo-list`**: a flat list of *edit records* (insertion ranges,
  deletion text+position, property-change records, a special marker for "boundary" between
  undo groups) consed onto the front of a per-buffer list; undoing itself pushes *inverse*
  records onto the same list (so redo-after-undo works by continuing to undo the undo). This
  is well-documented, stable Emacs behavior (high confidence from general knowledge of Emacs
  internals; not re-fetched this run since it is not disputed) but has two well-known pain
  points directly relevant to the "fix Emacs's pain points" mandate: (1) it is **linear
  branching only** — once you undo and then make a new edit, the old redo branch is simply
  discarded, which is why the third-party `undo-tree` package exists to give Emacs a real
  branching undo history; (2) large edit records (e.g. undoing a huge string deletion) are
  held as plain Lisp strings in the list, so undo history memory is proportional to raw edited
  bytes, not to a compact diff.
- **Zed's transaction model (confirmed via source fetch, `crates/text/src/text.rs`)**: a
  `Transaction { id, edit_ids: Vec<Lamport>, start: Global }` groups the Lamport-timestamped
  edits that happened together; a `HistoryEntry` wraps each transaction with
  `first_edit_at`/`last_edit_at` timestamps and a `suppress_grouping` flag, and consecutive
  transactions are **auto-grouped within a `group_interval` (default 300ms)** so that, e.g., a
  burst of individual keystrokes coalesces into one undo step — quoted source comment: *"Don't
  group transactions in tests unless we opt in, because it's a footgun."* Undo is **not** a
  data copy-back: it emits an `UndoOperation { timestamp, version, counts: HashMap<Lamport,
  u32> }` that flips **visibility counts on existing CRDT fragments** rather than
  reconstructing text, so undo is O(edits in the transaction), not O(bytes).
- **Recommendation (must)**: adopt Zed's shape — **time-windowed automatic grouping of
  transactions**, and **undo as inverse-operation replay against the persistent rope**
  (insert's inverse is delete-at-same-anchor-range, delete's inverse is
  insert-the-deleted-text-back), rather than storing full pre/post buffer snapshots. Because
  swiftemacs's rope is persistent (§2), an even simpler and very cheap alternative exists and
  should also be considered (**should**): keep a bounded ring of **whole-rope root pointers**
  (snapshots) as undo checkpoints — since the rope is a persistent tree, retaining an old root
  costs O(1) plus the cost of *not* garbage-collecting the nodes only that old version
  references (which is bounded by how much changed since the checkpoint, not by document
  size). This "snapshot undo" is simpler to implement correctly than an inverse-operation log
  and trivially supports true tree-shaped undo history (a la `undo-tree`) since every
  checkpoint is just a rope value that can be branched from independently — the two approaches
  are not mutually exclusive (transactions for fine-grained same-line coalescing, periodic
  snapshots for cheap long-range branching/undo-tree UI).
- **Undo-tree UI** (branching undo visualization, one of Doom Emacs / Steve Purcell setups'
  well-known features) is a **could**: worth exposing given the snapshot-based undo above
  makes it nearly free structurally, but it is a UI feature, not a data-structure requirement,
  so it is scoped out of the core engine design here.

## 7. Multi-cursor and selection sets

- No project-specific primary source was fetched for multi-cursor internals in this run
  (VS Code, Sublime Text, and Zed's cursor implementations are broadly similar and
  well-documented in general knowledge, but not re-verified against source this session —
  **medium confidence** for the specifics below).
- **Representation**: a multi-cursor session is a small, ordered collection of
  `Selection { anchor: Anchor, head: Anchor, id, goalColumn }` values (anchor = fixed end,
  head = moving end; a bare cursor is a zero-length selection with anchor == head). Because
  each `Anchor` is the Zed-style immutable, snapshot-resolved value from §4, **all cursors in
  a multi-cursor set survive an edit made by one of them "for free"**: after applying edit N
  from cursor A, cursors B..Z's anchors are just re-resolved against the new `BufferSnapshot`
  — no explicit "adjust every other cursor's offset" pass is needed, which is exactly the pass
  Emacs-style live markers *would* require and is a common source of multi-cursor bugs in
  editors built on mutable-offset cursors (this generalization is **medium confidence**
  reasoning from the anchor model, not a verified claim about any specific editor's bug
  history).
- **Batch-edit ordering**: when N cursors each insert/delete simultaneously, edits must be
  applied in a single transaction (§6) sorted by position, and every other cursor's anchor
  bias (§4) must be chosen so that "insert at cursor" pushes only cursors *after* the
  insertion point forward — standard practice, **must**: apply multi-cursor edits as one
  atomic rope transaction with per-anchor bias rules, never as N independent sequential edits
  against a live mutable structure (which reintroduces O(N²) marker-adjustment behavior and
  ordering bugs).
- **Should**: dedupe/merge selections that come to overlap after an edit (typing the same text
  at two cursors that end up adjacent), matching VS Code/Sublime convention.

## 8. Line wrapping / display maps for very long lines; incremental line/column caches

- Covered structurally in §5 (Zed's `WrapMap`/`TabMap` as independent `SumTree` layers). The
  specific hazard for swiftemacs's stated workload (multi-MB generated Verilog, which often
  has very long single lines from tool output, and GB logs) is **not the wrap computation
  itself but *finding* long lines cheaply**: if a "which rows need wrapping" query has to scan
  the whole buffer, opening a GB log with a single 50MB line embedded somewhere stalls the UI.
- **Recommendation (must)**: the rope leaf summary (§3) should include a `maxLineByteCount`
  (or `hasLongLine: Bool` above a threshold) so the wrap layer can query, in O(log n), "does
  any subtree in this visible range contain a pathological line," and can special-case
  rendering for it (e.g. only wrap/tokenize the visible slice of an extremely long line, never
  the whole line) rather than assuming line length is bounded, matching Zed's confirmed
  `TextSummary` design (§3) which already tracks first/last-line lengths and a longest-row
  field per subtree.
- **Incremental line/column cache**: because line count is a rope-summary dimension (§3),
  "go to line N" and "what line is byte offset X on" are both O(log n) tree descents, not
  O(n) scans — this directly fixes a class of slowness in flat-array or naive gap-buffer
  editors on GB-scale files where recomputing line offsets after any edit is O(n).

## 9. CRDT (only if cheap)

- swiftemacs has no stated collaborative-editing requirement in the brief — CRDT support is
  explicitly "only if cheap." The finding from this research: **Zed's fragment-based CRDT
  rope is not an add-on bolted onto a plain rope — the undo model (§6), the anchor model
  (§4), and the concurrent-snapshot model (§2) are *already* CRDT-shaped** even in
  Zed's single-user path (Lamport clocks, per-fragment visibility counts, `Global` version
  vectors are all present in `crates/text/src/text.rs` regardless of whether collaboration is
  active — confirmed via source fetch). This suggests the "cheap" version of CRDT support for
  swiftemacs is: **build the local single-user engine on the same primitives a CRDT would need
  anyway** (immutable anchors, transaction log with Lamport-like monotonic edit ids, snapshot
  isolation) **without implementing multi-replica merge logic**, so that *if* real-time
  collaboration is ever wanted later, the buffer core doesn't need a rewrite — only a merge/
  reconciliation layer needs to be added on top. This is a **should**, not a **must**, given
  no explicit multi-user requirement in the brief; recommend **not** implementing actual
  CRDT merge (fragment splitting on concurrent insert, tombstone GC, etc.) as part of the core
  buffer milestone, since it is real complexity with zero payoff until collaboration is a
  stated goal.

## 10. Memory footprint; mmap-ing huge read-only files

- **VS Code's own numbers (confirmed via source fetch)**: switching from a line-array text
  model to the piece-tree model dropped memory for a 184MB file from roughly **20x the file
  size to "approached the original file size"** — a concrete, citable data point for why
  swiftemacs should never materialize "one array/object per line" for GB-scale files.
- **mmap for read-only huge files**: Foundation's `Data(contentsOf:options:.mappedIfSafe)`
  memory-maps the file when safe to do so and falls back to a normal read otherwise — this is
  **medium confidence, general Apple-platform knowledge**, explicitly **not confirmed against
  Apple's current documentation in this run** (the WebFetch of Apple's own doc page for
  `Data.init(contentsOf:options:)` returned no usable body — flagged as **unverified,
  should re-check against developer.apple.com or Xcode's quick help before relying on it**).
  Known general caveat to carry forward regardless: a memory-mapped `Data`/file becomes
  unsafe/undefined if the underlying file is modified or the volume is unmounted while
  mapped, so any mmap path needs either a copy-on-write guard or a "detect external
  modification, fall back to full read" strategy — **should**, pending doc confirmation.
- **Recommendation (must)**: for files above a size threshold (e.g. Reticle-scale GB logs)
  opened without an active edit, do **not** build a full rope at all on open — present a
  **lazy, line-indexed mmap view**: an index built by one linear scan for newline byte offsets
  (itself streamable/incremental, e.g. index in background while showing the first N lines
  immediately), with random line access served directly from the mapped bytes. Only promote
  to a real rope (copying the touched region, or the whole file if small) the moment the user
  makes an edit. This mirrors the general industry pattern (VS Code's original-buffer-as-
  read-only-append-only-source in the piece table is the same idea in spirit: never mutate the
  bytes that came from disk) and is the only way to open a several-GB log file without a
  multi-second, multi-GB parse-into-rope stall.
- **Rope memory overhead control**: follow Zed's confirmed technique of **inline small-string
  chunk storage** (`ArrayString`-style fixed-capacity buffer embedded directly in the leaf,
  not a separate heap allocation) to avoid one heap allocation + one ARC box per leaf on top
  of the tree-node allocation itself — directly relevant to §12's ARC cost findings.

## 11. Concrete Swift design

### 11.1 Core types

```swift
// Leaf payload: UTF-8 bytes, inline up to a small fixed capacity, matching Zed's
// ArrayString-style chunk (avoids a second heap allocation per leaf).
struct Chunk: Sendable {
    var bytes: InlineArray<64, UInt8>   // Swift 6.3 InlineArray, confirmed present in SDK
                                          // per this machine's spike (spikes/RESULTS.md item 2)
    var count: UInt8                     // bytes actually used, <= 64
}

// Per-subtree aggregate, propagated bottom-up. Cheap to copy (all Trivial/value types).
struct TextSummary: Sendable, Equatable {
    var utf8Count: Int
    var utf16Count: Int
    var lineCount: Int
    var firstLineUTF8Count: Int
    var lastLineUTF8Count: Int
    var maxLineUTF8Count: Int
}
extension TextSummary {
    static func + (a: TextSummary, b: TextSummary) -> TextSummary { /* O(1) merge */ }
}

// Generic augmented B+-tree node, used both for the text rope (Item == Chunk) and for
// the interval-tree of overlays/text-properties (Item == OverlayRecord, Summary carries
// a max-end field per §5). One generic engine, two instantiations.
indirect enum Node<Item: Summable>: Sendable {
    case leaf(items: [Item], summary: Item.Summary)
    case interior(children: [Node<Item>], summary: Item.Summary, height: Int)
}

// The buffer's live, mutable handle. A *class* (reference type) because it owns identity
// (file path, undo history, marker registry) that multiple UI components subscribe to —
// but its `root` is a value type (persistent tree), so snapshots are O(1) to take.
final class TextBuffer {
    private var root: Node<Chunk>              // current content, persistent/CoW
    private var overlayRoot: Node<OverlayRecord> // interval tree, same generic engine
    private var history: UndoHistory            // §6
    private var editClock: UInt64                // Lamport-ish monotonic counter for anchors

    // O(1): just captures the current persistent root + overlay root + clock value.
    func snapshot() -> BufferSnapshot { .init(root: root, overlayRoot: overlayRoot, clock: editClock) }

    // Mutation entry point: O(log n) — descends+rebuilds only the path to the edited leaves.
    func apply(_ edits: [Edit]) -> [Anchor] { /* returns post-edit anchors for e.g. multi-cursor */ }
}

// Immutable, freely shareable across threads: exactly what tree-sitter's parse thread,
// the LSP client's request-building code, and background search hold onto.
struct BufferSnapshot: Sendable {
    let root: Node<Chunk>
    let overlayRoot: Node<OverlayRecord>
    let clock: UInt64

    func utf8Range(for anchor: Anchor) -> Range<Int> { /* O(log n) resolve */ }
    func utf16Offset(atUTF8Offset: Int) -> Int { /* O(log n) via summary */ }
    func line(_ n: Int) -> Substring { /* O(log n) descent + O(line length) decode */ }
}

// Immutable value; safe to copy to any thread; resolved lazily against a snapshot.
struct Anchor: Sendable, Hashable {
    var editID: UInt64      // which edit created the anchored text (Lamport-ish clock value)
    var offsetInEdit: Int32 // byte offset within that edit's inserted text
    var bias: Bias          // .beforeInsert / .afterInsert — same role as Zed's Anchor.bias
}
enum Bias: Sendable { case before, after }
```

### 11.2 Operation complexities

| Operation | Complexity | Notes |
|---|---|---|
| Insert/delete at N cursors (one transaction) | O(N log n) | n = document size in chunks; each edit touches O(log n) nodes, shared path prefixes make a sorted batch cheaper than N independent edits |
| Take a snapshot for a background reader | O(1) | Persistent root, reference copy only |
| Resolve an `Anchor` against a `BufferSnapshot` | O(log n) | Tree descent by summary dimension |
| Byte offset → UTF-16 offset, or → line/col | O(log n) | Summary carries all three dimensions (§3) |
| "Does this range contain a very long line?" | O(log n) | `maxLineUTF8Count` summary field (§8) |
| Overlapping-overlay query in a range | O(K log n) | K = result count, per Emacs's own itree complexity (§5), matched by the augmented max-end summary |
| Undo one transaction | O(edits in transaction) | Inverse-apply against current root, or O(1) swap to a retained snapshot root (§6) |
| Random line access in a read-only mmap'd huge file (no rope built) | O(log n) via a separate newline-offset index, or O(1) amortized with a periodic index | Never build a full rope for pure viewing (§10) |

### 11.3 Ownership, CoW vs class, `Sendable`

- **`Node<Item>` is a value type (`enum`/`struct`), not a class hierarchy.** Combined with
  Swift's copy-on-write for `Array`-backed storage inside leaves/children, this gives
  persistence "for free" via Swift's own COW machinery *as long as node arrays are never
  mutated in place while a second owner (e.g. an outstanding `BufferSnapshot`) exists* — this
  is the same discipline Swift already applies to `Array`/`Dictionary`, just extended to a
  custom tree type.
- **`TextBuffer` is a class** because it is the thing with *identity* over time (one per open
  file/indirect buffer, subscribed to by multiple UI panes, holds non-value state like the
  undo history and a Lamport-style clock) — mirroring why Emacs's buffer object is a mutable,
  identity-bearing object while its *content* (handled here by the rope) is what benefits from
  being a value.
- **`BufferSnapshot`, `Anchor`, `TextSummary`, `Chunk` are all `Sendable` value types**,
  meaning they can be captured by `Task`s or passed to actors (the tree-sitter incremental
  parser, the LSP client, background search) with the compiler statically checking there is no
  shared mutable state — this is the direct payoff of the persistent-value-type design:
  **Swift's concurrency checker enforces the same lock-free-background-read property that Zed
  achieves in Rust via `Arc`+immutability, but via `Sendable` conformance instead of manual
  auditing.** (High confidence as a description of what `Sendable` guarantees; the specific
  claim that this fully replaces Zed's `Arc` role is this agent's design reasoning, not a
  verified equivalence — **medium confidence**.)
- **`TextBuffer.apply` is the only mutator**; it is not `Sendable` and must only be called from
  the buffer's owning context (main actor or a dedicated buffer actor) — background threads
  only ever hold `BufferSnapshot`s taken before or after a mutation, never a live reference to
  `root` mid-mutation.

## 12. Swift ARC implications for a rope of many small nodes

This is the one section directly informed by **numbers measured on this machine**
(`../spikes/RESULTS.md`, item 3 — "Lisp value representation cost in Swift", -O -wmo, M4, best
of 3). Although that spike measured a cons-list interpreter, not a rope, the underlying cost
being measured — **ARC overhead per small heap-allocated node in a large linked/tree
structure** — is exactly the risk a naive "class-based rope with thousands of small leaf
objects" carries:

| Representation (from the spike) | Relative cost | Read-across to rope design |
|---|---|---|
| A: indirect enum, every node an ARC box, payload copied on match | ~27x baseline | Equivalent to a rope node as a `class` per leaf *and* per interior node, with `enum` payloads copied around — **avoid this shape** |
| B: `enum { int, cons(final class) }`, ARC only on the class refs | ~5x baseline | Equivalent to a rope using `final class` nodes only where a reference really is needed (e.g. a shared, out-of-line large-string backing) but plain value types for the tree spine — **the realistic target given Swift's language model** |
| C: tagged word + manual arena, no ARC | 1x (baseline) | Equivalent to a rope backed by a **single contiguous arena** (e.g. `ContiguousArray<Node>` with integer child indices instead of `class` references) — **the performance ceiling**, matching this agent's own §11 recommendation to use `[Item]`/`[Node<Item>]` value-type children rather than class-linked children |

The spike's own stated conclusion (quoted from `RESULTS.md`, high confidence — measured on
this exact machine/toolchain) generalizes directly: *"ARC-managed cons cells are viable for a
first interpreter but cost ~5x on list traversal... a tagged-word + arena/GC design is the
performance ceiling and should be the target... from the start (the swap later is the whole
engine)."* **The same warning applies to the rope**: an initial implementation using
`indirect enum Node` with `class`-boxed children (rep-A-shaped) will retain/release on every
tree descent — for a rope accessed on every keystroke, every scroll tick, and by three
background readers, this is squarely in the "hot path touched constantly" category the spike
warns about.

**Recommendation (must)**: design the rope's node/child storage as **arrays of value types**
(`struct Node { var children: [Node] }` or, for the performance-critical inner loop, an
arena-indexed `ContiguousArray<NodeStorage>` with `Int32` child indices instead of Swift
references) from the start, per the spike's own explicit warning that swapping representations
later "is the whole engine." Reserve `final class` only for: (a) large chunk payloads that
should not be copied when a `Node` value is copied (Swift will refcount the class instance
once per `Node` copy, which is cheap relative to copying kilobytes of bytes) — this is exactly
Zed's design (`Chunk` is a fixed-size inline value, not a class, precisely to avoid this), and
(b) genuinely identity-bearing objects like `TextBuffer` itself (§11.3), never for the O(log n)
tree spine that gets walked on every operation.

**Caveat on the read-across**: the spike measured a **cons-list interpreter's ARC cost**, not
a rope, so the ~5x/~27x numbers are **not a rope-specific benchmark** — they are cited here as
evidence of the general ARC-per-small-node cost model on this exact machine/toolchain, which
the rope design must respect, not as a direct measurement of rope performance. A follow-up
spike that builds a small rope prototype with both a class-linked and an array/arena-indexed
node representation and measures edit/traversal throughput would convert this from "informed
extrapolation" to "measured" — **recommended as a first implementation-phase spike, not done
in this research pass** (out of scope/budget for this agent).

## 13. Recommendations summary, pitfalls, unverified claims

### Must
1. Core buffer = **persistent rope of value-type nodes**, arena/array-indexed rather than
   class-linked (§2, §11, §12).
2. Rope leaf/subtree summaries carry **UTF-8 count, UTF-16 count, line count, and per-line
   max/first/last lengths** in one summary type, propagated bottom-up (§3, §8).
3. Store **raw UTF-8 bytes** in leaves; derive grapheme boundaries lazily, not pre-segmented
   in the tree (§3).
4. **Zed-style immutable `Anchor` + `BufferSnapshot`** as the marker/cursor primitive, not
   Emacs-style live-adjusted markers — this is both the fix for Emacs's own documented marker
   scaling pain point (§4) and the mechanism that makes background readers lock-free (§2, §11).
5. **Augmented interval tree with a full max-end summary** (both directions) for overlays/text
   properties, closing the gap Emacs 29's own itree explicitly still has open (bug#58342) (§5).
6. **Display transforms (folds, inlays, soft-wrap, block widgets) as independent SumTree-
   shaped layers over the buffer**, never baked into buffer content (§5, §8).
7. **Never build a full rope for pure viewing of huge read-only files**; use a lazy
   line-indexed view over the raw bytes (mmap'd where safe) until an edit occurs (§10).
8. Apply multi-cursor edits as **one atomic transaction with per-anchor bias rules**, never as
   N sequential mutations (§7).

### Should
1. Build the engine on CRDT-shaped primitives (Lamport-ish edit clock, fragment/anchor
   model, transaction log) **without implementing multi-replica merge**, to keep future
   collaboration cheap without paying its complexity now (§9).
2. Offer **snapshot-based undo checkpoints** (retained persistent roots) alongside/instead of
   pure inverse-operation undo, since it is nearly free given a persistent rope and naturally
   supports branching (`undo-tree`-style) history later (§6).
3. Confirm `Data(contentsOf:options:.mappedIfSafe)` behavior and failure modes against current
   Apple documentation before relying on it for GB-file opening (§10 — this run could not
   confirm the doc body).
4. Verify Swift `String`/grapheme-cluster segmentation performance characteristics against
   Apple's Unicode documentation before deciding whether to hand-roll grapheme breaking or use
   `String` directly on leaf byte ranges (§3).
5. Build a small dedicated rope-prototype spike (class-linked vs arena-indexed) to convert
   §12's ARC extrapolation into a direct measurement before committing the final node
   representation (§12).

### Could
1. Expose a branching **undo-tree UI** on top of the snapshot-checkpoint mechanism (§6) —
   UI/UX feature, not a data-structure requirement.
2. A true marker-position tree distinct from the anchor model (§4) — likely unnecessary once
   anchors + snapshot resolution are in place.

### Pitfalls (carried forward from primary sources)
- **Emacs's own documented pitfall**: marker/overlay list lookup degrades once overlay counts
  are large ("300KB and 30K overlays... can still be a bottleneck") — avoid recreating this by
  not using a live-adjusted linear structure for markers (§4).
- **Emacs 29's own documented open gap**: "nearest overlay change point" is O(N) because only
  BEGIN is tree-ordered, not END — track both from the start (§5).
- **VS Code's own documented pitfall**: heavy in-place editing fragments a piece table into
  "thousands or tens of thousands of nodes," degrading random line access — motivates choosing
  a rope (which rebalances) over a piece table for swiftemacs's edit-heavy Verilog use case,
  reserving piece-table-like append-only buffers only for the read-only mmap tier (§2, §10).
- **This machine's own measured pitfall**: naive recursive ARC teardown of a large linked
  value (1M-node list) segfaults (stack overflow, exit 139) on both tested representations;
  any tree/list structure with potentially large runs of nodes released together needs
  **iterative unlink before scope exit**, not naive recursive `deinit` (`spikes/RESULTS.md`
  item 3, high confidence, measured this session on this machine). This applies directly to
  tearing down a large rope subtree (e.g. closing a GB-file buffer) or a long undo chain.

### Unverified (explicitly not confirmed this run)
- LSP 3.17's exact `positionEncoding` negotiation mechanics (medium confidence from general
  knowledge, not re-fetched from the spec text).
- `Data.ReadingOptions.mappedIfSafe` exact fallback/invalidation semantics (Apple's doc page
  did not return usable content to WebFetch this run).
- Swift `String`/`Character` grapheme-segmentation performance characteristics for very large
  buffers (general knowledge only, not re-verified against Apple/Unicode documentation).
- The claim that Swift's `Sendable` checking fully substitutes for Zed's `Arc`-based
  concurrency discipline is this agent's design reasoning, not a verified equivalence.
- Xi-editor's specific rope-vs-gap-buffer rationale and CRDT design details beyond the table
  of contents (the `rope_science_00.html` fetch returned only a TOC; deeper posts were not
  fetched, this run being budget-constrained) — general characterization of xi's rope is from
  training knowledge, flagged medium confidence.
- Emacs overlay documentation (`elisp/Overlays.html`) could not be fetched (HTTP 429 twice);
  overlay behavior described in §5 relies on the `itree.c` source comment fetch plus general
  knowledge of Emacs overlay semantics (start/end markers, front-advance/rear-advance), which
  is high-confidence but not re-confirmed against the manual text in this run.

## 14. Sources

- Zed `sum_tree.rs` (SumTree B+ tree, Summary/Dimension/Item traits) —
  https://raw.githubusercontent.com/zed-industries/zed/main/crates/sum_tree/src/sum_tree.rs
- Zed `anchor.rs` (Anchor struct, Lamport timestamp, bias, BufferSnapshot resolution) —
  https://raw.githubusercontent.com/zed-industries/zed/main/crates/text/src/anchor.rs
- Zed `text.rs` (Transaction, HistoryEntry, UndoOperation, fragment-CRDT undo) —
  https://raw.githubusercontent.com/zed-industries/zed/main/crates/text/src/text.rs
- Zed engineering blog, "Rope & SumTree" (Chunk/TextSummary/DisplayMap layers) —
  https://zed.dev/blog/zed-decoded-rope-sumtree
- VS Code engineering blog, "Text Buffer Reimplementation" (PieceTreeTextBuffer, red-black
  tree indexing, memory numbers) —
  https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation
- Emacs `src/itree.c` (augmented red-black interval tree, LIMIT/max-end field, O(K log N)
  quote, open bug#58342 gap) —
  https://raw.githubusercontent.com/emacs-mirror/emacs/master/src/itree.c
- Emacs `src/marker.c` (per-buffer marker list, documented scaling bottleneck quote) —
  https://raw.githubusercontent.com/emacs-mirror/emacs/master/src/marker.c
- Ropey crate docs (segmented UTF-8 chunk storage, char-index API, sub-100ns chunk fetch) —
  https://docs.rs/ropey/latest/ropey/
- xi-editor "Rope science" series table of contents (TOC only; deeper posts not fetched) —
  https://xi-editor.io/docs/rope_science_00.html
- Local measured data: `../spikes/RESULTS.md` (this machine, 2026-09-05, Swift 6.3.3, M4) —
  ARC cost of indirect-enum vs class-boxed-enum vs tagged-word+arena value representations;
  recursive-teardown stack overflow finding.
- Not successfully fetched in this run (noted for completeness): Emacs
  `elisp/Overlays.html` (HTTP 429 x2), Apple `Data.init(contentsOf:options:)` documentation
  (empty body returned).

