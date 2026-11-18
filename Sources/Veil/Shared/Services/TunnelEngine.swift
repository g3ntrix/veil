import Foundation

enum TunnelStatus: Equatable {
    case stopped
    case starting(String)
    case running
    case degraded(String)
    case stopping
    case error(String)

    var isActive: Bool {
        switch self { case .starting, .running, .degraded: return true; default: return false }
    }
    var label: String {
        switch self {
        case .stopped: return "Not connected"
        case .starting: return "Connecting"
        case .running: return "Connected"
        case .degraded: return "Connected, not working"
        case .stopping: return "Disconnecting"
        case .error: return "Error"
        }
    }
}

enum TunnelError: LocalizedError, Equatable {
    case portBusy(port: Int, holder: Ports.Holder?)
    case missingBinary(String)
    case relayFailed(String)
    case xrayFailed(String)
    case noSecrets

    var errorDescription: String? {
        switch self {
        case .portBusy(let port, let h):
            if let h { return "Port \(port) is already in use by \(h.display)." }
            return "Port \(port) is already in use by another program."
        case .missingBinary(let n): return "\(n) is missing from the app. Reinstall Veil."
        case .relayFailed(let m): return "Veil's engine did not start: \(m)"
        case .xrayFailed(let m): return "The proxy core did not start: \(m)"
        case .noSecrets: return "This server's keys are missing from the Keychain. Rotate credentials and reinstall the server."
        }
    }
}

@MainActor
final class TunnelEngine: ObservableObject {
    @Published private(set) var status: TunnelStatus = .stopped
    @Published private(set) var exitIP: String?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var upBps: Double = 0
    @Published private(set) var downBps: Double = 0
    @Published private(set) var upTotal: UInt64 = 0
    @Published private(set) var downTotal: UInt64 = 0
    @Published private(set) var rotations: UInt64 = 0
    @Published private(set) var restarts = 0

    var onLog: ((String, String) -> Void)?
    var onEvent: ((String) -> Void)?

    private let relay = ManagedProcess(name: "relayd")
    private let xray = ManagedProcess(name: "xray")
    private let guardProc = ManagedProcess(name: "guard")
    private var configURL: URL?
    private var current: (profile: ServerProfile, secrets: ProfileSecrets, settings: TunnelSettings, lan: XrayConfigBuilder.LAN?)?
    private var serverIPs: [String] = []
    private var lastStats: (up: UInt64, down: UInt64, at: Date)?
    private var recheckTask: Task<Void, Never>?
    private var backoff: TimeInterval = 1
    private var userStopped = true

    var relayRunning: Bool { relay.isRunning }
    var xrayRunning: Bool { xray.isRunning }
    var activeProfileID: UUID? { current?.profile.id }
    var settings: TunnelSettings? { current?.settings }
    var expectedIPs: [String] { serverIPs }

    init() {
        relay.onLine = { [weak self] l in self?.handleRelayLine(l) }
        xray.onLine = { [weak self] l in self?.onLog?("core", Redactor.shared.redact(l)) }
        relay.onExit = { [weak self] st, req in self?.childExited("engine", st, req) }
        xray.onExit = { [weak self] st, req in self?.childExited("core", st, req) }
    }

    static func preflight(_ s: TunnelSettings, lan: Bool) -> TunnelError? {
        for p in [s.socksPort, s.socks2Port, s.httpPort] where !Ports.tcpFree(p) {
            return .portBusy(port: p, holder: Ports.tcpHolder(p))
        }
        if lan, !Ports.tcpFree(s.lanPort, host: "0.0.0.0") { return .portBusy(port: s.lanPort, holder: Ports.tcpHolder(s.lanPort)) }
        if !Ports.udpFree(s.relayLocalPort) { return .portBusy(port: s.relayLocalPort, holder: Ports.udpHolder(s.relayLocalPort)) }
        return nil
    }

    func start(profile: ServerProfile, secrets: ProfileSecrets, settings: TunnelSettings, lan: XrayConfigBuilder.LAN?) async throws {
        await stop()
        userStopped = false
        Redactor.shared.register(secrets)
        current = (profile, secrets, settings, lan)
        status = .starting("Checking ports")
        if let e = Self.preflight(settings, lan: lan != nil) { status = .stopped; userStopped = true; throw e }
        do {
            try await launchAll()
        } catch {
            await stopProcesses()
            status = .error(error.localizedDescription)
            userStopped = true
            throw error
        }
        backoff = 1
        await verifyEgress(initial: true)
    }

    private func launchAll() async throws {
        guard let c = current else { return }
        guard let relaydURL = Binaries.url("relayd") else { throw TunnelError.missingBinary("relayd") }
        guard let xrayURL = Binaries.url("xray") else { throw TunnelError.missingBinary("xray") }
        serverIPs = EgressInfo.resolveIPv4(c.profile.address)

        status = .starting("Starting the engine")
        try relay.launch(relaydURL, [
            "run", "--server", c.profile.address, "--port", String(c.profile.relayPort),
            "--listen", "127.0.0.1:\(c.settings.relayLocalPort)", "--rotate", String(c.settings.rotateEvery),
            "--keep", "\(c.settings.keepOldSocketsSeconds)s", "--parent-pid", String(getpid()),
        ])
        if !(await waitUntil(3, { !Ports.udpFree(c.settings.relayLocalPort) })) {
            throw TunnelError.relayFailed(relay.isRunning ? "it did not open its port" : "it exited (check the server address)")
        }

        status = .starting("Starting the proxy")
        let data = try XrayConfigBuilder.json(secrets: c.secrets, settings: c.settings, lan: c.lan)
        if let old = configURL { try? FileManager.default.removeItem(at: old) }
        let url = try XrayConfigBuilder.writeTemp(data)
        configURL = url
        try xray.launch(xrayURL, ["run", "-c", url.path])
        if !(await waitUntil(10, { Ports.tcpListening(c.settings.socksPort) })) {
            throw TunnelError.xrayFailed(xray.isRunning ? "its proxy port did not open" : "it exited (see Logs)")
        }
        startGuard(relaydURL)
    }

    private func startGuard(_ relaydURL: URL) {
        let pids = [relay.pid, xray.pid].compactMap { $0 }
        RunRecord.save(pids)
        guardProc.stopSync()
        try? guardProc.launch(relaydURL, ["guard", "--parent-pid", String(getpid())] + pids.map(String.init))
    }

    func verifyEgress(initial: Bool = false) async {
        guard let c = current, !userStopped else { return }
        if initial { status = .starting("Checking the exit IP") }
        for attempt in 1...4 {
            if userStopped { return }
            if let ip = await EgressInfo.exitIP(socksPort: c.settings.socksPort) {
                exitIP = ip
                if serverIPs.isEmpty || serverIPs.contains(ip) {
                    if status != .running { connectedSince = connectedSince ?? Date() }
                    status = .running
                    scheduleRecheck(every: 60)
                    return
                }
                status = .degraded("Traffic leaves from \(ip), not from your server. Something else on this Mac is proxying.")
                scheduleRecheck(every: 15)
                return
            }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        exitIP = nil
        status = .degraded("The tunnel is up on this Mac but nothing gets through. Run the connection test to see where it stops.")
        scheduleRecheck(every: 15)
    }

    private func scheduleRecheck(every seconds: UInt64) {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.verifyEgress()
        }
    }

    func networkChanged() async {
        guard !userStopped, current != nil else { return }
        await verifyEgress()
        if case .degraded = status {
            onEvent?("Network changed and the tunnel stopped working; restarting it.")
            await restartAll()
        }
    }

    func restartAll() async {
        guard current != nil, !userStopped else { return }
        await stopProcesses()
        do {
            try await launchAll()
            await verifyEgress(initial: true)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stop() async {
        userStopped = true
        recheckTask?.cancel()
        guard current != nil || relay.isRunning || xray.isRunning else { status = .stopped; return }
        status = .stopping
        await stopProcesses()
        current = nil
        exitIP = nil
        connectedSince = nil
        upBps = 0; downBps = 0
        status = .stopped
    }

    func stopSync() {
        userStopped = true
        xray.stopSync()
        relay.stopSync()
        guardProc.stopSync()
        if let u = configURL { try? FileManager.default.removeItem(at: u) }
        RunRecord.clear()
    }

    private func stopProcesses() async {
        await xray.stop()
        await relay.stop()
        await guardProc.stop()
        if let u = configURL { try? FileManager.default.removeItem(at: u); configURL = nil }
        RunRecord.clear()
        lastStats = nil
    }

    // MARK: Supervision

    private func childExited(_ name: String, _ status: Int32, _ requested: Bool) {
        onLog?(name, "[exited with status \(status)]")
        guard !requested, !userStopped, current != nil else { return }
        restarts += 1
        let delay = backoff
        backoff = min(backoff * 2, 30)
        self.status = .starting("\(name) stopped; restarting in \(Int(delay)) s")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.restartAll()
        }
    }

    private func handleRelayLine(_ line: String) {
        guard line.hasPrefix("STATS ") else { onLog?("engine", line); return }
        var kv: [String: UInt64] = [:]
        for part in line.dropFirst(6).split(separator: " ") {
            let p = part.split(separator: "=")
            if p.count == 2, let v = UInt64(p[1]) { kv[String(p[0])] = v }
        }
        let up = kv["up"] ?? 0, down = kv["down"] ?? 0
        let now = Date()
        if let last = lastStats {
            let dt = max(now.timeIntervalSince(last.at), 0.1)
            upBps = Double(up &- last.up) / dt
            downBps = Double(down &- last.down) / dt
        }
        lastStats = (up, down, now)
        upTotal = up
        downTotal = down
        rotations = kv["n"] ?? rotations
    }

    private func waitUntil(_ seconds: TimeInterval, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return cond()
    }
}
