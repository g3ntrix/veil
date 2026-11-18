import SwiftUI

struct WizardView: View {
    @EnvironmentObject var app: AppState
    @State private var forward = true

    enum Step: Int, CaseIterable {
        case welcome, vps, terminal, install, firewall, test, finish
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .vps: return "Your VPS"
            case .terminal: return "Open a terminal on your VPS"
            case .install: return "Install the server side"
            case .firewall: return "Open the cloud firewall"
            case .test: return "Test it"
            case .finish: return "You're set"
            }
        }
        var estimate: String {
            switch self {
            case .welcome: return "about 10 s"
            case .vps: return "about 1 min"
            case .terminal: return "about 1 min"
            case .install: return "2 to 4 min"
            case .firewall: return "about 3 min"
            case .test: return "about 1 min"
            case .finish: return ""
            }
        }
    }

    private var step: Step { Step(rawValue: app.wizard.step) ?? .welcome }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                StepIndicator(current: step.rawValue, total: Step.allCases.count)
                Group {
                    switch step {
                    case .welcome: WelcomeStep(next: { go(.vps) })
                    case .vps: VPSStep(back: { go(.welcome) }, next: { go(.terminal) })
                    case .terminal: TerminalStep(back: { go(.vps) }, next: { go(.install) })
                    case .install: InstallStep(back: { go(.terminal) }, toFirewall: { go(.firewall) }, toTest: { go(.test) })
                    case .firewall: FirewallStep(back: { go(.install) }, next: { go(.test) })
                    case .test: TestStep(back: { go(.install) }, next: { go(.finish) })
                    case .finish: FinishStep(back: { go(.test) })
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .padding(32)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        withAnimation(.easeInOut(duration: 0.3)) { app.wizard.step = s.rawValue }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step == .welcome ? "Set up Veil" : step.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Step \(step.rawValue + 1) of \(Step.allCases.count)\(step.estimate.isEmpty ? "" : " · \(step.estimate)")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Shared step chrome

struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    var help: String?
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(width: 26, height: 26).background(Circle().fill(Theme.accent.opacity(0.18))).foregroundStyle(Theme.accent)
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if let help { HelpButton(text: help) }
                }
                content
            }
        }
    }
}

struct StepNav: View {
    var back: (() -> Void)?
    var nextTitle = "Continue"
    var nextEnabled = true
    var skipTitle: String?
    var skip: (() -> Void)?
    let next: () -> Void

    var body: some View {
        HStack {
            if let back {
                Button(action: back) { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).keyboardShortcut("[", modifiers: .command)
            }
            Spacer()
            if let skip, let skipTitle { Button(skipTitle, action: skip).buttonStyle(.borderless).foregroundStyle(.secondary) }
            Button(action: next) { Text(nextTitle).frame(minWidth: 90) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                .disabled(!nextEnabled).keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - 0 Welcome and network doctor

struct WelcomeStep: View {
    @EnvironmentObject var app: AppState
    let next: () -> Void
    @State private var report: NetworkDoctor.Report?
    @State private var checking = false

    var body: some View {
        StepCard(number: 1, title: "Check this network", help: "Veil checks that this network allows the kind of traffic it needs. If it does not, Veil cannot work here.") {
            Text("Veil connects this Mac to your own server, fast, on networks that break normal VPNs.")
                .font(.system(size: 13))
            ChecklistRow(title: "This network is compatible",
                         detail: report.map { $0.udpWorks ? "Looks good" : "Veil's traffic is blocked on this network" } ?? "Checking…",
                         state: checking ? .checking : (report?.udpWorks == true ? .ok : (report == nil ? .waiting : .fail)))
            if let r = report, !r.udpWorks {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This network blocks the traffic Veil needs. Veil cannot work here.", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.bad)
                    Text("Use the Sonar app on networks like this one (slower, made for this case), or set Veil up now and use it on another network.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Check again") { Task { await run() } }
                }
            }
            StepNav(nextTitle: report?.udpWorks == false ? "Continue anyway" : "Get started", nextEnabled: !checking, next: next)
        }
        .task { if report == nil { await run() } }
    }

    private func run() async {
        checking = true
        report = await NetworkDoctor.run()
        checking = false
    }
}

// MARK: - 1 Your VPS

struct VPSStep: View {
    @EnvironmentObject var app: AppState
    let back: () -> Void
    let next: () -> Void
    @State private var address = ""
    @State private var user = "ubuntu"
    @State private var name = ""
    @State private var showGuide = false
    @State private var error: String?

    private var valid: Bool {
        let a = address.trimmingCharacters(in: .whitespaces)
        return AddressParser.isIPv4(a) ? AddressParser.isPublicIPv4(a) : (a.contains(".") && !a.contains(" ") && a.count > 3)
    }

    var body: some View {
        StepCard(number: 2, title: "Your VPS", help: "Veil needs a small Linux server you control. The cheapest plan is enough.") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Ubuntu 20.04 or newer, or Debian 11 or newer", "1 vCPU and 512 MB RAM are enough", "A public IPv4 address", "You can log in as root or a user with sudo"], id: \.self) {
                    Label($0, systemImage: "checkmark.circle").font(.system(size: 12))
                }
            }
            DisclosureGroup("I do not have a VPS yet", isExpanded: $showGuide) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Create an account with a provider. Oracle Cloud has an Always Free tier; Hetzner, DigitalOcean and Vultr cost a few dollars a month.")
                    Text("2. Create an instance with Ubuntu 22.04 or 24.04. Add your SSH key when asked (or download the key the provider generates).")
                    Text("3. Wait until it is running, then copy its public IP address here.")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
            }
            .font(.system(size: 12, weight: .medium))

            VStack(alignment: .leading, spacing: 6) {
                Text("SERVER IP OR HOSTNAME").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                TextField("e.g. 203.0.113.10, or paste an ssh line", text: $address)
                    .textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced))
                    .onChange(of: address) { v in autoFill(v) }
                    .accessibilityLabel("Server IP address")
                if !address.isEmpty && !valid {
                    Text("That does not look like a public IPv4 address or hostname.").font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH USER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $user) {
                        Text("ubuntu").tag("ubuntu"); Text("root").tag("root"); Text("debian").tag("debian"); Text("opc").tag("opc")
                        if !["ubuntu", "root", "debian", "opc"].contains(user) { Text(user).tag(user) }
                    }
                    .labelsHidden().frame(width: 140)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME (OPTIONAL)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    TextField("My server", text: $name).textFieldStyle(.roundedBorder)
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.bad) }
            StepNav(back: back, nextEnabled: valid, next: save)
        }
        .onAppear(perform: load)
    }

    private func autoFill(_ v: String) {
        guard v.contains(" ") || v.contains("@") || v.contains("\n") else { return }
        let r = AddressParser.parse(v)
        if let ip = r.ips.first {
            address = ip
            if let u = r.sshUser { user = u }
        } else if let host = v.split(separator: "@").last.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines), host.contains(".") {
            if let u = r.sshUser { user = u }
            address = host
        }
    }

    private func load() {
        guard let id = app.wizard.draftProfileID, let p = app.profiles.first(where: { $0.id == id }) else { return }
        address = p.address; user = p.sshUser; name = p.name
    }

    private func save() {
        let a = address.trimmingCharacters(in: .whitespaces)
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? "My server" : name
        do {
            if let id = app.wizard.draftProfileID, var p = app.profiles.first(where: { $0.id == id }) {
                p.address = a; p.sshUser = user; p.name = n
                app.update(p)
            } else {
                let p = try app.createProfile(name: n, address: a, sshUser: user)
                app.wizard.draftProfileID = p.id
                app.prefs.activeProfileID = p.id
            }
            next()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 2 Open a terminal on your VPS

struct TerminalStep: View {
    @EnvironmentObject var app: AppState
    let back: () -> Void
    let next: () -> Void
    @State private var sshUp: Bool?

    var profile: ServerProfile? { app.profiles.first { $0.id == app.wizard.draftProfileID } }

    var body: some View {
        StepCard(number: 3, title: "Log in to your VPS", help: "Veil never stores your SSH keys or passwords and never logs in for you. You run every command yourself.") {
            Text("Run this on your Mac, then answer \"yes\" if it asks about the server's fingerprint.").font(.system(size: 13))
            if let p = profile {
                CommandBlock(title: "On your Mac", command: p.sshCommand, terminalCommand: p.sshCommand)
                ChecklistRow(title: "SSH port on \(p.address) is reachable",
                             detail: sshUp == false ? "No answer on TCP 22 yet. Check the IP and that the VPS is running." : (sshUp == true ? "The server answers. Log in, then continue." : "Checking…"),
                             state: sshUp == nil ? .checking : (sshUp! ? .ok : .fail))
            }
            StepNav(back: back, nextTitle: "I'm logged in", next: next)
        }
        .task(id: profile?.address) {
            guard let p = profile else { return }
            while !Task.isCancelled {
                let up = await TCPProbe.reachable(host: p.address, port: 22)
                withAnimation { sshUp = up }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

// MARK: - 3 Install

struct InstallStep: View {
    @EnvironmentObject var app: AppState
    let back: () -> Void
    let toFirewall: () -> Void
    let toTest: () -> Void

    @State private var sshUp: Bool?
    @State private var probe: RelayProbeResult?
    @State private var copiedAt: Date?
    @State private var advanced = false

    var profile: ServerProfile? { app.profiles.first { $0.id == app.wizard.draftProfileID } }
    var relayUp: Bool { probe?.answered == true }
    var hyUp: Bool { probe?.hysteria == true }

    var body: some View {
        StepCard(number: 4, title: "Install the server side",
                 help: "The command installs Veil's server software and opens one firewall port. Running it again is safe and keeps the same keys.") {
            Text("Copy this one command and paste it into the terminal where you are logged in to the VPS.").font(.system(size: 13))
            if let p = profile {
                CommandBlock(title: "On the VPS (one paste)", command: app.installCommand(for: p), collapsedPreview: true)
                    .simultaneousGesture(TapGesture().onEnded { if copiedAt == nil { copiedAt = Date() } })
            }
            VStack(alignment: .leading, spacing: 10) {
                ChecklistRow(title: "SSH reachable", state: sshUp == nil ? .checking : (sshUp! ? .ok : .fail))
                ChecklistRow(title: "Veil server answering",
                             detail: relayUp ? String(format: "Answered in %.0f ms", probe?.rttMedianMs ?? 0) : "Turns green by itself when the install finishes",
                             state: relayUp ? .ok : .checking)
                ChecklistRow(title: "Secure tunnel ready on the server",
                             detail: relayUp && !hyUp ? "Not running yet. Run the install command again." : "",
                             state: relayUp ? (hyUp ? .ok : .fail) : .waiting)
            }
            if !relayUp, let t = copiedAt {
                TimelineView(.periodic(from: t, by: 5)) { ctx in
                    if ctx.date.timeIntervalSince(t) > 60, sshUp == true {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("If the install has finished, your cloud firewall is probably blocking Veil.", systemImage: "flame")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                            Button("Open the cloud firewall step", action: toFirewall).buttonStyle(.borderedProminent).tint(Theme.accent)
                        }
                    } else {
                        WaitRing(label: "Waiting for the install to finish", since: t)
                    }
                }
            }
            StepNav(back: back, nextTitle: relayUp ? "Continue" : "The install finished",
                    nextEnabled: !(relayUp && !hyUp), next: { relayUp ? toTest() : toFirewall() })
        }
        .task(id: profile?.address) {
            guard let p = profile else { return }
            while !Task.isCancelled {
                async let s = TCPProbe.reachable(host: p.address, port: 22)
                async let r = RelayProbe.run(server: p.address, port: p.relayPort, count: 3, rotate: 0, intervalMs: 50, waitMs: 1200)
                let (sv, rv) = await (s, r)
                withAnimation { sshUp = sv; probe = rv }
                if let rv, rv.answered, rv.hysteria == true, !advanced {
                    advanced = true
                    app.recordServerState(p, version: Versions.serverScripts, ok: true, note: "Server answers")
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    toTest()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

// MARK: - 4 Cloud firewall

struct FirewallStep: View {
    @EnvironmentObject var app: AppState
    let back: () -> Void
    let next: () -> Void
    @State private var probe: RelayProbeResult?
    @State private var provider = 0
    @State private var since = Date()

    var profile: ServerProfile? { app.profiles.first { $0.id == app.wizard.draftProfileID } }
    var port: Int { profile?.relayPort ?? 2100 }

    var body: some View {
        StepCard(number: 5, title: "Open UDP \(port) in your cloud firewall",
                 help: "Cloud providers filter traffic before it reaches your VPS. The install opened the VPS's own firewall, but the provider's firewall is separate and only you can change it.") {
            Text("Add one rule that allows UDP port \(String(port)) from anywhere. Veil watches and continues by itself.").font(.system(size: 13))
            Picker("", selection: $provider) {
                Text("Oracle Cloud").tag(0); Text("Other providers").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            if provider == 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Open the Oracle Cloud console: Compute, Instances, click your instance.")
                    Text("2. Under Primary VNIC, click the Subnet, then the Default Security List.")
                    Text("3. Add Ingress Rules: Source CIDR 0.0.0.0/0, IP Protocol UDP, Destination Port Range \(String(port)). Save.")
                    Text("4. If the instance uses a Network Security Group, add the same rule there.")
                }
                .font(.system(size: 12))
                Link(destination: URL(string: "https://cloud.oracle.com/compute/instances")!) {
                    Label("Open Oracle Cloud instances", systemImage: "arrow.up.right.square")
                }.font(.system(size: 12, weight: .medium))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In your provider's console, find Firewall, Security Group or Network rules for this server.")
                    Text("Add an inbound (ingress) rule: protocol UDP, port \(String(port)), source anywhere (0.0.0.0/0).")
                    Text("Hetzner: Firewalls. DigitalOcean: Networking, Firewalls. AWS: Security Groups. Google Cloud: VPC firewall rules.")
                }
                .font(.system(size: 12))
            }
            ChecklistRow(title: "Server reachable from this Mac",
                         detail: probe?.answered == true ? "It answers. The firewall is open." : "Not yet. Rules can take a minute to apply.",
                         state: probe?.answered == true ? .ok : .checking)
            if probe?.answered != true { WaitRing(label: "Watching UDP \(port)", since: since) }
            WhyDisclosure(text: "If the install self-test passed on the server but Veil cannot reach UDP \(port), the only layer left between is the provider's network firewall.")
            StepNav(back: back, nextTitle: "Continue", nextEnabled: probe?.answered == true, skipTitle: "Skip", skip: next, next: next)
        }
        .task(id: profile?.address) {
            guard let p = profile else { return }
            while !Task.isCancelled {
                let r = await RelayProbe.run(server: p.address, port: p.relayPort, count: 3, rotate: 0, intervalMs: 50, waitMs: 1200)
                withAnimation { probe = r }
                if r?.answered == true {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    next()
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}

// MARK: - 5 Test

struct TestStep: View {
    @EnvironmentObject var app: AppState
    let back: () -> Void
    let next: () -> Void
    @State private var started = false

    var body: some View {
        StepCard(number: 6, title: "Test the tunnel", help: "Veil connects, then checks each layer from this Mac to the internet through your server.") {
            if case .error(let e) = app.status { Text(e).font(.system(size: 12)).foregroundStyle(Theme.bad) }
            if let e = app.lastError { Text(e).font(.system(size: 12)).foregroundStyle(Theme.bad) }
            if let c = app.portConflict { PortConflictView(conflict: c) }
            TesterStagesView()
            HStack {
                Button(app.tester.running ? "Testing…" : "Run again") { Task { await runTest() } }
                    .disabled(app.tester.running)
                Spacer()
            }
            StepNav(back: back, nextTitle: app.tester.summary == .red ? "Continue anyway" : "Continue",
                    nextEnabled: !app.tester.running, next: next)
        }
        .task { if !started { started = true; await runTest() } }
    }

    private func runTest() async {
        if !app.engine.status.isActive { await app.connect() }
        if let p = app.activeProfile { app.tester.run(engine: app.engine, profile: p) }
    }
}

// MARK: - 6 Finish

struct FinishStep: View {
    @EnvironmentObject var app: AppState
    let back: () -> Void
    @State private var appear = false
    @State private var loginOn = LaunchAtLogin.isEnabled
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        StepCard(number: 7, title: "Veil is ready") {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 42)).foregroundStyle(Theme.gradient)
                    .scaleEffect(appear || reduceMotion ? 1 : 0.4).opacity(appear ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.55), value: appear)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your private tunnel works.").font(.system(size: 15, weight: .semibold))
                    Text("Apps can use SOCKS5 127.0.0.1:\(String(app.prefs.tunnel.socksPort)) or HTTP 127.0.0.1:\(String(app.prefs.tunnel.httpPort)).")
                        .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Toggle("Send all Mac traffic through Veil (system proxy)", isOn: Binding(get: { app.prefs.systemProxy }, set: { app.setSystemProxy($0) }))
            Toggle("Share to my phone (V2Box, NekoRay) over Wi-Fi", isOn: Binding(get: { app.prefs.lanSharing }, set: { v in Task { await app.setLanSharing(v) } }))
            if app.prefs.lanSharing { Button("Show the QR code") { app.tab = .share; app.finishWizard(); app.tab = .share } }
            Toggle("Open Veil when I log in", isOn: $loginOn).onChange(of: loginOn) { v in try? LaunchAtLogin.set(v) }
            VStack(alignment: .leading, spacing: 4) {
                Label("The menu bar icon connects, disconnects and runs a test.", systemImage: "menubar.rectangle")
                Label("When your network changes, Veil checks the tunnel and restarts it if needed. If it still fails, run the connection test.", systemImage: "arrow.triangle.2.circlepath")
                Label("If your VPS gets a new IP, use Servers, Change IP. Nothing changes on the VPS.", systemImage: "server.rack")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            StepNav(back: back, nextTitle: "Open the dashboard") { app.finishWizard() }
        }
        .onAppear { appear = true }
    }
}

// MARK: - Port conflict

struct PortConflictView: View {
    @EnvironmentObject var app: AppState
    let conflict: TunnelError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(conflict.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
            Text("Veil and other proxy apps (for example Sonar) use the same ports, so only one can run at a time.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                if case .portBusy(_, let h?) = conflict {
                    Button("Stop \(h.appName ?? h.command) and connect") { Task { await app.resolveConflictByStopping() } }
                }
                Button("Use other ports") { Task { await app.resolveConflictByMoving() } }
                Button("Dismiss") { app.portConflict = nil }.buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.08)))
    }
}
