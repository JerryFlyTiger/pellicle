import CPlatform
import Testing

@Suite("icache shim")
struct IcacheShimTests {
    @Test("pellicle_icache_invalidate links and is callable from Swift")
    func callable() {
        let count = 64
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 8)
        defer { buffer.deallocate() }
        pellicle_icache_invalidate(buffer, count)
        // The C shim is void; reaching this line without trapping is the test.
        #expect(Bool(true))
    }
}
