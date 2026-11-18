import SwiftUI

// MARK: - Share to phone

struct ShareView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Share to Phone", subtitle: "Your phone uses this Mac's tunnel over Wi-Fi. Both must be on the same network.")
                Card {
                    Toggle(isOn: Binding(get: { app.prefs.lanSharing }, set: { v in Task { await app.setLanSharing(v) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share over Wi-Fi").font(.system(size: 14, weight: .semibold))
                            Text("Opens a password-protected SOCKS5 proxy on port \(String(app.prefs.tunnel.lanPort)).").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                if app.prefs.lanSharing {
                    if app.lanIPChanged {
                        Card {
                            HStack {
                                Label("This Mac's address changed. Scan the new code on your phone.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                                Spacer()
                                Button("Done") { app.acknowledgeLanIP() }
                            }
                        }
                    }
                    if let p = app.activeProfile, let s = app.secrets(for: p), let ip = app.lanIP, let link = app.shareLink {
                        Card {
                            HStack(alignment: .top, spacing: 24) {
                                if let img = QRCode.image(link) {
                                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 200, height: 200)
                                        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                                        .accessibilityLabel("QR code for the phone proxy")
                                }
                                VStack(alignment: .leading, spacing: 10) {
                                    Picker("Format", selection: $app.prefs.lanLinkStyle) {
                                        Text("V2Box / v2rayNG").tag(0); Text("socks5:// (NekoRay)").tag(1)
                                    }.pickerStyle(.segmented).frame(width: 300)
                                    field("Server", ip); field("Port", String(app.prefs.tunnel.lanPort))
                                    field("User", app.prefs.tunnel.lanUser); field("Password", s.lanPassword)
                                    HStack {
                                        CopyButton(text: link, label: "Copy link")
                                        Button("New password") { app.rotateLanPassword() }.font(.system(size: 11))
                                    }
                                }
                            }
                        }
                        if !app.status.isActive {
                            Text("Connect Veil first; the phone works only while Veil is connected.").font(.system(size: 12)).foregroundStyle(Theme.warn)
                        }
                    } else {
                        Card { Text("No Wi-Fi or Ethernet address found. Join a network first.").foregroundStyle(.secondary) }
                    }
                    Label("On public Wi-Fi, anyone on the network can try to connect. The password protects it; turn sharing off when you do not need it.", systemImage: "lock.shield")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Label("The phone connects through this Mac, so keep Veil connected while the phone uses it.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(28).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
    }

    private func field(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(v).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            CopyButton(text: v, label: "")
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject var app: AppState
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PageHeader(title: "Logs", subtitle: "Passwords and keys are never shown.")
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 160)
                CopyButton(text: app.diagnostics(), label: "Copy diagnostics")
                Button("Clear") { app.clearLogs() }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(app.logs.filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }) { l in
                            Text("\(l.date.formatted(date: .omitted, time: .standard))  [\(l.source)]  \(l.text)")
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .foregroundStyle(l.text.localizedCaseInsensitiveContains("fail") || l.text.contains("error") ? Theme.bad : .primary)
                                .id(l.id)
                        }
                    }
                    .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                .onChange(of: app.logs.count) { _ in if let last = app.logs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(28)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var loginOn = false
    @State private var helperInstalled = ProxyHelper.looksInstalled
    @State private var checking = false

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Use Veil for the whole Mac (system SOCKS and HTTP proxy)",
                       isOn: Binding(get: { app.prefs.systemProxy }, set: { app.setSystemProxy($0) }))
                Toggle("Connect automatically when Veil opens", isOn: $app.prefs.connectOnLaunch)
                Toggle("Open Veil at login", isOn: Binding(get: { loginOn }, set: { v in
                    loginOn = ((try? LaunchAtLogin.set(v)) != nil) ? v : LaunchAtLogin.isEnabled
                }))
                Text(helperInstalled
                     ? "Proxy helper installed. Turning the system proxy on or off won't ask for your password."
                     : "The first time you turn on the system proxy, macOS asks for your password once to install a small helper.")
                    .font(.caption).foregroundStyle(.secondary)
                if app.prefs.tunnel.socksPort != TunnelSettings.default.socksPort {
                    HStack {
                        Text("Veil moved to SOCKS \(String(app.prefs.tunnel.socksPort)) because another app used its ports.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use 10808 again") { app.prefs.tunnel = .default }.controlSize(.small)
                    }
                }
            }
            Section("Appearance") {
                Picker("Theme", selection: $app.prefs.theme) {
                    Text("System").tag(0); Text("Light").tag(1); Text("Dark").tag(2)
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $app.prefs.checkUpdates)
                HStack {
                    if let u = app.update {
                        Link("Veil \(u.version) is available", destination: u.dmg ?? u.page)
                    } else {
                        Text("Version \(AppUpdateService.currentVersion)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(checking ? "Checking…" : "Check now") {
                        checking = true
                        Task { await app.checkForUpdate(); checking = false }
                    }.disabled(checking)
                }
                Link("Releases page", destination: AppUpdateService.releasesPage)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .task {
            loginOn = LaunchAtLogin.isEnabled
            helperInstalled = await Task.detached { ProxyHelper.isInstalled() }.value
        }
    }
}

// MARK: - About

struct AboutView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("Veil").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Version \(AppUpdateService.currentVersion)").foregroundStyle(.secondary)
                Text("A fast private connection to your own server.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Link(destination: Brand.developerURL) {
                    Label("Made by \(Brand.developer) · github.com/\(Brand.developer)", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 13, weight: .medium))
                }
                HStack {
                    Link("Releases", destination: AppUpdateService.releasesPage)
                    Button { app.tab = .donate } label: { Label("Buy me a coffee", systemImage: "cup.and.saucer") }
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Free and open source").font(.system(size: 14, weight: .semibold))
                        Text("Veil is free software under the GNU General Public License v3.0. You can use, study, share and change it.")
                        Link("Read the license", destination: Brand.licenseURL)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Privacy").font(.system(size: 14, weight: .semibold))
                        Text("No ads and no tracking. Veil only contacts your server, test services during connection tests, and GitHub to check for updates.")
                        Text("Releases are not notarized by Apple. They are ad-hoc signed; you install them at your own risk.")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text("Bundles Xray-core (MPL-2.0).").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(36).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    let openMain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(color: app.status.color, animated: app.status == .running)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.status.label).font(.system(size: 13, weight: .semibold))
                    Text(app.engine.exitIP.map { "Exit IP \($0)" } ?? (app.activeProfile?.name ?? "No server")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button { Task { await app.toggleConnection() } } label: {
                Text(app.status.isActive ? "Disconnect" : "Connect").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(app.status.isActive ? Theme.bad : Theme.accent).controlSize(.large)
            .disabled(app.activeProfile == nil)
            if app.status.isActive {
                HStack {
                    Label(formatRate(app.engine.downBps), systemImage: "arrow.down")
                    Spacer()
                    Label(formatRate(app.engine.upBps), systemImage: "arrow.up")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if app.profiles.count > 1 {
                Picker("Server", selection: Binding(get: { app.activeProfile?.id }, set: { id in
                    if let p = app.profiles.first(where: { $0.id == id }) { Task { await app.selectProfile(p) } }
                })) { ForEach(app.profiles) { Text($0.name).tag(Optional($0.id)) } }
            }
            Divider()
            Toggle("System proxy", isOn: Binding(get: { app.prefs.systemProxy }, set: { app.setSystemProxy($0) }))
            Toggle("Share to phone", isOn: Binding(get: { app.prefs.lanSharing }, set: { v in Task { await app.setLanSharing(v) } }))
            Divider()
            Button("Run connection test") {
                if let p = app.activeProfile { app.tester.run(engine: app.engine, profile: p, quick: true) }
                app.tab = .test
                openMain()
            }.buttonStyle(.plain)
            CopyButton(text: "socks5h://127.0.0.1:\(app.prefs.tunnel.socksPort)", label: "Copy proxy address")
            Button("Open Veil") { openMain() }.buttonStyle(.plain)
            Button("Quit Veil") { NSApp.terminate(nil) }.buttonStyle(.plain).keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 270)
        .toggleStyle(.switch)
        .font(.system(size: 12))
    }
}
