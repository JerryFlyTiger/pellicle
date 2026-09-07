import Foundation

// Mini tree-walking Elisp-shaped interpreter in "realistic" Swift (enum values with a
// final-class cons payload, symbols interned to Ints, dynamic-binding environment as a
// flat array). Runs Reticle's loop-sum benchmark shape:
//   (let ((acc 0) (i 0)) (while (< i n) (setq acc (+ acc i)) (setq i (1+ i))) acc)
// Reticle (Rust, release, tree-walker): loop-sum(20M) 9.59s; bytecode VM ~8x faster.

final class Cons {
    var car: V
    var cdr: V
    init(_ a: V, _ d: V) {
        car = a
        cdr = d
    }
}
enum V {
    case nilv, t
    case int(Int)
    case sym(Int)
    case cons(Cons)
}

let S_LT = 0
let S_PLUS = 1
let S_1PLUS = 2
let S_SETQ = 3
let S_WHILE = 4
let S_LET = 5
let S_PROGN = 6
let S_ACC = 10
let S_I = 11
let S_N = 12

final class Interp {
    var values = [V](repeating: .nilv, count: 64)  // symbol id -> value (dynamic binding)
    var stepBudget = 0

    @inline(__always) func list(_ v: V) -> [V] {
        var out = [V]()
        var p = v
        while case .cons(let c) = p {
            out.append(c.car)
            p = c.cdr
        }
        return out
    }

    func eval(_ x: V) -> V {
        switch x {
        case .int, .nilv, .t: return x
        case .sym(let s): return values[s]
        case .cons(let c):
            guard case .sym(let head) = c.car else { fatalError("bad head") }
            switch head {
            case S_SETQ:
                guard case .cons(let a1) = c.cdr, case .sym(let s) = a1.car,
                    case .cons(let a2) = a1.cdr
                else { fatalError() }
                let v = eval(a2.car)
                values[s] = v
                return v
            case S_WHILE:
                guard case .cons(let a1) = c.cdr else { fatalError() }
                let test = a1.car
                let body = a1.cdr
                while true {
                    if case .nilv = eval(test) { break }
                    var p = body
                    while case .cons(let b) = p {
                        _ = eval(b.car)
                        p = b.cdr
                    }
                    stepBudget &+= 1
                    if stepBudget & 63 == 0 { /* deadline check slot */  }
                }
                return .nilv
            case S_PROGN:
                var r = V.nilv
                var p = c.cdr
                while case .cons(let b) = p {
                    r = eval(b.car)
                    p = b.cdr
                }
                return r
            case S_LET:
                guard case .cons(let a1) = c.cdr else { fatalError() }
                var saved = [(Int, V)]()
                var p = a1.car
                while case .cons(let b) = p {
                    guard case .cons(let binding) = b.car, case .sym(let s) = binding.car,
                        case .cons(let init0) = binding.cdr
                    else { fatalError() }
                    let v = eval(init0.car)
                    saved.append((s, values[s]))
                    values[s] = v
                    p = b.cdr
                }
                var r = V.nilv
                p = a1.cdr
                while case .cons(let b) = p {
                    r = eval(b.car)
                    p = b.cdr
                }
                for (s, v) in saved.reversed() { values[s] = v }
                return r
            case S_LT:
                guard case .cons(let a1) = c.cdr, case .cons(let a2) = a1.cdr else { fatalError() }
                guard case .int(let a) = eval(a1.car), case .int(let b) = eval(a2.car) else {
                    fatalError()
                }
                return a < b ? .t : .nilv
            case S_PLUS:
                guard case .cons(let a1) = c.cdr, case .cons(let a2) = a1.cdr else { fatalError() }
                guard case .int(let a) = eval(a1.car), case .int(let b) = eval(a2.car) else {
                    fatalError()
                }
                return .int(a &+ b)
            case S_1PLUS:
                guard case .cons(let a1) = c.cdr, case .int(let a) = eval(a1.car) else {
                    fatalError()
                }
                return .int(a &+ 1)
            default: fatalError("unknown function")
            }
        }
    }
}

func L(_ xs: V...) -> V {
    var r = V.nilv
    for x in xs.reversed() { r = .cons(Cons(x, r)) }
    return r
}
let sy = { (i: Int) -> V in .sym(i) }
// (let ((acc 0) (i 0)) (while (< i n) (setq acc (+ acc i)) (setq i (1+ i))) acc)
let form = L(
    sy(S_LET), L(L(sy(S_ACC), .int(0)), L(sy(S_I), .int(0))),
    L(
        sy(S_WHILE), L(sy(S_LT), sy(S_I), sy(S_N)),
        L(sy(S_SETQ), sy(S_ACC), L(sy(S_PLUS), sy(S_ACC), sy(S_I))),
        L(sy(S_SETQ), sy(S_I), L(sy(S_1PLUS), sy(S_I)))),
    sy(S_ACC))
let n = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1])! : 20_000_000
let interp = Interp()
interp.values[S_N] = .int(n)
for run in 0..<3 {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r = interp.eval(form)
    let dt = CFAbsoluteTimeGetCurrent() - t0
    if case .int(let v) = r {
        print(
            String(
                format: "loop-sum(%ld) run %d: %.3fs  result %ld  (%.1f ns/iter)", n, run, dt, v,
                dt * 1e9 / Double(n)))
    }
}
