import CryptoKit
import Foundation
import Security

enum SecretGenerator {
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    static func password(length: Int = 24) -> String {
        var out = ""
        var bytes = [UInt8](repeating: 0, count: length * 2)
        while out.count < length {
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            for b in bytes where out.count < length {
                let limit = UInt8(256 - 256 % alphabet.count)
                if b < limit { out.append(alphabet[Int(b) % alphabet.count]) }
            }
        }
        return out
    }

    static func newSecrets(sni: String = TunnelSettings.default.sni) throws -> ProfileSecrets {
        let cert = try SelfSignedCertificate.make(commonName: sni)
        return ProfileSecrets(
            hysteriaPassword: password(),
            obfsPassword: password(),
            certPEM: cert.certPEM,
            keyPEM: cert.keyPEM,
            certPin: cert.sha256Hex,
            lanPassword: password(length: 16)
        )
    }
}

enum SelfSignedCertificate {
    struct Result {
        let der: Data
        let certPEM: String
        let keyPEM: String
        let sha256Hex: String
    }

    static func make(commonName: String, validYears: Int = 10, now: Date = Date()) throws -> Result {
        let key = P256.Signing.PrivateKey()
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        if serial[0] == 0 { serial[0] = 1 }

        let ecdsaWithSHA256 = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8(commonName)])])])
        let notBefore = now.addingTimeInterval(-86400)
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: validYears, to: now)!
        let validity = DER.sequence([DER.utcTime(notBefore), DER.utcTime(notAfter)])
        let spki = DER.sequence([
            DER.sequence([DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])]),
            DER.bitString(key.publicKey.x963Representation),
        ])
        let san = DER.sequence([DER.tagged(0x82, Data(commonName.utf8))])
        let extensions = DER.tagged(0xA3, DER.sequence([
            DER.sequence([DER.oid([2, 5, 29, 17]), DER.octetString(san)]),
        ]))
        let tbs = DER.sequence([
            DER.tagged(0xA0, DER.integer(Data([2]))),
            DER.integer(Data(serial)),
            ecdsaWithSHA256,
            name,
            validity,
            name,
            spki,
            extensions,
        ])
        let signature = try key.signature(for: tbs).derRepresentation
        let cert = DER.sequence([tbs, ecdsaWithSHA256, DER.bitString(signature)])

        let hex = SHA256.hash(data: cert).map { String(format: "%02x", $0) }.joined()
        return Result(der: cert, certPEM: pem(cert, label: "CERTIFICATE"), keyPEM: key.pemRepresentation + "\n", sha256Hex: hex)
    }

    static func pem(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }
}

enum DER {
    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func tagged(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func sequence(_ items: [Data]) -> Data { tagged(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tagged(0x31, items.reduce(Data(), +)) }
    static func integer(_ bytes: Data) -> Data {
        var b = bytes
        if let f = b.first, f & 0x80 != 0 { b.insert(0, at: 0) }
        return tagged(0x02, b)
    }
    static func bitString(_ bytes: Data) -> Data { tagged(0x03, Data([0]) + bytes) }
    static func octetString(_ bytes: Data) -> Data { tagged(0x04, bytes) }
    static func utf8(_ s: String) -> Data { tagged(0x0C, Data(s.utf8)) }
    static func utcTime(_ d: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(f.string(from: d).utf8))
    }
    static func oid(_ parts: [UInt]) -> Data {
        var out = Data([UInt8(parts[0] * 40 + parts[1])])
        for p in parts.dropFirst(2) {
            var stack: [UInt8] = [UInt8(p & 0x7F)]
            var v = p >> 7
            while v > 0 { stack.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out.append(contentsOf: stack)
        }
        return tagged(0x06, out)
    }
}
