// Compile-only probe of Swift 6.3 / macOS 26 SDK features the plan may rely on.
import AppKit
import Metal
import MetalKit
import CoreText
import QuartzCore
import ExtensionKit
import ExtensionFoundation
import FoundationModels
import Observation
import os

// Swift 6.x stdlib additions
let arr: InlineArray<4, Int> = [1, 2, 3, 4]
let sp: Span<Int> = arr.span
_ = sp.count
struct NC: ~Copyable { var p: UnsafeMutableRawPointer? }
let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 16)
let rs: RawSpan = UnsafeRawBufferPointer(buf).bytes
_ = rs.byteCount

// CADisplayLink on NSView (macOS 14+)
final class V: NSView { func mk() -> CADisplayLink { displayLink(target: self, selector: #selector(tick)) }; @objc func tick() {} }

// Metal 4 (macOS 26) types
func m4(_ d: MTLDevice) { let q: MTL4CommandQueue? = d.makeMTL4CommandQueue(); _ = q }
// CAMetalLayer presentsWithTransaction
let layer = CAMetalLayer(); layer.presentsWithTransaction = true
// TextKit 2
let lm = NSTextLayoutManager(); _ = lm
// FoundationModels availability
@available(macOS 26, *) func fm() { let m = SystemLanguageModel.default; _ = m.availability }
// Glass effect in AppKit (macOS 26)
@available(macOS 26, *) func glass() { let g = NSGlassEffectView(); _ = g }
print("ok")
