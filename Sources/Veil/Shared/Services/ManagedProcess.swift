import Darwin
import Foundation

final class ManagedProcess {
    let name: String
    private(set) var process: Process?
    var onLine: ((String) -> Void)?
    var onExit: ((Int32, Bool) -> Void)?
    private var buffer = Data()
    private var stopRequested = false

    init(name: String) { self.name = name }

    var pid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }
    var isRunning: Bool { process?.isRunning ?? false }

    func launch(_ exe: URL, _ args: [String]) throws {
        stopRequested = false
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.environment = ProcessRunner.cleanEnvironment
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { return }
            self.consume(d)
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            let requested = self.stopRequested
            DispatchQueue.main.async { self.onExit?(proc.terminationStatus, requested) }
        }
        try p.run()
        process = p
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(data: buffer[buffer.startIndex..<nl], encoding: .utf8) ?? ""
            buffer.removeSubrange(buffer.startIndex...nl)
            let cb = onLine
            DispatchQueue.main.async { cb?(line) }
        }
    }

    func stop(grace: TimeInterval = 2) async {
        guard let p = process, p.isRunning else { process = nil; return }
        stopRequested = true
        p.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while p.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
    }

    func stopSync() {
        guard let p = process, p.isRunning else { return }
        stopRequested = true
        p.terminate()
        let deadline = Date().addingTimeInterval(1.5)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
}

enum RunRecord {
    static var url: URL { AppPaths.support.appendingPathComponent("running.json") }

    static func save(_ pids: [Int32]) {
        try? JSONEncoder().encode(pids).write(to: url)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    static func killLeftovers() {
        guard let data = try? Data(contentsOf: url), let pids = try? JSONDecoder().decode([Int32].self, from: data) else { return }
        for pid in pids where ["xray", "relayd"].contains(processName(pid)) {
            kill(pid, SIGTERM)
        }
        clear()
    }

    static func processName(_ pid: Int32) -> String? {
        let o = ProcessRunner.runSync("/bin/ps", ["-p", String(pid), "-o", "comm="], timeout: 3)
        let path = o.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path).lastPathComponent
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Veil", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class Redactor {
    static let shared = Redactor()
    private var secrets: Set<String> = []
    private let lock = NSLock()

    func register(_ s: ProfileSecrets) {
        lock.lock(); defer { lock.unlock() }
        for v in [s.hysteriaPassword, s.obfsPassword, s.certPin, s.lanPassword] where v.count >= 6 { secrets.insert(v) }
    }

    func redact(_ text: String) -> String {
        lock.lock(); let list = secrets; lock.unlock()
        var t = text
        for s in list { t = t.replacingOccurrences(of: s, with: "‹redacted›") }
        return t
    }

    func redactForReport(_ text: String) -> String {
        let t = redact(text)
        let re = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}(?![\d.])"#)
        return re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1.x.x")
    }
}
