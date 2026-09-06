/// The cross-module caller `dev/check-inlining.sh` disassembles. See the probe files in
/// `Sources/Text` and `Sources/Lisp` for what the two shapes are, and PLAN.md 4.2 for the
/// convention they encode.
///
/// `editorHotProbe` must compile to code containing no reference to the Text/Lisp hot
/// symbols; `editorColdProbe` must still call the Text/Lisp cold symbols.
import Lisp
import Text

public func editorHotProbe(_ n: UInt64) -> UInt64 {
    let text = TextHotProbe()
    let lisp = LispHotProbe()
    var acc: UInt64 = 0
    var i: UInt64 = 0
    while i < n {
        acc = acc &+ text.packedByteLength(i) &+ lisp.packedByteLength(i)
        i &+= 1
    }
    return acc
}

package func editorColdProbe(_ n: UInt64) -> UInt64 {
    let text = TextColdProbe()
    let lisp = LispColdProbe()
    var acc: UInt64 = 0
    var i: UInt64 = 0
    while i < n {
        acc = acc &+ text.packedByteLength(i) &+ lisp.packedByteLength(i)
        i &+= 1
    }
    return acc
}
