import AppKit
import SwiftUI

// MARK: - Theme

enum Theme {
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.95)
    static let accent2 = Color(red: 0.66, green: 0.38, blue: 0.92)
    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let ok = Color.green
    static let warn = Color.orange
    static let bad = Color.red
}

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.primary.opacity(0.1), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}

struct AppBackground: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.08) : Color(red: 0.97, green: 0.97, blue: 0.99))
            Circle().fill(Theme.accent.opacity(scheme == .dark ? 0.14 : 0.08)).frame(width: 420).blur(radius: 120).offset(x: -220, y: -220)
            Circle().fill(Theme.accent2.opacity(scheme == .dark ? 0.12 : 0.06)).frame(width: 360).blur(radius: 120).offset(x: 260, y: 220)
        }
        .ignoresSafeArea()
    }
}

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.setFrameAutosaveName("VeilMain")
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Status

struct StatusDot: View {
    let color: Color
    var animated = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                Circle().fill(color.opacity(0.25)).frame(width: 20, height: 20)
                    .scaleEffect(pulse ? 1.6 : 1).opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(color).frame(width: 10, height: 10)
        }
        .frame(width: 20, height: 20)
        .onAppear { if animated { pulse = true } }
        .accessibilityHidden(true)
    }
}

extension TunnelStatus {
    var color: Color {
        switch self {
        case .running: return Theme.ok
        case .starting, .stopping: return .yellow
        case .degraded: return Theme.warn
        case .error: return Theme.bad
        case .stopped: return .secondary.opacity(0.5)
        }
    }
}

// MARK: - Copy and code

struct CopyButton: View {
    let text: String
    var label = "Copy"
    var prominent = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.spring(response: 0.3)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { copied = false } }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: prominent ? 13 : 11, weight: .semibold))
                .padding(.horizontal, prominent ? 14 : 0)
                .padding(.vertical, prominent ? 7 : 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.white : (copied ? Theme.ok : Theme.accent))
        .background {
            if prominent {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(copied ? AnyShapeStyle(Theme.ok) : AnyShapeStyle(Theme.gradient))
            }
        }
        .accessibilityLabel(copied ? "Copied" : "\(label) to clipboard")
    }
}

struct CommandBlock: View {
    let title: String
    let command: String
    var terminalCommand: String?
    var collapsedPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let t = terminalCommand {
                    Button { Terminal.open(withCommandReady: t) } label: {
                        Label("Open Terminal", systemImage: "terminal").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .help("Opens Terminal with this command typed in. Press Return to run it.")
                }
                CopyButton(text: command, prominent: true).keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))
            Divider().opacity(0.2)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(collapsedPreview && command.count > 140 ? String(command.prefix(110)) + " … (\(command.count) characters, copy it all with the button)" : command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(collapsedPreview ? 2 : nil)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

enum Terminal {
    static func open(withCommandReady cmd: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let quoted = cmd.replacingOccurrences(of: "'", with: "'\\''")
        let line = shell.hasSuffix("zsh") ? "print -z '\(quoted)'" : cmd
        let esc = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = """
        tell application "Terminal"
            activate
            do script "\(esc)"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err != nil { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")) }
    }
}

// MARK: - Wizard pieces

struct StepIndicator: View {
    let current: Int
    let total: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule().fill(i <= current ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    .frame(height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}

enum CheckState: Equatable { case waiting, checking, ok, fail, skipped }

struct ChecklistRow: View {
    let title: String
    var detail: String = ""
    let state: CheckState
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                switch state {
                case .waiting: Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                case .checking: ProgressView().controlSize(.small).scaleEffect(0.7)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).transition(.scale.combined(with: .opacity))
                case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.bad)
                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 16))
            .frame(width: 18, height: 18)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: state)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue({
            switch state { case .ok: return "done"; case .fail: return "failed"; case .checking: return "checking"; case .skipped: return "skipped"; case .waiting: return "waiting" }
        }())
    }
}

struct WaitRing: View {
    let label: String
    let since: Date
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
                Circle().trim(from: 0, to: 0.28).stroke(Theme.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium))
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text("\(Int(ctx.date.timeIntervalSince(since))) s").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { spin = true }
    }
}

struct WhyDisclosure: View {
    let text: String
    @State private var open = false
    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        } label: {
            Text("Why?").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
        }
    }
}

struct HelpButton: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "questionmark.circle").font(.system(size: 14)) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).font(.system(size: 12)).padding(14).frame(width: 300).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel("Help")
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
