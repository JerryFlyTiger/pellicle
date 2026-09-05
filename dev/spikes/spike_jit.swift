import Darwin

@_silgen_name("sys_icache_invalidate") func sys_icache_invalidate(_ start: UnsafeMutableRawPointer, _ len: Int)

// Feasibility spike: allocate MAP_JIT memory, write two ARM64 instructions
// (mov w0,#42 ; ret), flip to executable, invalidate icache, call it.
let size = 16384
guard let mem = mmap(nil, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0), mem != MAP_FAILED else {
    print("mmap MAP_JIT failed errno=\(errno)"); exit(1)
}
pthread_jit_write_protect_np(0)
let code: [UInt32] = [0x5280_0540, 0xD65F_03C0]
mem.withMemoryRebound(to: UInt32.self, capacity: code.count) { p in
    for (i, w) in code.enumerated() { p[i] = w }
}
pthread_jit_write_protect_np(1)
sys_icache_invalidate(mem, size)
typealias Fn = @convention(c) () -> Int32
let fn = unsafeBitCast(mem, to: Fn.self)
let r = fn()
print("jit call returned \(r) (expected 42)")
exit(r == 42 ? 0 : 2)
