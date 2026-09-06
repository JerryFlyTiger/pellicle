/// Lisp: reader, printer, values, heap+GC, evaluator, bytecode compiler, VM, regex
/// engine, the builtin registry, the Swift<->Elisp boundary. Depends on: Platform, Text
/// (PLAN.md 4.2: the regex engine scans the rope's chunks without copying, so Lisp must
/// be able to name rope and chunk *types*). It sees those types only — buffer, window
/// and command-loop objects stay in Editor.
package enum LispModule {
    package static let moduleName = "Lisp"
}
