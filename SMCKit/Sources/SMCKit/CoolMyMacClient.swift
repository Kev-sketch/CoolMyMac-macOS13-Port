// XPCClient.swift
// XPC connection wrapper for communicating with the CoolMyMac daemon.

import Foundation

/// Wraps an NSXPCConnection to the CoolMyMac daemon.
/// All calls are async wrappers around the `withReply:` XPC protocol.
// NSXPCConnection is not Sendable in Swift 6; we manage thread-safety via its internal serial queue.
public final class CoolMyMacClient: @unchecked Sendable {

    private var _connection: NSXPCConnection?
    private let lock = NSLock()

    // Every in-flight call registers a resumer here, keyed by a per-call token.
    // If the underlying NSXPCConnection is invalidated/interrupted, we resume
    // ALL stranded continuations with an error instead of leaking them forever.
    // This is required because NSXPCConnection does NOT invoke the error block
    // passed to remoteObjectProxyWithErrorHandler on invalidation: without this
    // registry, a dead helper (mach service absent) hangs every awaited call —
    // including isDaemonReachable()/daemonVersion() (so AppState.refresh() never
    // reaches its direct-SMC fallback) and the CLI's temps/fans reads.
    private var pending: [UUID: (Error) -> Void] = [:]

    // Bound every awaited call. A mach service can be registered by launchd yet have
    // no live helper (a stale reservation left by a prior install, or a helper that
    // never gets spawned): the NSXPCConnection then stays OPEN, never delivers a
    // reply, and never invalidates/interrupts — so the invalidation resume below
    // never fires and the call would hang forever (the reported bug). The timer fails
    // it fast instead. Tiers:
    //   * reachabilityTimeout — gates isDaemonReachable()/AppState.refresh(); must be
    //     shorter than the app's ~1s refresh cadence so refresh() reaches its direct-SMC
    //     fallback before the loop cancels its task. Healthy daemons answer in <100ms.
    //   * readTimeout — the fast subset reads used by the CLI (temps/fans/active-group);
    //     keeps the CLI snappy when the daemon is unreachable.
    //   * requestTimeout — the full sensor sweep and all writes/config round-trips.
    private let reachabilityTimeout: TimeInterval = 0.7
    private let readTimeout: TimeInterval = 1.0
    private let requestTimeout: TimeInterval = 5.0
    private let timeoutQueue = DispatchQueue(label: "com.coolmymac.SMCKit.client.timeout", qos: .utility)

    private var connection: NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }

        if let conn = _connection {
            return conn
        }

        let newConn = NSXPCConnection(machServiceName: CoolMyMacXPCServiceName, options: [])
        newConn.remoteObjectInterface = NSXPCInterface(with: CoolMyMacXPCProtocol.self)

        // If launchd kills the daemon or it crashes, safely nil out the reference
        // so the next XPC call automatically spawns a fresh connection pipeline.
        // On BOTH interruption and invalidation we also resume every stranded
        // continuation with a descriptive error so callers fail fast (and reach
        // their direct-SMC fallback) instead of blocking forever.
        newConn.interruptionHandler = { [weak self] in
            self?.connectionLost()
        }
        newConn.invalidationHandler = { [weak self] in
            self?.connectionLost()
        }

        newConn.resume()
        _connection = newConn
        return newConn
    }

    public init() {}

    deinit {
        _connection?.invalidate()
    }

    public func disconnect() {
        let conn: NSXPCConnection?
        lock.lock()
        conn = _connection
        _connection = nil
        lock.unlock()
        // Invalidate OUTSIDE the lock. The invalidation handler runs asynchronously
        // on NSXPCConnection's internal queue and re-enters this lock via
        // connectionLost(); holding our lock across invalidate() would risk a
        // deadlock if the handler were ever delivered synchronously.
        conn?.invalidate()
    }

    /// Called from the connection's interruption/invalidation handlers.
    /// Discards the dead connection (so the next call builds a fresh one) and
    /// resumes every pending continuation with an error so none is left hanging.
    private func connectionLost() {
        clearConnection()
        failAllPending(invalidationError)
    }

    private func clearConnection() {
        lock.lock()
        defer { lock.unlock() }
        _connection = nil
    }

    /// Descriptive error used to resume stranded continuations: the helper tool is
    /// either not running or dropped the connection mid-call. Either way the caller
    /// must observe an error (not a hang) so it can fall back to direct SMC access.
    private var invalidationError: Error {
        NSError(domain: CoolMyMacXPCServiceName, code: -1, userInfo: [
            NSLocalizedDescriptionKey:
                "Helper tool connection invalidated. The CoolMyMac daemon may not be running."
        ])
    }

    // MARK: - Pending-continuation registry (all access under `lock`)

    private func registerPending(_ id: UUID, _ resumer: @escaping (Error) -> Void) {
        lock.lock(); pending[id] = resumer; lock.unlock()
    }

    private func unregisterPending(_ id: UUID) {
        lock.lock(); pending.removeValue(forKey: id); lock.unlock()
    }

    /// Resumes every pending continuation with `error` and clears the registry.
    /// The resumers are invoked OUTSIDE `lock` (they call back into Swift
    /// concurrency via continuation.resume).
    private func failAllPending(_ error: Error) {
        lock.lock()
        let inflight = pending
        pending.removeAll()
        lock.unlock()
        for resumer in inflight.values { resumer(error) }
    }

    /// Wraps a continuation so that every completion path — the XPC reply, the
    /// remoteObjectProxyWithErrorHandler error block, a nil-proxy short-circuit,
    /// and connection invalidation — funnels through a single idempotent `finish`
    /// closure that resumes the continuation exactly once. The continuation is
    /// registered in the pending registry for the lifetime of the call and removed
    /// the moment it settles (so nothing leaks while the connection stays healthy).
    private func makeResume<T>(
        _ cont: CheckedContinuation<T, Error>,
        timeout: TimeInterval
    ) -> (Swift.Result<T, Error>) -> Void {
        let id = UUID()
        let once = ResumeOnce()
        var timer: DispatchWorkItem?

        let finish: (Swift.Result<T, Error>) -> Void = { [weak self] result in
            guard once.claim() else { return }
            timer?.cancel()
            self?.unregisterPending(id)
            switch result {
            case .success(let value): cont.resume(returning: value)
            case .failure(let error): cont.resume(throwing: error)
            }
        }
        // If the connection dies before this call completes, fail it fast.
        registerPending(id) { error in finish(.failure(error)) }

        // Backstop for an OPEN-but-silent connection (registered service, no live
        // helper): never replies and never invalidates. Fail after `timeout` so the
        // caller (e.g. the CLI) returns quickly and the app reaches its fallback.
        let item = DispatchWorkItem { finish(.failure(XPCError.timedOut)) }
        timer = item
        timeoutQueue.asyncAfter(deadline: .now() + timeout, execute: item)

        return finish
    }

    // MARK: - Private helper

    private func getProxy(errorHandler: @escaping (Error) -> Void) -> (any CoolMyMacXPCProtocol)? {
        connection.remoteObjectProxyWithErrorHandler { error in
            errorHandler(error)
        } as? any CoolMyMacXPCProtocol
    }

    // MARK: - Generic helper

    private func xpcCall<T: Decodable & Sendable>(
        timeout: TimeInterval,
        _ call: @escaping (any CoolMyMacXPCProtocol, @escaping (Data?, Error?) -> Void) -> Void
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let finish = makeResume(cont, timeout: timeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                // Could not build the remote proxy — resume instead of silently returning.
                finish(.failure(XPCError.connectionFailed))
                return
            }

            call(proxy) { data, error in
                if let error { finish(.failure(error)); return }
                guard let data else { finish(.failure(XPCError.noData)); return }
                do { finish(.success(try JSONDecoder().decode(T.self, from: data))) }
                catch let decodeError { finish(.failure(decodeError)) }
            }
        }
    }

    // MARK: - Public API (mirrors SMCController interface for drop-in fallback)

    public func readSensors() async throws -> [SensorReading] {
        try await xpcCall(timeout: readTimeout) { proxy, reply in proxy.readSensors(withReply: reply) }
    }

    public func readAllSensors() async throws -> [SensorReading] {
        try await xpcCall(timeout: requestTimeout) { proxy, reply in proxy.readAllSensors(withReply: reply) }
    }

    public func readFans() async throws -> [FanStatus] {
        try await xpcCall(timeout: readTimeout) { proxy, reply in proxy.readFans(withReply: reply) }
    }

    public func activeProfile() async throws -> FanProfile {
        try await xpcCall(timeout: requestTimeout) { proxy, reply in proxy.activeProfile(withReply: reply) }
    }

    public func listProfiles() async throws -> [String] {
        try await xpcCall(timeout: requestTimeout) { proxy, reply in proxy.listProfiles(withReply: reply) }
    }

    // MARK: - Version

    public func getDaemonVersion() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let finish = makeResume(cont, timeout: reachabilityTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.getDaemonVersion { version in
                finish(.success(version))
            }
        }
    }

    public func getCustomProfiles() async throws -> [FanProfile] {
        try await xpcCall(timeout: requestTimeout) { proxy, reply in proxy.getCustomProfiles(withReply: reply) }
    }

    public func setActiveProfile(_ name: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.setActiveProfile(name) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func saveCustomProfile(_ profile: FanProfile) async throws {
        let data = try JSONEncoder().encode(profile)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.saveCustomProfile(data) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func deleteCustomProfile(id: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.deleteCustomProfile(id) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func isDaemonReachable() async -> Bool {
        (try? await daemonVersion()) != nil
    }

    public func setUpdateInterval(_ interval: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.setUpdateInterval(interval) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func getUpdateInterval() async throws -> Double {
        try await withCheckedThrowingContinuation { cont in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.getUpdateInterval { interval, error in
                if let error { finish(.failure(error)) } else { finish(.success(interval)) }
            }
        }
    }

    public func setActiveSensors(_ groups: [SensorGroup], excludedSensors: [String]) async throws {
        let strings = groups.map(\.rawValue)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.setActiveSensors(strings, excludedSensors: excludedSensors) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func getActiveSensors() async throws -> (groups: [SensorGroup], excludedSensors: [String]) {
        let result: ([String], [String]) = try await withCheckedThrowingContinuation { cont in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.getActiveSensors { groups, excluded, error in
                if let error { finish(.failure(error)) } else { finish(.success((groups, excluded))) }
            }
        }
        return (result.0.compactMap(SensorGroup.init(rawValue:)), result.1)
    }

    public func daemonVersion() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let finish = makeResume(cont, timeout: reachabilityTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.daemonVersion { version in
                finish(.success(version))
            }
        }
    }

    public func getAllowUnprivilegedCLI() async throws -> Bool {
        try await withCheckedThrowingContinuation { cont in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.getAllowUnprivilegedCLI { allow, error in
                if let error { finish(.failure(error)) } else { finish(.success(allow)) }
            }
        }
    }

    public func setAllowUnprivilegedCLI(_ allow: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.setAllowUnprivilegedCLI(allow) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func installCLI() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.installCLI { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func uninstallCLI() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.uninstallCLI { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func setThermalFailsafeSpeeds(heavy: Double, critical: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.setThermalFailsafeSpeeds(heavy: heavy, critical: critical) { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }

    public func getThermalFailsafeSpeeds() async throws -> (heavy: Double, critical: Double) {
        try await withCheckedThrowingContinuation { cont in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.getThermalFailsafeSpeeds { heavy, critical, error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success((heavy: heavy, critical: critical)))
                }
            }
        }
    }

    /// Asks the daemon to restart itself via `launchctl kickstart -k`.
    /// The daemon replies before issuing the kickstart, so this call succeeds even though
    /// the XPC connection will drop shortly after. Callers should ignore the subsequent
    /// disconnection error and call disconnect() to clean up the stale connection.
    public func restartDaemon() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let finish = makeResume(cont, timeout: requestTimeout)
            guard let proxy = getProxy(errorHandler: { finish(.failure($0)) }) else {
                finish(.failure(XPCError.connectionFailed))
                return
            }

            proxy.restartDaemon { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            }
        }
    }
}

// MARK: - ResumeOnce

/// A tiny thread-safe once-flag so a continuation is resumed at most once even
/// though its completion paths run on different queues (XPC reply queue,
/// remoteObjectProxyWithErrorHandler error queue, and the invalidation queue).
private final class ResumeOnce {
    private let lock = NSLock()
    private var done = false

    /// Returns true the first time only; false on every subsequent call.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

// MARK: - XPC Errors

public enum XPCError: Error, LocalizedError {
    case connectionFailed
    case noData
    case daemonNotRunning
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:  return "Failed to connect to CoolMyMac daemon."
        case .noData:            return "Daemon returned no data."
        case .daemonNotRunning:  return "Daemon not running."
        case .timedOut:          return "No response from the CoolMyMac daemon in time."
        }
    }
}
