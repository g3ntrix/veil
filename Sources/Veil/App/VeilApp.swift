import Combine
import SwiftUI

@main
struct VeilApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Veil") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 860, idealWidth: 940, minHeight: 600, idealHeight: 780)
                .preferredColorScheme(app.prefs.theme == 1 ? .light : (app.prefs.theme == 2 ? .dark : nil))
                .tint(Theme.accent)
                .onAppear { delegate.attach(app) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Connection") {
                Button(app.status.isActive ? "Disconnect" : "Connect") { Task { await app.toggleConnection() } }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Run Connection Test") {
                    app.tab = .test
                    if let p = app.activeProfile { app.tester.run(engine: app.engine, profile: p) }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppState.Tab.allCases.enumerated()), id: \.element) { i, t in
                    if i < 9 { Button(t.title) { app.tab = t }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command) }
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppState?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var monitor: Any?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.target = self
        popover.behavior = .transient
        updateIcon()
        if CommandLine.arguments.contains("--background") {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
    }

    func attach(_ state: AppState) {
        guard app == nil else { return }
        app = state
        cancellable = state.engine.$status.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }
    }

    private func updateIcon() {
        guard let b = statusItem?.button else { return }
        let st = app?.status ?? .stopped
        let name: String
        switch st {
        case .running: name = "shield.lefthalf.filled"
        case .degraded, .error: name = "exclamationmark.shield"
        case .starting, .stopping: name = "shield.lefthalf.filled.slash"
        case .stopped: name = "shield"
        }
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Veil: \(st.label)")
        img?.isTemplate = true
        b.image = img
        b.toolTip = "Veil: \(st.label)"
    }

    @objc private func togglePopover() {
        if popover.isShown { close(); return }
        guard let b = statusItem?.button, let app else { return }
        popover.contentViewController = NSHostingController(rootView: MenuBarView(openMain: { [weak self] in
            self?.close()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }).environmentObject(app))
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func close() {
        popover.performClose(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.shutdown()
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Group {
            if app.isWizardComplete {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
                } detail: {
                    ZStack {
                        AppBackground()
                        detail.transition(.opacity)
                    }
                }
            } else {
                ZStack { AppBackground(); WizardView() }
            }
        }
        .background(WindowAccessor())
        .animation(.easeInOut(duration: 0.2), value: app.tab)
    }

    @ViewBuilder private var detail: some View {
        switch app.tab {
        case .dashboard: DashboardView()
        case .test: TestView()
        case .servers: ServersView()
        case .share: ShareView()
        case .logs: LogsView()
        case .setup: WizardView()
        case .settings: SettingsView()
        case .about: AboutView()
        case .donate: DonateView()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("Veil").font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 16).padding(.top, 48).padding(.bottom, 18)
            ForEach([AppState.Tab.dashboard, .test, .servers, .share, .logs, .setup]) { item($0) }
            Spacer()
            ForEach([AppState.Tab.settings, .about, .donate]) { item($0) }
            HStack(spacing: 6) {
                StatusDot(color: app.status.color, animated: app.status == .running)
                Text(app.status.label).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
            .padding(12)
            .accessibilityElement(children: .combine)
        }
        .background(scheme == .dark ? Color(red: 0.06, green: 0.06, blue: 0.11) : Color(red: 0.94, green: 0.94, blue: 0.97))
    }

    private func item(_ t: AppState.Tab) -> some View {
        Button { app.tab = t } label: {
            HStack(spacing: 10) {
                Image(systemName: t.symbol).frame(width: 18)
                Text(t.title).font(.system(size: 13, weight: app.tab == t ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(app.tab == t ? Theme.accent.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(app.tab == t ? Theme.accent : .secondary)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(app.tab == t ? .isSelected : [])
    }
}
