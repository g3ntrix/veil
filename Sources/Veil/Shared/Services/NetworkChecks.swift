import AppKit
import Darwin
import Foundation
import Network

// MARK: - Ports

enum Ports {
    static func tcpFree(_ port: Int, host: String = "127.0.0.1") -> Bool { canBind(port, host: host, type: SOCK_STREAM) }
    static func udpFree(_ port: Int, host: String = "127.0.0.1") -> Bool { canBind(port, host: host, type: SOCK_DGRAM) }

    private static func canBind(_ port: Int, host: String, type: Int32) -> Bool {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if type == SOCK_STREAM {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }

    static func tcpListening(_ port: Int) -> Bool { TCPProbe.connectSync(host: "127.0.0.1", port: port, timeout: 1) }

    struct Holder: Equatable {
        var pid: Int32
        var command: String
        var appName: String?
        var display: String { appName.map { "\($0) (\(command), PID \(pid))" } ?? "\(command) (PID \(pid))" }
    }

    static func tcpHolder(_ port: Int) -> Holder? {
        let o = ProcessRunner.runSync("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"], timeout: 5)
        var pid: Int32?
        var cmd = ""
        for line in o.stdout.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), cmd.isEmpty { cmd = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return Holder(pid: pid, command: cmd, appName: owningApp(pid))
    }

    static func udpHolder(_ port: Int) -> Holder? {
        let o = ProcessRunner.runSync("/usr/sbin/lsof", ["-nP", "-iUDP:\(port)", "-Fpc"], timeout: 5)
        var pid: Int32?
        var cmd = ""
        for line in o.stdout.split(separator: "\n") {
            if line.hasPrefix("p"), pid == nil { pid = Int32(line.dropFirst()) }
            if line.hasPrefix("c"), cmd.isEmpty { cmd = String(line.dropFirst()) }
        }
        guard let pid else { return nil }
        return Holder(pid: pid, command: cmd, appName: owningApp(pid))
    }

    static func owningApp(_ pid: Int32) -> String? {
        var cur = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: cur), let name = app.localizedName,
               app.bundleURL?.pathExtension == "app" {
                return name
            }
            let o = ProcessRunner.runSync("/bin/ps", ["-o", "ppid=", "-p", String(cur)], timeout: 3)
            guard let ppid = Int32(o.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), ppid > 1 else { return nil }
            cur = ppid
        }
        return nil
    }

    static func stop(_ h: Holder) {
        if let name = h.appName,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            app.terminate()
        } else {
            kill(h.pid, SIGTERM)
        }
    }
}

// MARK: - TCP reachability (SSH on the VPS)

enum TCPProbe {
    static func reachable(host: String, port: Int, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let ip = EgressInfo.resolveIPv4(host).first ?? host
                cont.resume(returning: connectNonBlocking(ip: ip, port: port, timeout: timeout))
            }
        }
    }

    private static func connectNonBlocking(ip: String, port: Int, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    static func connectSync(host: String, port: Int, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

// MARK: - Relay probe (relayd probe)

struct RelayProbeResult: Codable, Equatable {
    var sent: Int
    var received: Int
    var receivedAfter30: Int
    var lossPercent: Double
    var rttMedianMs: Double
    var rttMinMs: Double
    var rttMaxMs: Double
    var serverVersion: String?
    var hysteria: Bool?
    var sourcePorts: Int
    var error: String?

    var answered: Bool { received > 0 }
    var relayVersion: Int? { serverVersion.flatMap(Int.init) }
}

enum RelayProbe {
    static func run(server: String, port: Int, count: Int = 4, rotate: Int = 22,
                    intervalMs: Int = 25, waitMs: Int = 1500) async -> RelayProbeResult? {
        guard let relayd = Binaries.url("relayd") else { return nil }
        let o = await ProcessRunner.run(relayd.path, [
            "probe", "--server", server, "--port", String(port), "--count", String(count),
            "--rotate", String(rotate), "--interval", "\(intervalMs)ms", "--wait", "\(waitMs)ms",
        ], timeout: Double(count * intervalMs + waitMs) / 1000 + 10)
        return try? JSONDecoder().decode(RelayProbeResult.self, from: Data(o.stdout.utf8))
    }
}

// MARK: - Network doctor (is UDP usable here?)

enum NetworkDoctor {
    struct Report: Equatable {
        var resolversAnswered: [String]
        var resolversTried: [String]
        var udpWorks: Bool { !resolversAnswered.isEmpty }
    }

    static let resolvers = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]

    static func run() async -> Report {
        var ok: [String] = []
        await withTaskGroup(of: (String, Bool).self) { g in
            for r in resolvers { g.addTask { (r, await dnsOverUDP(r)) } }
            for await (r, v) in g where v { ok.append(r) }
        }
        return Report(resolversAnswered: ok.sorted(), resolversTried: resolvers)
    }

    static func dnsOverUDP(_ server: String, timeout: TimeInterval = 3) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
            let lock = NSLock()
            var done = false
            func finish(_ v: Bool) {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                done = true
                conn.cancel()
                cont.resume(returning: v)
            }
            let id = UInt16.random(in: 1...0xFFFE)
            let q: Data = {
                var q = Data([UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
                for label in ["example", "com"] { q.append(UInt8(label.count)); q.append(contentsOf: label.utf8) }
                q.append(contentsOf: [0, 0, 1, 0, 1])
                return q
            }()
            conn.stateUpdateHandler = { st in
                if case .ready = st {
                    conn.send(content: q, completion: .contentProcessed { _ in })
                    conn.receiveMessage { data, _, _, _ in
                        if let d = data, d.count >= 2, d[0] == UInt8(id >> 8), d[1] == UInt8(id & 0xFF) { finish(true) }
                        else { finish(false) }
                    }
                } else if case .failed = st { finish(false) }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

// MARK: - Egress IP and location

enum EgressInfo {
    struct Egress: Equatable {
        var ip: String
        var country: String?
        var city: String?
        var org: String?
    }

    static func exitIP(socksPort: Int) async -> String? {
        let r = await ProxyCurl.get("https://api.ipify.org", socksPort: socksPort, timeout: 10)
        let ip = r.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.httpCode == 200 && AddressParser.isIPv4(ip) ? ip : nil
    }

    static func details(socksPort: Int) async -> Egress? {
        let r = await ProxyCurl.get("https://ipinfo.io/json", socksPort: socksPort, timeout: 10)
        guard r.httpCode == 200, let obj = try? JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any],
              let ip = obj["ip"] as? String else { return nil }
        return Egress(ip: ip, country: obj["country"] as? String, city: obj["city"] as? String, org: obj["org"] as? String)
    }

    static func resolveIPv4(_ host: String) -> [String] {
        if AddressParser.isIPv4(host) { return [host] }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let cur = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(cur.pointee.ai_addr, cur.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                if !out.contains(s) { out.append(s) }
            }
            p = cur.pointee.ai_next
        }
        return out
    }
}

// MARK: - LAN address

enum LanAddress {
    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let s = String(cString: buf)
            if s != "127.0.0.1", !s.hasPrefix("169.254.") { candidates.append((name, s)) }
        }
        return candidates.sorted { $0.0 < $1.0 }.first?.1
    }
}
