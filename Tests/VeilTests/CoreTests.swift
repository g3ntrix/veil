import CoreImage
import Foundation
import XCTest
@testable import Veil

final class CoreTests: XCTestCase {
    func testPasswordAlphabetAndLength() {
        let p = SecretGenerator.password(length: 24)
        XCTAssertEqual(p.count, 24)
        XCTAssertTrue(p.allSatisfy { $0.isLetter || $0.isNumber })
        XCTAssertNotEqual(p, SecretGenerator.password(length: 24))
    }

    func testSelfSignedCertificateParsesAndPinMatches() throws {
        let c = try SelfSignedCertificate.make(commonName: "www.bing.com")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let certURL = dir.appendingPathComponent("c.pem"), keyURL = dir.appendingPathComponent("k.pem")
        try c.certPEM.write(to: certURL, atomically: true, encoding: .utf8)
        try c.keyPEM.write(to: keyURL, atomically: true, encoding: .utf8)
        let text = ProcessRunner.runSync("/usr/bin/openssl", ["x509", "-in", certURL.path, "-noout", "-text"])
        XCTAssertEqual(text.status, 0, text.stderr)
        XCTAssertTrue(text.stdout.contains("www.bing.com"))
        XCTAssertTrue(text.stdout.contains("DNS:www.bing.com"))
        let verify = ProcessRunner.runSync("/usr/bin/openssl", ["verify", "-CAfile", certURL.path, certURL.path])
        XCTAssertTrue(verify.stdout.contains("OK"), verify.stdout + verify.stderr)
        let key = ProcessRunner.runSync("/usr/bin/openssl", ["pkey", "-in", keyURL.path, "-noout"])
        XCTAssertEqual(key.status, 0, key.stderr)
        let der = ProcessRunner.runSync("/bin/sh", ["-c", "/usr/bin/openssl x509 -in '\(certURL.path)' -outform der | /usr/bin/shasum -a 256"])
        XCTAssertEqual(String(der.stdout.prefix(64)), c.sha256Hex)
    }

    func testGzipRoundTrip() throws {
        let s = String(repeating: "veil relay test\n", count: 500)
        let gz = Gzip.compress(Data(s.utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gz")
        try gz.write(to: url)
        let out = ProcessRunner.runSync("/usr/bin/gunzip", ["-c", url.path])
        XCTAssertEqual(out.stdout, s)
    }

    func testInstallScriptRendersWithoutPlaceholders() throws {
        let secrets = try SecretGenerator.newSecrets()
        let p = ServerProfile(name: "Test", address: "203.0.113.7")
        let script = try ServerScript.installScript(profile: p, secrets: secrets)
        XCTAssertFalse(script.contains("__"), "unfilled placeholder")
        XCTAssertTrue(script.contains(secrets.hysteriaPassword))
        let check = ProcessRunner.runSync("/bin/bash", ["-n", "-c", script])
        XCTAssertEqual(check.status, 0, check.stderr)
        XCTAssertEqual(script, try ServerScript.installScript(profile: p, secrets: secrets))
        let cmd = try ServerScript.installCommand(profile: p, secrets: secrets)
        XCTAssertTrue(cmd.hasPrefix("t=$(mktemp)"))
        XCTAssertLessThan(cmd.count, 12_000)
    }

    func testOneLinerDecodesToScript() throws {
        let script = "#!/bin/bash\necho hello-veil\n"
        let cmd = ServerScript.oneLiner(for: script)
        let b64 = cmd.components(separatedBy: "'")[1]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gz")
        try Data(base64Encoded: b64)!.write(to: url)
        XCTAssertEqual(ProcessRunner.runSync("/usr/bin/gunzip", ["-c", url.path]).stdout, script)
    }

    func testXrayConfigShape() throws {
        let s = ProfileSecrets(hysteriaPassword: "hp", obfsPassword: "op", certPEM: "", keyPEM: "", certPin: "ab", lanPassword: "lp")
        let cfg = XrayConfigBuilder.config(secrets: s, settings: .default, lan: .init(user: "phone", password: "lp"))
        let inbounds = cfg["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.map { $0["port"] as! Int }, [10808, 10809, 10810, 10811])
        XCTAssertEqual(inbounds[3]["listen"] as? String, "0.0.0.0")
        let out = (cfg["outbounds"] as! [[String: Any]])[0]
        XCTAssertEqual(out["protocol"] as? String, "hysteria")
        let st = out["streamSettings"] as! [String: Any]
        let tls = st["tlsSettings"] as! [String: Any]
        XCTAssertEqual(tls["serverName"] as? String, "www.bing.com")
        XCTAssertEqual(tls["pinnedPeerCertSha256"] as? String, "ab")
        let fm = st["finalmask"] as! [String: Any]
        let q = fm["quicParams"] as! [String: Any]
        XCTAssertEqual(q["brutalUp"] as? String, "20mbps")
        XCTAssertEqual(q["brutalDown"] as? String, "60mbps")
        let settings = out["settings"] as! [String: Any]
        XCTAssertEqual(settings["port"] as? Int, 18095)
        XCTAssertEqual(settings["address"] as? String, "127.0.0.1")
    }

    func testXrayAcceptsConfig() throws {
        guard let xray = Binaries.url("xray") else { throw XCTSkip("xray not in bundle/") }
        let secrets = try SecretGenerator.newSecrets()
        let data = try XrayConfigBuilder.json(secrets: secrets, settings: .default, lan: .init(user: "phone", password: "x"))
        let url = try XrayConfigBuilder.writeTemp(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let o = ProcessRunner.runSync(xray.path, ["run", "-test", "-c", url.path], timeout: 20)
        XCTAssertEqual(o.status, 0, o.stdout + o.stderr)
    }
}

final class AddressParserTests: XCTestCase {
    func testFindsPublicIPAndUser() {
        let r = AddressParser.parse("ubuntu@instance-1:~$ ssh ubuntu@203.0.113.9\nlocal 192.168.1.5 and 10.0.0.2")
        XCTAssertEqual(r.ips, ["203.0.113.9"])
        XCTAssertEqual(r.sshUser, "ubuntu")
    }

    func testStripsPrompts() {
        XCTAssertEqual(AddressParser.stripPrompts("root@vps:~# ls -la"), "ls -la")
        XCTAssertEqual(AddressParser.stripPrompts("[opc@host ~]$ uname"), "uname")
    }

    func testRejectsBadIPs() {
        XCTAssertFalse(AddressParser.isIPv4("256.1.1.1"))
        XCTAssertFalse(AddressParser.isIPv4("01.2.3.4"))
        XCTAssertFalse(AddressParser.isPublicIPv4("172.20.1.1"))
        XCTAssertFalse(AddressParser.isPublicIPv4("100.70.0.1"))
        XCTAssertTrue(AddressParser.isPublicIPv4("8.8.8.8"))
    }

    func testRedactorMasks() {
        let s = ProfileSecrets(hysteriaPassword: "SECRETpass123", obfsPassword: "OBFSpass456", certPin: "", lanPassword: "")
        Redactor.shared.register(s)
        let r = Redactor.shared.redactForReport("auth SECRETpass123 to 203.0.113.9")
        XCTAssertFalse(r.contains("SECRETpass123"))
        XCTAssertTrue(r.contains("203.0.x.x"))
    }
}

private extension ProfileSecrets {
    init(hysteriaPassword: String, obfsPassword: String, certPin: String, lanPassword: String) {
        self.init(hysteriaPassword: hysteriaPassword, obfsPassword: obfsPassword, certPEM: "", keyPEM: "", certPin: certPin, lanPassword: lanPassword)
    }
}

final class ReachabilityTests: XCTestCase {
    func testTCPProbe() async throws {
        let unreachable = await TCPProbe.reachable(host: "203.0.113.10", port: 22, timeout: 2)
        XCTAssertFalse(unreachable)
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let reachable = await TCPProbe.reachable(host: "127.0.0.1", port: Int(UInt16(bigEndian: addr.sin_port)), timeout: 2)
        close(listener)
        XCTAssertTrue(reachable)
    }
}

final class DonateTests: XCTestCase {
    func testQRCodesDecodeToAddresses() throws {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
        for coin in DonateView.coins {
            let img = try XCTUnwrap(QRCode.image(coin.address, size: 300))
            let cg = try XCTUnwrap(img.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(found, [coin.address], coin.name)
        }
    }
}
