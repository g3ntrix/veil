import AppKit
import Combine
import Network
import SwiftUI

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let source: String
    let text: String
}

@MainActor
final class AppState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case dashboard, test, servers, share, logs, setup, settings, about, donate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dashboard: return "Dashboard"
            case .test: return "Connection Test"
            case .servers: return "Servers"
            case .share: return "Share to Phone"
            case .logs: return "Logs"
            case .setup: return "Setup Wizard"
            case .settings: return "Settings"
            case .about: return "About"
            case .donate: return "Buy me a coffee"
            }
        }
        var symbol: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .test: return "checklist"
            case .servers: return "server.rack"
            case .share: return "iphone.radiowaves.left.and.right"
            case .logs: return "text.alignleft"
            case .setup: return "wand.and.stars"
            case .settings: return "slider.horizontal.3"
            case .about: return "info.circle"
            case .donate: return "cup.and.saucer"
            }
        }
    }

    @Published var tab: Tab = .dashboard
    @Published private(set) var profiles: [ServerProfile] = []
    @Published var prefs: AppPreferences { didSet { prefs.save() } }
    @Published var wizard: WizardProgress { didSet { wizard.save() } }
    @Published private(set) var logs: [LogLine] = []
    @Published var portConflict: TunnelError?
    @Published var banner: String?
    @Published private(set) var lanIP: String?
    @Published private(set) var lanIPChanged = false
    @Published private(set) var update: AppUpdateService.Release?
    @Published private(set) var egress: EgressInfo.Egress?
    @Published private(set) var systemProxyOn = false
    @Published var lastError: String?

    let engine = TunnelEngine()
    let tester = ConnectionTester()
    private var secretsCache: [UUID: ProfileSecrets] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature = ""
    private var cancellables: Set<AnyCancellable> = []
    private var wasConnectedBeforeSleep = false

    init() {
        prefs = AppPreferences.load()
        wizard = WizardProgress.load()
        profiles = ProfileStore.load()
        if profiles.isEmpty, prefs.wizardComplete { prefs.wizardComplete = false }
        RunRecord.killLeftovers()
        engine.onLog = { [weak self] src, line in self?.appendLog(src, line) }
        engine.onEvent = { [weak self] msg in self?.appendLog("veil", msg) }
        engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        tester.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        engine.$status.removeDuplicates().sink { [weak self] st in self?.statusChanged(st) }.store(in: &cancellables)
        lanIP = LanAddress.primaryIPv4()
        startPathMonitor()
        observeSleep()
        Notifier.requestPermission()
        if prefs.checkUpdates { Task { await checkForUpdate() } }
        if prefs.connectOnLaunch, prefs.wizardComplete { Task { await connect() } }
    }

    var isWizardComplete: Bool { prefs.wizardComplete }
    var status: TunnelStatus { engine.status }

    var activeProfile: ServerProfile? {
        profiles.first { $0.id == prefs.activeProfileID } ?? profiles.first
    }

    // MARK: Profiles

    func secrets(for p: ServerProfile) -> ProfileSecrets? {
        if let s = secretsCache[p.id] { return s }
        let s = try? Keychain.load(for: p.id)
        if let s { secretsCache[p.id] = s; Redactor.shared.register(s) }
        return s
    }

    @discardableResult
    func createProfile(name: String, address: String, sshUser: String) throws -> ServerProfile {
        let p = ServerProfile(name: name, address: address, sshUser: sshUser)
        let s = try SecretGenerator.newSecrets(sni: prefs.tunnel.sni)
        try Keychain.save(s, for: p.id)
        secretsCache[p.id] = s
        Redactor.shared.register(s)
        profiles.append(p)
        ProfileStore.save(profiles)
        if prefs.activeProfileID == nil { prefs.activeProfileID = p.id }
        return p
    }

    func update(_ p: ServerProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i] = p
        ProfileStore.save(profiles)
    }

    func duplicate(_ p: ServerProfile) throws {
        guard let s = secrets(for: p) else { throw TunnelError.noSecrets }
        var copy = p
        copy.id = UUID()
        copy.name += " copy"
        copy.created = Date()
        try Keychain.save(s, for: copy.id)
        secretsCache[copy.id] = s
        profiles.append(copy)
        ProfileStore.save(profiles)
    }

    func delete(_ p: ServerProfile) async {
        if engine.activeProfileID == p.id { await disconnect() }
        Keychain.delete(for: p.id)
        secretsCache[p.id] = nil
        profiles.removeAll { $0.id == p.id }
        ProfileStore.save(profiles)
        if prefs.activeProfileID == p.id { prefs.activeProfileID = profiles.first?.id }
        if profiles.isEmpty {
            prefs.wizardComplete = false
            wizard = WizardProgress()
            tab = .dashboard
        } else if wizard.draftProfileID == p.id {
            wizard = WizardProgress()
        }
    }

    func rotateCredentials(_ p: ServerProfile) throws {
        let old = secrets(for: p)
        var s = try SecretGenerator.newSecrets(sni: prefs.tunnel.sni)
        if let old { s.lanPassword = old.lanPassword }
        try Keychain.save(s, for: p.id)
        secretsCache[p.id] = s
        Redactor.shared.register(s)
        var q = p
        q.installedVersion = nil
        update(q)
    }

    func rotateLanPassword() {
        guard let p = activeProfile, var s = secrets(for: p) else { return }
        s.lanPassword = SecretGenerator.password(length: 16)
        try? Keychain.save(s, for: p.id)
        secretsCache[p.id] = s
        Redactor.shared.register(s)
        if prefs.lanSharing, engine.status.isActive { Task { await reconnect() } }
    }

    func importProfile(_ data: Data) throws {
        let (p, s) = try ProfileTransfer.import(data)
        try Keychain.save(s, for: p.id)
        secretsCache[p.id] = s
        profiles.append(p)
        ProfileStore.save(profiles)
        if prefs.activeProfileID == nil { prefs.activeProfileID = p.id }
    }

    func installCommand(for p: ServerProfile) -> String {
        guard let s = secrets(for: p) else { return "# keys missing: rotate credentials first" }
        return (try? ServerScript.installCommand(profile: p, secrets: s)) ?? "# could not build the install command"
    }

    func selectProfile(_ p: ServerProfile) async {
        let wasActive = engine.status.isActive
        prefs.activeProfileID = p.id
        if wasActive { await reconnect() }
    }

    func recordServerState(_ p: ServerProfile, version: Int?, ok: Bool, note: String) {
        var q = profiles.first { $0.id == p.id } ?? p
        if let version { q.installedVersion = version }
        q.lastCheck = .init(date: Date(), ok: ok, note: note)
        update(q)
    }

    // MARK: Connection

    func connect() async {
        guard let p = activeProfile else { tab = .setup; return }
        guard let s = secrets(for: p) else { lastError = TunnelError.noSecrets.errorDescription; return }
        portConflict = nil
        lastError = nil
        let lan = prefs.lanSharing ? XrayConfigBuilder.LAN(user: prefs.tunnel.lanUser, password: s.lanPassword) : nil
        do {
            try await engine.start(profile: p, secrets: s, settings: prefs.tunnel, lan: lan)
            if prefs.systemProxy { applySystemProxy(true) }
            egress = nil
            Task { egress = await EgressInfo.details(socksPort: prefs.tunnel.socksPort) }
        } catch let e as TunnelError {
            if case .portBusy = e { portConflict = e } else { lastError = e.localizedDescription }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        if systemProxyOn { applySystemProxy(false) }
        await engine.stop()
        egress = nil
    }

    func reconnect() async {
        await engine.stop()
        await connect()
    }

    func toggleConnection() async {
        if engine.status.isActive { await disconnect() } else { await connect() }
    }

    func resolveConflictByStopping() async {
        if case .portBusy(_, let h?) = portConflict { Ports.stop(h) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await connect()
    }

    func resolveConflictByMoving() async {
        var t = prefs.tunnel
        var base = 20808
        while base < 60000 {
            let ports = [base, base + 1, base + 2, base + 3]
            if ports.allSatisfy({ Ports.tcpFree($0) }) && Ports.udpFree(base + 87) { break }
            base += 100
        }
        t.socksPort = base; t.socks2Port = base + 1; t.httpPort = base + 2; t.lanPort = base + 3; t.relayLocalPort = base + 87
        prefs.tunnel = t
        banner = "Veil now uses SOCKS \(base) and HTTP \(base + 2). Update apps that point at the old ports."
        await connect()
    }

    private func statusChanged(_ st: TunnelStatus) {
        if case .degraded(let why) = st { appendLog("veil", why) }
        if case .error(let why) = st { appendLog("veil", why) }
    }

    // MARK: System proxy

    func setSystemProxy(_ on: Bool) {
        prefs.systemProxy = on
        if engine.status.isActive || !on { applySystemProxy(on) }
    }

    private func applySystemProxy(_ on: Bool) {
        if on {
            do {
                try SystemProxy.enable(socks: prefs.tunnel.socksPort, http: prefs.tunnel.httpPort)
                systemProxyOn = true
            } catch {
                prefs.systemProxy = false
                lastError = error.localizedDescription
            }
        } else {
            SystemProxy.disable()
            systemProxyOn = false
        }
    }

    // MARK: LAN sharing

    func setLanSharing(_ on: Bool) async {
        prefs.lanSharing = on
        prefs.lastLanIP = LanAddress.primaryIPv4()
        lanIPChanged = false
        if engine.status.isActive { await reconnect() }
    }

    var shareLink: String? {
        guard let p = activeProfile, let s = secrets(for: p), let ip = lanIP else { return nil }
        let t = prefs.tunnel
        return prefs.lanLinkStyle == 0
            ? ShareLinks.v2rayN(host: ip, port: t.lanPort, user: t.lanUser, pass: s.lanPassword)
            : ShareLinks.socks5(host: ip, port: t.lanPort, user: t.lanUser, pass: s.lanPassword)
    }

    func acknowledgeLanIP() {
        prefs.lastLanIP = lanIP
        lanIPChanged = false
    }

    // MARK: Network changes, sleep and wake

    private func startPathMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let sig = path.availableInterfaces.map(\.name).joined(separator: ",") + "|\(path.status)"
            Task { @MainActor in self?.pathChanged(sig, satisfied: path.status == .satisfied) }
        }
        m.start(queue: .global(qos: .utility))
        pathMonitor = m
    }

    private func pathChanged(_ sig: String, satisfied: Bool) {
        guard sig != lastPathSignature else { return }
        let first = lastPathSignature.isEmpty
        lastPathSignature = sig
        let newIP = LanAddress.primaryIPv4()
        if newIP != lanIP {
            lanIP = newIP
            if prefs.lanSharing, let old = prefs.lastLanIP, let newIP, old != newIP {
                lanIPChanged = true
                Notifier.post("Phone sharing address changed", "Your Mac is now \(newIP). Update the phone's proxy (scan the new QR code).", id: "lan-ip")
            }
        }
        guard !first, satisfied, engine.status.isActive else { return }
        appendLog("veil", "Network changed; checking the tunnel.")
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await engine.networkChanged()
            if case .degraded = engine.status {
                Notifier.post("Veil cannot reach your server", "The network changed and the tunnel does not work yet. Open Veil and run the connection test.", id: "net")
            }
        }
    }

    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.wasConnectedBeforeSleep = self.engine.status.isActive
                if self.wasConnectedBeforeSleep { await self.disconnect() }
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wasConnectedBeforeSleep else { return }
                self.wasConnectedBeforeSleep = false
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.connect()
            }
        }
    }

    func shutdown() {
        if systemProxyOn { SystemProxy.disable() }
        engine.stopSync()
    }

    // MARK: Updates

    func checkForUpdate() async {
        guard let r = try? await AppUpdateService.latest() else { return }
        update = AppUpdateService.isNewer(r.version, than: AppUpdateService.currentVersion) ? r : nil
    }

    // MARK: Logs

    func appendLog(_ src: String, _ text: String) {
        let t = Redactor.shared.redact(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        logs.append(LogLine(source: src, text: t))
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    func clearLogs() { logs.removeAll() }

    func diagnostics() -> String {
        var lines: [String] = [
            "Veil \(AppUpdateService.currentVersion), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Status: \(engine.status.label)",
            "Profile: \(activeProfile?.name ?? "none"), server port \(activeProfile?.relayPort ?? 0), server scripts v\(activeProfile?.installedVersion.map(String.init) ?? "?")",
            "Ports: SOCKS \(prefs.tunnel.socksPort)/\(prefs.tunnel.socks2Port) HTTP \(prefs.tunnel.httpPort) LAN \(prefs.lanSharing ? String(prefs.tunnel.lanPort) : "off")",
            "Restarts: \(engine.restarts)",
            "System proxy: \(systemProxyOn ? "on" : "off")",
            "", "Last test:", tester.report(profileName: activeProfile?.name ?? "-"), "", "Recent log:",
        ]
        lines += logs.suffix(150).map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.source)] \($0.text)" }
        return Redactor.shared.redactForReport(lines.joined(separator: "\n"))
    }

    // MARK: Wizard

    func finishWizard() {
        prefs.wizardComplete = true
        WizardProgress.clear()
        wizard = WizardProgress()
        tab = .dashboard
    }
}

func formatBytes(_ b: Double) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .binary
    f.allowsNonnumericFormatting = false
    f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: Int64(max(0, b)))
}

func formatRate(_ bps: Double) -> String { formatBytes(bps) + "/s" }
