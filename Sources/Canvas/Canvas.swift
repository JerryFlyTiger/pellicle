/// Canvas: the Metal text canvas: glyph atlas, shaping cache, layout, damage tracking,
/// display link, minimap, cursor/selection/decorations. Depends on: Editor, Text.
///
/// Canvas must never `import Lisp` directly; it reaches Elisp state only through the
/// `DisplaySnapshot` type owned by `Editor`.
///
/// The UI actor never touches a buffer.
/// (PLAN.md 4.2)
package enum CanvasModule {
    package static let moduleName = "Canvas"
}
