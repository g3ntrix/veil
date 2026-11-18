import Darwin
import Foundation

enum Binaries {
    static func url(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL {
            candidates.append(r.appendingPathComponent(name))
            candidates.append(r.appendingPathComponent("xray").appendingPathComponent(name))
        }
        if let dir = ProcessInfo.processInfo.environment["VEIL_BIN_DIR"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("vendor").appendingPathComponent(name))
        candidates.append(cwd.appendingPathComponent("vendor/xray").appendingPathComponent(name))
        for c in candidates {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isExecutableFile(atPath: c.path) else { continue }
            stripQuarantine(c)
            return c
        }
        return nil
    }

    static func stripQuarantine(_ url: URL) {
        let path = (url.path as NSString).fileSystemRepresentation
        _ = removexattr(path, "com.apple.quarantine", 0)
        _ = removexattr(path, "com.apple.provenance", 0)
    }
}

enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
        var elapsed: TimeInterval
    }

    static var cleanEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 30) async -> Output {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(exe, args, timeout: timeout))
            }
        }
    }

    static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval = 30) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = cleanEnvironment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let start = Date()
        do { try p.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription, elapsed: 0)
        }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        p.waitUntilExit()
        timer.cancel()
        group.wait()
        return Output(status: p.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "",
                      elapsed: Date().timeIntervalSince(start))
    }
}

enum ProxyCurl {
    struct Response {
        var ok: Bool
        var httpCode: Int
        var body: String
        var timeTotal: Double
        var bytes: Double
        var speed: Double
        var error: String
    }

    static func get(_ url: String, socksPort: Int, timeout: Int = 12, discardBody: Bool = false,
                    extra: [String] = []) async -> Response {
        var args = ["-sS", "-m", String(timeout), "-x", "socks5h://127.0.0.1:\(socksPort)",
                    "-w", "\n__VEIL__%{http_code} %{time_total} %{size_download} %{speed_download} %{size_upload}"]
        if discardBody { args += ["-o", "/dev/null"] }
        args += extra
        args.append(url)
        let o = await ProcessRunner.run("/usr/bin/curl", args, timeout: TimeInterval(timeout + 3))
        return parse(o)
    }

    static func parse(_ o: ProcessRunner.Output) -> Response {
        let parts = o.stdout.components(separatedBy: "\n__VEIL__")
        let body = parts.first ?? ""
        let stats = (parts.count > 1 ? parts[1] : "").split(separator: " ").map(String.init)
        let code = Int(stats.first ?? "") ?? 0
        let t = Double(stats.count > 1 ? stats[1] : "") ?? 0
        let size = Double(stats.count > 2 ? stats[2] : "") ?? 0
        let speed = Double(stats.count > 3 ? stats[3] : "") ?? 0
        let up = Double(stats.count > 4 ? stats[4] : "") ?? 0
        return Response(ok: o.status == 0 && code > 0, httpCode: code, body: discardMarker(body), timeTotal: t,
                        bytes: max(size, up), speed: speed,
                        error: o.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func discardMarker(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
