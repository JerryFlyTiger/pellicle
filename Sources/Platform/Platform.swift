/// Platform: C shims (sys_icache_invalidate, MAP_JIT helpers, PTY ioctls), FSEvents,
/// process spawning with DispatchIO, energy/latency telemetry. Depends on: CPlatform.
/// (PLAN.md 4.2)
package enum PlatformModule {
    package static let moduleName = "Platform"
}
