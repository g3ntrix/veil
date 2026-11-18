import SwiftUI
import UniformTypeIdentifiers

struct ServersView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: UUID?
    @State private var sheet: SheetKind?
    @State private var confirmDelete: ServerProfile?
    @State private var confirmRotate: ServerProfile?
    @State private var error: String?

    enum SheetKind: Identifiable {
        case changeIP(ServerProfile), edit(ServerProfile), install(ServerProfile), health(ServerProfile), uninstall(ServerProfile)
        var id: String {
            switch self {
            case .changeIP(let p): return "ip\(p.id)"
            case .edit(let p): return "ed\(p.id)"
            case .install(let p): return "in\(p.id)"
            case .health(let p): return "he\(p.id)"
            case .uninstall(let p): return "un\(p.id)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    PageHeader(title: "Servers", subtitle: "Your VPS profiles. Keys stay in your Keychain.")
                    Spacer()
                    Button { importProfile() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    Button {
                        app.wizard = WizardProgress(step: 1)
                        app.tab = .setup
                    } label: { Label("Add server", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.bad) }
                ForEach(app.profiles) { p in row(p) }
                if app.profiles.isEmpty { Card { Text("No servers yet. Add one with the setup wizard.").foregroundStyle(.secondary) } }
            }
            .padding(28).frame(maxWidth: 820).frame(maxWidth: .infinity)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .changeIP(let p): ChangeIPSheet(profile: p)
            case .edit(let p): EditProfileSheet(profile: p)
            case .install(let p): CommandSheet(title: "Install command for \(p.name)", text: "Run this in an SSH session on the VPS. Safe to run again; the keys stay the same.", command: app.installCommand(for: p))
            case .health(let p): HealthSheet(profile: p)
            case .uninstall(let p): CommandSheet(title: "Remove Veil from \(p.name)", text: "Run this on the VPS to remove everything Veil installed. Then delete the profile here.", command: ServerScript.uninstallCommand)
            }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete profile and keys", role: .destructive) { if let p = confirmDelete { Task { await app.delete(p) } } }
            Button("Show the uninstall command first") { if let p = confirmDelete { sheet = .uninstall(p) } }
        } message: { Text("The keys are removed from this Mac. The VPS keeps running Veil until you run the uninstall command there.") }
        .confirmationDialog("Rotate credentials for \(confirmRotate?.name ?? "")?", isPresented: Binding(get: { confirmRotate != nil }, set: { if !$0 { confirmRotate = nil } })) {
            Button("Make new keys", role: .destructive) {
                if let p = confirmRotate {
                    do { try app.rotateCredentials(p); sheet = .install(p) } catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("Veil makes a new certificate and passwords. The tunnel stops working until you run the new install command on the VPS.") }
    }

    private func row(_ p: ServerProfile) -> some View {
        let active = app.activeProfile?.id == p.id
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(active ? Theme.accent : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(p.name).font(.system(size: 15, weight: .semibold))
                            if active { Pill(text: "ACTIVE", color: Theme.accent) }
                            if let v = p.installedVersion, v < Versions.serverScripts { Pill(text: "UPDATE AVAILABLE", color: Theme.warn) }
                        }
                        Text("\(p.address) · port \(String(p.relayPort)) · \(p.sshUser)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        if let c = p.lastCheck {
                            Text("\(c.ok ? "OK" : "Problem"): \(c.note), \(c.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 11)).foregroundStyle(c.ok ? Theme.ok : Theme.warn)
                        }
                    }
                    Spacer()
                    if !active { Button("Use") { Task { await app.selectProfile(p) } } }
                    Menu {
                        Button("Change IP…") { sheet = .changeIP(p) }
                        Button("Edit…") { sheet = .edit(p) }
                        Button("Show install command") { sheet = .install(p) }
                        Button("Check server health…") { sheet = .health(p) }
                        Divider()
                        Button("Duplicate") { do { try app.duplicate(p) } catch { self.error = error.localizedDescription } }
                        Button("Export…") { export(p) }
                        Button("Rotate credentials…") { confirmRotate = p }
                        Divider()
                        Button("Delete…", role: .destructive) { confirmDelete = p }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).frame(width: 36)
                    .accessibilityLabel("Actions for \(p.name)")
                }
            }
        }
    }

    private func export(_ p: ServerProfile) {
        guard let s = app.secrets(for: p), let data = try? ProfileTransfer.export(p, s) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name).\(ProfileTransfer.fileExtension)"
        panel.message = "This file contains your server's keys. Anyone who has it can use your server."
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ProfileTransfer.fileExtension) ?? .json, .json]
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            do { try app.importProfile(data) } catch { self.error = error.localizedDescription }
        }
    }
}

struct CommandSheet: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    let text: String
    let command: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            CommandBlock(title: "On the VPS", command: command, collapsedPreview: true)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 560)
    }
}

struct ChangeIPSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let profile: ServerProfile
    @State private var newAddress = ""
    @State private var probing = false
    @State private var newProbe: RelayProbeResult?
    @State private var oldAnswers: Bool?
    @State private var newSSH: Bool?
    @State private var probed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change IP of \(profile.name)").font(.system(size: 18, weight: .bold, design: .rounded))
            Text("Same VPS with a new IP: nothing changes on the VPS. A new or rebuilt VPS: run the same install command again; your keys stay valid.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Current").frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                Text(profile.address).font(.system(size: 13, design: .monospaced))
            }
            HStack {
                Text("New").frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                TextField("New IP or hostname, or paste text containing it", text: $newAddress)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                    .onChange(of: newAddress) { v in
                        probed = false
                        if v.contains(" ") || v.contains("\n"), let ip = AddressParser.parse(v).ips.first { newAddress = ip }
                    }
            }
            if probed {
                VStack(alignment: .leading, spacing: 8) {
                    ChecklistRow(title: "New address reachable on SSH", state: newSSH == true ? .ok : .fail)
                    ChecklistRow(title: "Veil server answers at the new address",
                                 detail: newProbe?.answered == true ? (newProbe?.hysteria == true ? "Tunnel ready" : "Tunnel service not running") : "",
                                 state: newProbe?.answered == true ? .ok : .fail)
                    if oldAnswers == true {
                        Label("The old address still answers too. Make sure you picked the right server.", systemImage: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Theme.warn)
                    }
                    if newSSH == true && newProbe?.answered != true {
                        Label("This looks like a new server. Save, then run the install command again (same command as before). If it still does not answer, open UDP \(String(profile.relayPort)) in the cloud firewall.", systemImage: "info.circle")
                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if probing { ProgressView("Probing…").controlSize(.small) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Probe") { Task { await probe() } }.disabled(!valid || probing)
                Button(probed && newProbe?.answered != true ? "Save anyway" : "Save and reconnect") { Task { await save() } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!valid || !probed)
            }
        }
        .padding(24).frame(width: 540)
    }

    var valid: Bool {
        let a = newAddress.trimmingCharacters(in: .whitespaces)
        return a != profile.address && (AddressParser.isPublicIPv4(a) || (!AddressParser.isIPv4(a) && a.contains(".")))
    }

    private func probe() async {
        probing = true
        let a = newAddress.trimmingCharacters(in: .whitespaces)
        async let n = RelayProbe.run(server: a, port: profile.relayPort, count: 3, rotate: 0)
        async let o = RelayProbe.run(server: profile.address, port: profile.relayPort, count: 3, rotate: 0)
        async let s = TCPProbe.reachable(host: a, port: 22)
        let (nv, ov, sv) = await (n, o, s)
        newProbe = nv; oldAnswers = ov?.answered; newSSH = sv
        probed = true
        probing = false
    }

    private func save() async {
        var p = profile
        p.address = newAddress.trimmingCharacters(in: .whitespaces)
        app.update(p)
        dismiss()
        if newProbe?.answered != true {
            app.banner = "Address changed. Run the install command on the new server (Servers, Show install command)."
            return
        }
        if app.activeProfile?.id == p.id {
            await app.reconnect()
            app.tester.run(engine: app.engine, profile: p, quick: true)
            app.tab = .test
        }
    }
}

struct EditProfileSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let profile: ServerProfile
    @State private var name = ""
    @State private var user = ""
    @State private var port = 2100

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(profile.name)").font(.system(size: 18, weight: .bold, design: .rounded))
            Form {
                TextField("Name", text: $name)
                TextField("SSH user", text: $user)
                TextField("Server port (UDP)", value: $port, format: .number.grouping(.never))
            }
            if port != profile.relayPort {
                Text("A new server port needs the install command to run again on the VPS, and the cloud firewall rule to change.")
                    .font(.system(size: 11)).foregroundStyle(Theme.warn)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    var p = profile
                    p.name = name; p.sshUser = user; p.relayPort = max(1, min(65535, port))
                    app.update(p)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(name.isEmpty || user.isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { name = profile.name; user = profile.sshUser; port = profile.relayPort }
    }
}

struct HealthSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    let profile: ServerProfile
    @State private var probe: RelayProbeResult?
    @State private var probing = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Server health: \(profile.name)").font(.system(size: 18, weight: .bold, design: .rounded))
            ChecklistRow(title: "Server answers from this Mac",
                         detail: probe.map { $0.answered ? String(format: "%.0f ms, server v%@", $0.rttMedianMs, $0.serverVersion ?? "?") : "No answer" } ?? "",
                         state: probing ? .checking : (probe?.answered == true ? .ok : .fail))
            ChecklistRow(title: "Tunnel service running", state: probing ? .checking : (probe?.hysteria == true ? .ok : (probe?.answered == true ? .fail : .skipped)))
            if let v = probe?.relayVersion, v < Versions.serverRelay {
                Label("Server update available. Run the install command again to update.", systemImage: "arrow.up.circle").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 560)
        .task {
            probe = await RelayProbe.run(server: profile.address, port: profile.relayPort, count: 3, rotate: 0)
            probing = false
            if let p = probe {
                app.recordServerState(profile, version: nil, ok: p.answered && p.hysteria == true,
                                      note: p.answered ? (p.hysteria == true ? "Server answers" : "Tunnel service down") : "Server not answering")
            }
        }
    }
}
