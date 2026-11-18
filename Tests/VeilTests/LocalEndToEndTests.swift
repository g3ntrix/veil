import Foundation
import XCTest
@testable import Veil

@MainActor
final class LocalEndToEndTests: XCTestCase {
    var procs: [Process] = []

    override func tearDown() async throws {
        for p in procs where p.isRunning { p.terminate() }
    }

    func spawn(_ exe: String, _ args: [String], log: URL) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ProcessRunner.cleanEnvironment
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = try FileHandle(forWritingTo: log)
        p.standardOutput = h
        p.standardError = h
        try p.run()
        procs.append(p)
        return p
    }

    func testTunnelEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["VEIL_E2E"] == "1" else { throw XCTSkip("set VEIL_E2E=1") }
        let hysteria = "/opt/homebrew/bin/hysteria"
        guard FileManager.default.isExecutableFile(atPath: hysteria) else { throw XCTSkip("no hysteria") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-e2e-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let secrets = try SecretGenerator.newSecrets()
        try secrets.certPEM.write(to: dir.appendingPathComponent("cert.pem"), atomically: true, encoding: .utf8)
        try secrets.keyPEM.write(to: dir.appendingPathComponent("key.pem"), atomically: true, encoding: .utf8)
        let hyPort = 22095, relayPort = 22100, webPort = 22180
        let yaml = """
        listen: 127.0.0.1:\(hyPort)
        tls:
          cert: \(dir.path)/cert.pem
          key: \(dir.path)/key.pem
        auth:
          type: password
          password: "\(secrets.hysteriaPassword)"
        obfs:
          type: salamander
          salamander:
            password: "\(secrets.obfsPassword)"
        """
        try yaml.write(to: dir.appendingPathComponent("hy.yaml"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("blob").path, contents: Data(count: 8_000_000))

        _ = try spawn(hysteria, ["server", "--config", dir.appendingPathComponent("hy.yaml").path], log: dir.appendingPathComponent("hy.log"))
        let relayScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Server/gate.py").standardized.path
        _ = try spawn("/usr/bin/python3", ["-I", relayScript, String(relayPort), String(hyPort)], log: dir.appendingPathComponent("relay.log"))
        _ = try spawn("/usr/bin/python3", ["-m", "http.server", String(webPort), "--bind", "127.0.0.1", "--directory", dir.path], log: dir.appendingPathComponent("web.log"))
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let probe = await RelayProbe.run(server: "127.0.0.1", port: relayPort, count: 40, rotate: 22, intervalMs: 5, waitMs: 800)
        XCTAssertEqual(probe?.received, 40)
        XCTAssertEqual(probe?.relayVersion, Versions.serverRelay)
        XCTAssertEqual(probe?.hysteria, true)

        var settings = TunnelSettings.default
        settings.socksPort = 21808; settings.socks2Port = 21809; settings.httpPort = 21810; settings.lanPort = 21811
        settings.relayLocalPort = 21895
        let profile = ServerProfile(name: "local", address: "127.0.0.1", relayPort: relayPort)
        let engine = TunnelEngine()
        var logs: [String] = []
        engine.onLog = { src, line in logs.append("\(src): \(line)") }
        try await engine.start(profile: profile, secrets: secrets, settings: settings, lan: nil)
        XCTAssertTrue(engine.relayRunning && engine.xrayRunning)

        let r = await ProxyCurl.get("http://127.0.0.1:\(webPort)/blob", socksPort: settings.socksPort, timeout: 30, discardBody: true)
        XCTAssertEqual(r.httpCode, 200, "logs:\n" + logs.joined(separator: "\n"))
        XCTAssertEqual(Int(r.bytes), 8_000_000)
        print(String(format: "E2E: 8 MB through the tunnel in %.2f s (%.1f MB/s)", r.timeTotal, r.speed / 1e6))

        let h = await ProcessRunner.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-x", "http://127.0.0.1:\(settings.httpPort)", "http://127.0.0.1:\(webPort)/"])
        XCTAssertEqual(h.stdout, "200")

        await engine.stop()
        var bad = secrets
        bad.hysteriaPassword = "wrong-password-123"
        try await engine.start(profile: profile, secrets: bad, settings: settings, lan: nil)
        let r2 = await ProxyCurl.get("http://127.0.0.1:\(webPort)/", socksPort: settings.socksPort, timeout: 8, discardBody: true)
        XCTAssertNotEqual(r2.httpCode, 200)
        await engine.stop()
        XCTAssertFalse(engine.relayRunning || engine.xrayRunning)
        XCTAssertTrue(Ports.tcpFree(settings.socksPort))
    }
}
