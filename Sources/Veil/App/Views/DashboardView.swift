import SwiftUI

struct PageHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @State private var downHistory: [Double] = Array(repeating: 0, count: 40)

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                topBar
                notices
                VeilOrb(status: app.status) { Task { await app.toggleConnection() } }
                    .disabled(app.status == .stopping || app.activeProfile == nil)
                    .keyboardShortcut("k", modifiers: .command)
                statusText
                if app.status.isActive { liveStrip.transition(.opacity.combined(with: .move(edge: .top))) }
                PathStrip()
                HStack(spacing: 12) {
                    PillToggle(title: "System proxy", icon: "network", isOn: app.prefs.systemProxy) { app.setSystemProxy(!app.prefs.systemProxy) }
                    PillToggle(title: "Share to phone", icon: "iphone", isOn: app.prefs.lanSharing) { Task { await app.setLanSharing(!app.prefs.lanSharing) } }
                }
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 32).padding(.vertical, 26)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: app.status.isActive)
        .onChange(of: app.engine.downBps) { v in downHistory = Array((downHistory + [v]).suffix(40)) }
    }

    // MARK: Top bar: server and exit chips

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(app.profiles) { p in
                    Button(p.name) { Task { await app.selectProfile(p) } }
                }
                Divider()
                Button("Manage servers…") { app.tab = .servers }
            } label: {
                chip(icon: "server.rack", text: app.activeProfile?.name ?? "No server")
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if let ip = app.egress?.ip ?? app.engine.exitIP {
                chip(icon: "globe", text: [ip, app.egress?.country].compactMap { $0 }.joined(separator: " · "))
                    .textSelection(.enabled)
            }
            CopyButton(text: "socks5h://127.0.0.1:\(String(app.prefs.tunnel.socksPort))", label: "SOCKS \(String(app.prefs.tunnel.socksPort))")
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help("Copy the proxy address. HTTP proxy: 127.0.0.1:\(String(app.prefs.tunnel.httpPort))")
        }
    }

    private func chip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if let u = app.update { notice("Veil \(u.version) is available.", "Download") { NSWorkspace.shared.open(u.dmg ?? u.page) } }
        if let b = app.banner { notice(b, "OK") { app.banner = nil } }
        if app.lanIPChanged, let ip = app.lanIP {
            notice("Your Mac's address changed to \(ip). Phones must use the new address.", "Show QR") { app.acknowledgeLanIP(); app.tab = .share }
        }
        if let p = app.activeProfile, let v = p.installedVersion, v < Versions.serverScripts {
            notice("Server update available for \(p.name).", "Show") { app.tab = .servers }
        }
        if let c = app.portConflict { PortConflictView(conflict: c) }
        if let e = app.lastError {
            Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.bad)
        }
    }

    private func notice(_ text: String, _ action: String, _ f: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12))
            Spacer()
            Button(action, action: f).buttonStyle(.borderless).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(Theme.accent.opacity(0.1)))
    }

    // MARK: Status

    private var statusText: some View {
        VStack(spacing: 6) {
            Text(app.status.label).font(.system(size: 30, weight: .bold, design: .rounded))
            Group {
                switch app.status {
                case .starting(let s): Text(s)
                case .degraded(let s), .error(let s): Text(s).multilineTextAlignment(.center)
                case .running:
                    if let since = app.engine.connectedSince {
                        TimelineView(.periodic(from: since, by: 1)) { ctx in Text("Up \(uptime(ctx.date.timeIntervalSince(since)))") }
                    }
                case .stopped: Text(app.activeProfile == nil ? "Add a server to begin" : "Click the veil or press ⌘K to connect")
                case .stopping: Text("Closing the connection")
                }
            }
            .font(.system(size: 13)).foregroundStyle(.secondary)
            .frame(maxWidth: 460)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Live strip

    private var liveStrip: some View {
        HStack(spacing: 0) {
            metric("Down", formatRate(app.engine.downBps), icon: "arrow.down", tint: Theme.accent) {
                Sparkline(values: downHistory).stroke(Theme.gradient, lineWidth: 1.5).frame(width: 64, height: 18)
            }
            divider
            metric("Up", formatRate(app.engine.upBps), icon: "arrow.up", tint: Theme.accent2) { EmptyView() }
            divider
            metric("Session", formatBytes(Double(app.engine.downTotal + app.engine.upTotal)), icon: "sum", tint: .secondary) { EmptyView() }
            divider
            metric("Latency", latencyText, icon: "timer", tint: .secondary) { EmptyView() }
        }
        .padding(.vertical, 12).padding(.horizontal, 6)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.08)))
        )
    }

    private var divider: some View { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1, height: 30) }

    private func metric<Extra: View>(_ label: String, _ value: String, icon: String, tint: Color, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(spacing: 3) {
            Label(label.uppercased(), systemImage: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
            HStack(spacing: 8) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                extra()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var latencyText: String {
        if let s = app.tester.stages.first(where: { $0.id == .latency }), s.outcome == .pass || s.outcome == .warn {
            return s.detail.components(separatedBy: " (").first?.replacingOccurrences(of: "Median ", with: "") ?? "–"
        }
        return "–"
    }

    private func uptime(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 60)m \(s % 60)s"
    }
}

struct VeilOrb: View {
    let status: TunnelStatus
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.colorScheme) var scheme
    @State private var hover = false
    @State private var start = Date()

    private enum Mode { case off, busy, on, warn }
    private var mode: Mode {
        switch status {
        case .stopped: return .off
        case .starting, .stopping: return .busy
        case .running: return .on
        case .degraded, .error: return .warn
        }
    }

    private let disc: CGFloat = 132

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(glowColor.opacity(mode == .off ? 0 : (scheme == .dark ? 0.28 : 0.18)))
                    .frame(width: 210, height: 210).blur(radius: 40)

                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 2).frame(width: 176, height: 176)

                TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion || mode == .off)) { ctx in
                    let t = ctx.date.timeIntervalSince(start)
                    ZStack {
                        if mode == .busy {
                            Circle().trim(from: 0, to: 0.22)
                                .stroke(Theme.gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 176, height: 176)
                                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
                        } else if mode == .on || mode == .warn {
                            let breath = (sin(t * 2 * .pi / 4) + 1) / 2
                            Circle().stroke(ringStyle, lineWidth: 2)
                                .frame(width: 176, height: 176)
                                .scaleEffect(1 + 0.06 * breath)
                                .opacity(0.35 + 0.4 * (1 - breath))
                            Circle().stroke(ringStyle, lineWidth: 2)
                                .frame(width: 176, height: 176)
                        }
                    }
                    .transaction { $0.animation = nil }
                }

                Circle()
                    .fill(discFill)
                    .frame(width: disc, height: disc)
                    .overlay(Circle().stroke(Color.white.opacity(mode == .off ? 0.08 : 0.22), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                Image(systemName: "power")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(mode == .off ? Color.secondary : Color.white)
            }
            .frame(width: 230, height: 230)
            .scaleEffect(hover ? 1.025 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.35), value: mode)
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
        .onChange(of: mode) { _ in start = Date() }
        .accessibilityLabel(status.isActive ? "Disconnect" : "Connect")
        .accessibilityValue(status.label)
    }

    private var glowColor: Color { mode == .warn ? Theme.warn : Theme.accent }

    private var ringStyle: AnyShapeStyle {
        mode == .warn ? AnyShapeStyle(Theme.warn) : AnyShapeStyle(Theme.gradient)
    }

    private var discFill: AnyShapeStyle {
        switch mode {
        case .off: return AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06))
        case .busy: return AnyShapeStyle(Theme.accent.opacity(0.55))
        case .on: return AnyShapeStyle(Theme.gradient)
        case .warn: return AnyShapeStyle(LinearGradient(colors: [Theme.warn, Theme.warn.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

struct Sparkline: Shape {
    let values: [Double]
    func path(in r: CGRect) -> Path {
        var p = Path()
        let m = max(values.max() ?? 1, 1)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: r.minX + r.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                             y: r.maxY - r.height * CGFloat(v / m))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

struct PillToggle: View {
    let title: String
    let icon: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title).font(.system(size: 13, weight: .medium))
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").opacity(0.9)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(Capsule().fill(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .overlay(Capsule().stroke(.primary.opacity(isOn ? 0 : 0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

struct PathStrip: View {
    @EnvironmentObject var app: AppState

    struct Node: Identifiable {
        let id: String
        let symbol: String
        var state: ConnectionTester.Outcome
        var note: String
    }

    var nodes: [Node] {
        let st = Dictionary(uniqueKeysWithValues: app.tester.stages.map { ($0.id, $0) })
        func o(_ k: ConnectionTester.Kind) -> ConnectionTester.Outcome { st[k]?.outcome ?? .pending }
        func fix(_ k: ConnectionTester.Kind) -> String { st[k]?.fix ?? st[k]?.detail ?? "" }
        let engine: ConnectionTester.Outcome = app.status.isActive ? (app.engine.relayRunning && app.engine.xrayRunning ? .pass : .fail) : .pending
        let path = o(.path)
        let internet: ConnectionTester.Outcome = app.status == .running ? .pass : (o(.egress) == .pending ? (app.status.isActive ? .warn : .pending) : o(.egress))
        return [
            Node(id: "This Mac", symbol: "laptopcomputer", state: engine, note: app.status.isActive ? "" : "Press Connect"),
            Node(id: "Network", symbol: "wifi", state: path, note: fix(.path)),
            Node(id: "Server", symbol: "server.rack", state: path == .fail ? .fail : (path == .pending ? .pending : .pass), note: fix(.path)),
            Node(id: "Tunnel", symbol: "lock.shield", state: o(.handshake), note: fix(.handshake)),
            Node(id: "Internet", symbol: "globe", state: internet, note: fix(.egress)),
        ]
    }

    var body: some View {
        let ns = nodes
        let problem = ns.first { $0.state == .fail || $0.state == .warn }
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(Array(ns.enumerated()), id: \.element.id) { i, n in
                    if i > 0 {
                        Capsule().fill(lineColor(ns[i - 1].state, n.state)).frame(height: 3).frame(maxWidth: .infinity)
                            .padding(.bottom, 20)
                    }
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(color(n.state).opacity(0.16)).frame(width: 40, height: 40)
                            if n.state == .running { ProgressView().controlSize(.small) }
                            else { Image(systemName: n.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(color(n.state)) }
                        }
                        Text(n.id).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(word(n.state))
                }
            }
            HStack(spacing: 10) {
                if let p = problem, !p.note.isEmpty {
                    Label(p.note, systemImage: "lightbulb").font(.system(size: 11)).foregroundStyle(Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let t = app.tester.finishedAt {
                    Text("Checked \(t.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Run a check to see every step to the internet.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(app.tester.running ? "Checking…" : "Check now") {
                    if let p = app.activeProfile { app.tester.run(engine: app.engine, profile: p, quick: true) }
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .disabled(app.tester.running || app.activeProfile == nil || !app.status.isActive)
                .keyboardShortcut("t", modifiers: .command)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func color(_ o: ConnectionTester.Outcome) -> Color {
        switch o { case .pass: return Theme.ok; case .warn: return Theme.warn; case .fail: return Theme.bad; case .running: return Theme.accent; default: return .secondary }
    }
    private func lineColor(_ a: ConnectionTester.Outcome, _ b: ConnectionTester.Outcome) -> Color {
        a == .pass && b == .pass ? Theme.ok.opacity(0.6) : Color.primary.opacity(0.1)
    }
    private func word(_ o: ConnectionTester.Outcome) -> String {
        switch o { case .pass: return "OK"; case .warn: return "Degraded"; case .fail: return "Down"; case .running: return "Checking"; default: return "Not checked" }
    }
}

// MARK: - Connection test page

struct TesterStagesView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(summaryColor).frame(width: 12, height: 12)
                Text(app.tester.summaryText).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            ForEach(app.tester.stages) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        icon(s.outcome).frame(width: 18)
                        Image(systemName: s.id.symbol).foregroundStyle(.secondary).frame(width: 18)
                        Text(s.title).font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let t = s.seconds { Text(String(format: "%.1f s", t)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                    if !s.detail.isEmpty { Text(s.detail).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 56) }
                    if let f = s.fix, s.outcome == .fail || s.outcome == .warn {
                        Label(f, systemImage: "lightbulb").font(.system(size: 11)).foregroundStyle(Theme.warn).padding(.leading, 56)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var summaryColor: Color {
        switch app.tester.summary { case .green: return Theme.ok; case .amber: return Theme.warn; case .red: return Theme.bad; case .none: return .secondary }
    }

    @ViewBuilder private func icon(_ o: ConnectionTester.Outcome) -> some View {
        switch o {
        case .pending: Image(systemName: "circle").foregroundStyle(.secondary.opacity(0.5))
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.warn)
        case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

struct TestView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Connection Test", subtitle: "Checks every layer from this Mac to the internet through your server.")
                Card { TesterStagesView() }
                HStack {
                    Button(app.tester.running ? "Testing…" : "Run full test") {
                        Task {
                            if !app.status.isActive { await app.connect() }
                            if let p = app.activeProfile { app.tester.run(engine: app.engine, profile: p) }
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(app.tester.running || app.activeProfile == nil)
                    if app.tester.running { Button("Stop") { app.tester.cancel() } }
                    Spacer()
                    CopyButton(text: app.tester.report(profileName: app.activeProfile?.name ?? "-"), label: "Copy report")
                        .help("Copies the results without passwords; IP addresses are partly masked.")
                }
            }
            .padding(28).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
    }
}
