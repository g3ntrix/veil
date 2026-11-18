import Foundation

enum ServerScript {
    enum ScriptError: LocalizedError {
        case missingTemplate(String)
        var errorDescription: String? {
            switch self { case .missingTemplate(let n): return "Server template \(n) is missing from the app bundle." }
        }
    }

    static func template(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Server"),
              let s = try? String(contentsOf: url, encoding: .utf8)
        else { throw ScriptError.missingTemplate(name) }
        return s
    }

    static func installScript(profile: ServerProfile, secrets: ProfileSecrets) throws -> String {
        let relay = try template("gate.py")
        let b64 = { (s: String) in Data(s.utf8).base64EncodedString() }
        return try template("install.sh")
            .replacingOccurrences(of: "__SCRIPTS_VERSION__", with: String(Versions.serverScripts))
            .replacingOccurrences(of: "__PROFILE_ID__", with: profile.id.uuidString)
            .replacingOccurrences(of: "__RELAY_PORT__", with: String(profile.relayPort))
            .replacingOccurrences(of: "__HY_PASSWORD__", with: secrets.hysteriaPassword)
            .replacingOccurrences(of: "__OBFS_PASSWORD__", with: secrets.obfsPassword)
            .replacingOccurrences(of: "__CERT_PEM_B64__", with: b64(secrets.certPEM))
            .replacingOccurrences(of: "__KEY_PEM_B64__", with: b64(secrets.keyPEM))
            .replacingOccurrences(of: "__RELAY_PY_B64__", with: b64(relay))
    }


    static func oneLiner(for script: String, args: String = "") -> String {
        let payload = Gzip.compress(Data(script.utf8)).base64EncodedString()
        let a = args.isEmpty ? "" : " \(args)"
        return "t=$(mktemp) && echo '\(payload)' | base64 -d | gunzip > \"$t\" && $([ \"$(id -u)\" -eq 0 ] || echo sudo) bash \"$t\"\(a); rm -f \"$t\""
    }

    static func installCommand(profile: ServerProfile, secrets: ProfileSecrets) throws -> String {
        oneLiner(for: try installScript(profile: profile, secrets: secrets))
    }


    static let uninstallCommand = "sudo veil-server --uninstall"
}

enum Gzip {
    static func compress(_ data: Data) -> Data {
        let deflated = (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
