import Foundation

@MainActor
final class ConnectionTester: ObservableObject {
    enum Outcome: Equatable { case pending, running, pass, warn, fail, skipped }

    struct Stage: Identifiable, Equatable {
        let id: Kind
        var outcome: Outcome = .pending
        var detail = ""
        var fix: String?
        var seconds: Double?
        var title: String { id.title }
    }

    enum Kind: Int, CaseIterable, Identifiable {
        case engine, path, handshake, egress, dns, latency, speed, parallel, reach
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .engine: return "Veil on this Mac"
            case .path: return "Path to your server"
            case .handshake: return "Tunnel handshake"
            case .egress: return "Exit IP is your server"
            case .dns: return "DNS through the tunnel"
            case .latency: return "Latency"
            case .speed: return "Speed"
            case .parallel: return "Parallel downloads"
            case .reach: return "Popular sites"
            }
        }
        var symbol: String {
            switch self {
            case .engine: return "laptopcomputer"
            case .path: return "point.3.connected.trianglepath.dotted"
            case .handshake: return "hand.wave"
            case .egress: return "globe"
            case .dns: return "character.book.closed"
            case .latency: return "timer"
            case .speed: return "speedometer"
            case .parallel: return "square.stack.3d.down.forward"
            case .reach: return "paperplane"
            }
        }
    }

    enum Summary: Equatable { case none, green, amber, red }

    @Published private(set) var stages: [Stage] = Kind.allCases.map { Stage(id: $0) }
    @Published private(set) var running = false
    @Published private(set) var finishedAt: Date?

    var summary: Summary {
        if stages.allSatisfy({ $0.outcome == .pending }) { return .none }
        if stages.contains(where: { $0.outcome == .fail }) { return .red }
        if stages.contains(where: { $0.outcome == .warn }) { return .amber }
        return stages.contains(where: { $0.outcome == .pass }) ? .green : .none
    }

    var summaryText: String {
        switch summary {
        case .none: return "Not run yet"
        case .green: return "Everything works"
        case .amber: return "Works, with warnings"
        case .red:
            let f = stages.first { $0.outcome == .fail }!
            return "Stopped at: \(f.title)"
        }
    }

    private var task: Task<Void, Never>?

    func run(engine: TunnelEngine, profile: ServerProfile, quick: Bool = false) {
        task?.cancel()
        task = Task { await runAll(engine: engine, profile: profile, quick: quick) }
    }

    func cancel() { task?.cancel(); running = false }

    private func set(_ k: Kind, _ o: Outcome, _ detail: String, fix: String? = nil, seconds: Double? = nil) {
        stages[k.rawValue].outcome = o
        stages[k.rawValue].detail = detail
        stages[k.rawValue].fix = fix
        stages[k.rawValue].seconds = seconds
    }

    private func skipRest(from k: Kind, reason: String) {
        for s in Kind.allCases where s.rawValue > k.rawValue { set(s, .skipped, reason) }
    }

    private func runAll(engine: TunnelEngine, profile: ServerProfile, quick: Bool) async {
        running = true
        finishedAt = nil
        stages = Kind.allCases.map { Stage(id: $0) }
        defer { running = false; finishedAt = Date() }
        let s = engine.settings ?? .default
        let port = s.socksPort

        var t0 = Date()
        set(.engine, .running, "Checking Veil's engine and local ports")
        let socksUp = Ports.tcpListening(port), httpUp = Ports.tcpListening(s.httpPort)
        let localOK = engine.relayRunning && engine.xrayRunning && socksUp && httpUp
        if !localOK {
            var missing: [String] = []
            if !engine.relayRunning { missing.append("engine not running") }
            if !engine.xrayRunning { missing.append("proxy core not running") }
            if !socksUp { missing.append("SOCKS \(String(port)) closed") }
            if !httpUp { missing.append("HTTP \(String(s.httpPort)) closed") }
            set(.engine, .fail, missing.joined(separator: ", "), fix: "Press Connect. If it stops again, open Logs to see why.", seconds: Date().timeIntervalSince(t0))
        } else {
            set(.engine, .pass, "Engine, SOCKS \(String(port)) and HTTP \(String(s.httpPort)) are up", seconds: Date().timeIntervalSince(t0))
        }
        if Task.isCancelled { return }

        t0 = Date()
        set(.path, .running, "Checking the path to your server")
        let probe = await RelayProbe.run(server: profile.address, port: profile.relayPort, count: 40,
                                         rotate: s.rotateEvery, intervalMs: 20, waitMs: 1500)
        var hysteriaDown = false
        if let p = probe, p.answered {
            hysteriaDown = p.hysteria == false
            let loss = String(format: "%.0f%%", p.lossPercent)
            let rtt = String(format: "%.0f ms", p.rttMedianMs)
            if p.receivedAfter30 == 0 {
                set(.path, .fail, "Replies stopped part-way (\(p.received)/\(p.sent))",
                    fix: "This network interferes with the connection. Try again later or on another network.",
                    seconds: Date().timeIntervalSince(t0))
            } else if p.lossPercent > 20 {
                set(.path, .warn, "\(p.received)/\(p.sent) replies, loss \(loss), RTT \(rtt)",
                    fix: "High loss: the tunnel works but will be slow on this network.", seconds: Date().timeIntervalSince(t0))
            } else {
                set(.path, .pass, "\(p.received)/\(p.sent) replies, loss \(loss), RTT \(rtt)",
                    seconds: Date().timeIntervalSince(t0))
            }
            if let v = p.relayVersion, v < Versions.serverRelay {
                stages[Kind.path.rawValue].detail += ". Server update available."
            }
        } else {
            let sshUp = await TCPProbe.reachable(host: profile.address, port: 22)
            let udpOK = await NetworkDoctor.run().udpWorks
            let (why, fix): (String, String) = !udpOK
                ? ("This network blocks the traffic Veil needs.", "Veil cannot work on this network. Use the Sonar app here, or another network.")
                : sshUp
                    ? ("The server is up, but Veil's server software does not answer.",
                       "Most likely the cloud firewall: add an ingress rule for UDP \(String(profile.relayPort)). If this is a new or rebuilt server, run the install command again.")
                    : ("The server does not answer at all.", "Check the IP and that the VPS is running in your provider's console.")
            set(.path, .fail, why, fix: fix, seconds: Date().timeIntervalSince(t0))
            skipRest(from: .path, reason: "Needs a working path to the server")
            return
        }
        if Task.isCancelled { return }
        guard localOK else { skipRest(from: .path, reason: "Needs Veil connected"); return }

        t0 = Date()
        set(.handshake, .running, "Opening a secure session")
        let hs = await ProxyCurl.get("http://cp.cloudflare.com/generate_204", socksPort: port, timeout: 12, discardBody: true)
        if hs.httpCode == 204 || hs.httpCode == 200 {
            set(.handshake, .pass, String(format: "Session established (%.0f ms)", hs.timeTotal * 1000), seconds: Date().timeIntervalSince(t0))
        } else {
            let fix = hysteriaDown
                ? "The tunnel service is not running on the server. Run the install command on the VPS again."
                : "The server refused the keys. If you rotated credentials or reinstalled with another profile, run this profile's install command again."
            set(.handshake, .fail, hysteriaDown ? "The server answers but its tunnel service is down" : "No session (\(hs.error.isEmpty ? "timeout" : hs.error))",
                fix: fix, seconds: Date().timeIntervalSince(t0))
            skipRest(from: .handshake, reason: "Needs a tunnel session")
            return
        }
        if Task.isCancelled { return }

        t0 = Date()
        set(.egress, .running, "Asking api.ipify.org")
        let expected = engine.expectedIPs
        if let ip = await EgressInfo.exitIP(socksPort: port) {
            if expected.isEmpty || expected.contains(ip) {
                set(.egress, .pass, "Traffic exits from \(ip), your server", seconds: Date().timeIntervalSince(t0))
            } else {
                set(.egress, .fail, "Traffic exits from \(ip), expected \(expected.joined(separator: " or "))",
                    fix: "Another proxy is in the way, or the profile points to the wrong server. Check the server address.",
                    seconds: Date().timeIntervalSince(t0))
            }
        } else {
            set(.egress, .fail, "Could not read the exit IP", fix: "Run the test again; if it repeats, reconnect.", seconds: Date().timeIntervalSince(t0))
        }
        if Task.isCancelled { return }

        t0 = Date()
        set(.dns, .running, "Resolving names through the tunnel")
        let dns = await ProxyCurl.get("https://www.wikipedia.org", socksPort: port, timeout: 12, discardBody: true)
        if dns.httpCode > 0 {
            set(.dns, .pass, "Names resolve on the server (socks5h), nothing leaks to this network's DNS", seconds: Date().timeIntervalSince(t0))
        } else {
            set(.dns, .fail, "Name lookup through the tunnel failed", fix: "The server's DNS may be broken. On the VPS try: resolvectl query wikipedia.org", seconds: Date().timeIntervalSince(t0))
        }
        if Task.isCancelled || quick { if quick { skipRest(from: .dns, reason: "Quick test") }; return }

        t0 = Date()
        set(.latency, .running, "Measuring 5 requests")
        var times: [Double] = []
        for _ in 0..<5 {
            let r = await ProxyCurl.get("http://cp.cloudflare.com/generate_204", socksPort: port, timeout: 8, discardBody: true)
            if r.httpCode == 204 { times.append(r.timeTotal * 1000) }
        }
        if times.isEmpty {
            set(.latency, .fail, "No request completed", seconds: Date().timeIntervalSince(t0))
        } else {
            let med = times.sorted()[times.count / 2]
            set(.latency, med > 1500 ? .warn : .pass, String(format: "Median %.0f ms (%d/5)", med, times.count),
                fix: med > 1500 ? "Slow responses; the network path may be congested." : nil, seconds: Date().timeIntervalSince(t0))
        }
        if Task.isCancelled { return }

        t0 = Date()
        set(.speed, .running, "Downloading 20 MB")
        let down = await ProxyCurl.get("https://speed.cloudflare.com/__down?bytes=20000000", socksPort: port, timeout: 60, discardBody: true)
        set(.speed, .running, "Uploading 2 MB")
        let up = await ProxyCurl.get("https://speed.cloudflare.com/__up", socksPort: port, timeout: 40, discardBody: true,
                                     extra: uploadArgs())
        let dMB = down.speed / 1_000_000, uMB = up.speed / 1_000_000
        let text = String(format: "%.1f MB/s down, %.1f MB/s up", dMB, uMB)
        if down.bytes < 19_000_000 {
            set(.speed, .fail, "Download did not finish (\(Int(down.bytes / 1_000_000)) MB)", fix: "The tunnel stalls under load. Run the test again; if it repeats, check Path loss.", seconds: Date().timeIntervalSince(t0))
        } else if dMB < 1.0 {
            set(.speed, .warn, text + ". Expected 3 to 4.5 MB/s.", fix: "Far below normal. The network may be congested right now.", seconds: Date().timeIntervalSince(t0))
        } else {
            set(.speed, .pass, text, seconds: Date().timeIntervalSince(t0))
        }
        if Task.isCancelled { return }

        t0 = Date()
        set(.parallel, .running, "4 downloads at once")
        let results = await withTaskGroup(of: ProxyCurl.Response.self) { g -> [ProxyCurl.Response] in
            for _ in 0..<4 {
                g.addTask { await ProxyCurl.get("https://speed.cloudflare.com/__down?bytes=5000000", socksPort: port, timeout: 60, discardBody: true) }
            }
            var all: [ProxyCurl.Response] = []
            for await r in g { all.append(r) }
            return all
        }
        let complete = results.filter { $0.bytes >= 4_900_000 }.count
        set(.parallel, complete == 4 ? .pass : .fail, "\(complete)/4 finished",
            fix: complete == 4 ? nil : "Some transfers stalled under load.", seconds: Date().timeIntervalSince(t0))
        if Task.isCancelled { return }

        t0 = Date()
        set(.reach, .running, "Telegram, Google, YouTube, GitHub")
        let sites = ["https://web.telegram.org", "https://www.google.com", "https://www.youtube.com", "https://github.com"]
        var okSites: [String] = [], bad: [String] = []
        for site in sites {
            let r = await ProxyCurl.get(site, socksPort: port, timeout: 15, discardBody: true)
            let host = URL(string: site)!.host!.replacingOccurrences(of: "www.", with: "")
            if r.httpCode > 0, r.httpCode < 500 { okSites.append(host) } else { bad.append(host) }
        }
        set(.reach, bad.isEmpty ? .pass : (okSites.isEmpty ? .fail : .warn),
            bad.isEmpty ? "All reachable" : "Not reachable: \(bad.joined(separator: ", "))",
            fix: bad.isEmpty ? nil : "These sites may block your server's IP, or be slow right now.", seconds: Date().timeIntervalSince(t0))
    }

    private func uploadArgs() -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veil-upload.bin")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(count: 2_000_000))
        }
        return ["--data-binary", "@\(url.path)", "-H", "Content-Type: application/octet-stream"]
    }

    func report(profileName: String) -> String {
        var lines = ["Veil connection test, \(Date().formatted()), profile \(profileName)", "Result: \(summaryText)", ""]
        for s in stages {
            let mark: String
            switch s.outcome {
            case .pass: mark = "OK  "; case .warn: mark = "WARN"; case .fail: mark = "FAIL"
            case .skipped: mark = "SKIP"; case .pending, .running: mark = "    "
            }
            var l = "\(mark) \(s.title): \(s.detail)"
            if let t = s.seconds { l += String(format: " [%.1fs]", t) }
            lines.append(l)
            if let f = s.fix { lines.append("      fix: \(f)") }
        }
        return Redactor.shared.redactForReport(lines.joined(separator: "\n"))
    }
}
