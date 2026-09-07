import Foundation

// Micro-benchmark: three Lisp value representations in Swift 6.3 on this machine.
// argv[1] selects the rep (A/B/C); argv[2] == "naive" skips the iterative teardown
// so the recursive-release behaviour of ARC on a 1M-node list can be observed.
// Workload: build a 1,000,000-element list of ints, sum it 20 times (pointer chasing
// that stresses retain/release), plus a 20M-iteration arithmetic loop through the
// value type (stresses boxing/unboxing). Representation cost only, not an interpreter.

@inline(never) func now() -> Double { CFAbsoluteTimeGetCurrent() }
let N = 1_000_000
let SUMS = 20
let LOOP = 20_000_000

// --- Rep A: indirect enum (each cons is an ARC box) ---
indirect enum VA {
    case nilv
    case int(Int)
    case cons(VA, VA)
}
@inline(never) func benchA(naive: Bool) -> (Double, Int) {
    let t0 = now()
    var list = VA.nilv
    for i in 0..<N { list = .cons(.int(i), list) }
    var total = 0
    for _ in 0..<SUMS {
        var p = list
        while case .cons(let car, let cdr) = p {
            if case .int(let n) = car { total &+= n }
            p = cdr
        }
    }
    var acc = VA.int(0)
    for i in 0..<LOOP { if case .int(let a) = acc { acc = .int(a &+ (i & 7)) } }
    if case .int(let a) = acc { total &+= a }
    let t1 = now() - t0
    if !naive { while case .cons(_, let cdr) = list { list = cdr } }  // iterative teardown
    return (t1, total)
}

// --- Rep B: enum with final-class cons payload (ARC) ---
final class ConsB {
    var car: VB
    var cdr: VB
    init(_ a: VB, _ d: VB) {
        car = a
        cdr = d
    }
}
enum VB {
    case nilv
    case int(Int)
    case cons(ConsB)
}
@inline(never) func benchB(naive: Bool) -> (Double, Int) {
    let t0 = now()
    var list = VB.nilv
    for i in 0..<N { list = .cons(ConsB(.int(i), list)) }
    var total = 0
    for _ in 0..<SUMS {
        var p = list
        while case .cons(let c) = p {
            if case .int(let n) = c.car { total &+= n }
            p = c.cdr
        }
    }
    var acc = VB.int(0)
    for i in 0..<LOOP { if case .int(let a) = acc { acc = .int(a &+ (i & 7)) } }
    if case .int(let a) = acc { total &+= a }
    let t1 = now() - t0
    if !naive {
        while case .cons(let c) = list {
            list = c.cdr
            c.cdr = .nilv
        }
    }
    return (t1, total)
}

// --- Rep C: tagged 64-bit word + manual arena (no ARC; a GC would be separate) ---
struct VC {
    var raw: UInt64
    @inline(__always) static func int(_ n: Int) -> VC {
        VC(raw: UInt64(bitPattern: Int64(n) << 1) | 1)
    }
    @inline(__always) var isInt: Bool { raw & 1 == 1 }
    @inline(__always) var intValue: Int { Int(Int64(bitPattern: raw) >> 1) }
    static var nilv: VC { VC(raw: 0) }
}
struct CellC {
    var car: VC
    var cdr: VC
}
final class ArenaC {
    var cells: UnsafeMutablePointer<CellC>
    var count = 1
    init(cap: Int) { cells = .allocate(capacity: cap) }
    deinit { cells.deallocate() }
    @inline(__always) func cons(_ a: VC, _ d: VC) -> VC {
        let i = count
        count += 1
        cells[i] = CellC(car: a, cdr: d)
        return VC(raw: UInt64(i) << 1)
    }
    @inline(__always) func car(_ v: VC) -> VC { cells[Int(v.raw >> 1)].car }
    @inline(__always) func cdr(_ v: VC) -> VC { cells[Int(v.raw >> 1)].cdr }
}
@inline(never) func benchC() -> (Double, Int) {
    let t0 = now()
    let arena = ArenaC(cap: N + 10)
    var list = VC.nilv
    for i in 0..<N { list = arena.cons(.int(i), list) }
    var total = 0
    for _ in 0..<SUMS {
        var p = list
        while p.raw != 0 {
            let a = arena.car(p)
            if a.isInt { total &+= a.intValue }
            p = arena.cdr(p)
        }
    }
    var acc = VC.int(0)
    for i in 0..<LOOP { if acc.isInt { acc = .int(acc.intValue &+ (i & 7)) } }
    if acc.isInt { total &+= acc.intValue }
    return (now() - t0, total)
}

let rep = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "C"
let naive = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "naive"
for run in 0..<3 {
    let r: (Double, Int)
    switch rep {
    case "A": r = benchA(naive: naive)
    case "B": r = benchB(naive: naive)
    default: r = benchC()
    }
    print(
        String(
            format: "rep %@%@ run %d: %.3fs (checksum %d)", rep, naive ? "/naive" : "", run, r.0,
            r.1))
}
