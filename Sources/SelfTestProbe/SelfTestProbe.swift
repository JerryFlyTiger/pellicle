/// SelfTestProbe: a one-function dynamic library with no dependencies. M0.2 will
/// `dlopen` it from inside the app bundle to prove the `disable-library-validation`
/// entitlement works. (PLAN.md 4.2 / M0.1 spec)
@_cdecl("pellicle_selftest_probe")
public func selfTestProbe() -> Int32 {
    42
}
