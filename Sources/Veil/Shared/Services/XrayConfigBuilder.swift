import Foundation

enum XrayConfigBuilder {
    struct LAN: Equatable {
        var user: String
        var password: String
    }

    static func config(secrets: ProfileSecrets, settings: TunnelSettings, lan: LAN?) -> [String: Any] {
        let sniff: [String: Any] = ["enabled": true, "destOverride": ["http", "tls"]]
        var inbounds: [[String: Any]] = [
            ["tag": "socks", "port": settings.socksPort, "listen": "127.0.0.1", "protocol": "socks",
             "settings": ["udp": true], "sniffing": sniff],
            ["tag": "socks2", "port": settings.socks2Port, "listen": "127.0.0.1", "protocol": "socks",
             "settings": ["udp": true], "sniffing": sniff],
            ["tag": "http", "port": settings.httpPort, "listen": "127.0.0.1", "protocol": "http"],
        ]
        if let lan {
            inbounds.append([
                "tag": "lan", "port": settings.lanPort, "listen": "0.0.0.0", "protocol": "socks",
                "settings": ["auth": "password", "accounts": [["user": lan.user, "pass": lan.password]], "udp": true],
                "sniffing": sniff,
            ])
        }
        let outbound: [String: Any] = [
            "tag": "proxy",
            "protocol": "hysteria",
            "settings": ["version": 2, "address": "127.0.0.1", "port": settings.relayLocalPort],
            "streamSettings": [
                "network": "hysteria",
                "hysteriaSettings": ["version": 2, "auth": secrets.hysteriaPassword],
                "security": "tls",
                "tlsSettings": [
                    "serverName": settings.sni,
                    "pinnedPeerCertSha256": secrets.certPin,
                    "alpn": ["h3"],
                ],
                "finalmask": [
                    "udp": [["type": "salamander", "settings": ["password": secrets.obfsPassword]]],
                    "quicParams": [
                        "congestion": "brutal",
                        "brutalUp": "\(settings.brutalUpMbps)mbps",
                        "brutalDown": "\(settings.brutalDownMbps)mbps",
                    ],
                ],
            ],
        ]
        return [
            "log": ["loglevel": "warning"],
            "inbounds": inbounds,
            "outbounds": [outbound],
        ]
    }

    static func json(secrets: ProfileSecrets, settings: TunnelSettings, lan: LAN?) throws -> Data {
        try JSONSerialization.data(withJSONObject: config(secrets: secrets, settings: settings, lan: lan),
                                   options: [.prettyPrinted, .sortedKeys])
    }

    static func writeTemp(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("xray-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
