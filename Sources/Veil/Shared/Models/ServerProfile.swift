import Foundation

struct ServerProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var address: String
    var sshUser: String = "ubuntu"
    var relayPort: Int = 2100
    var created: Date = Date()
    var installedVersion: Int?
    var lastCheck: CheckSummary?

    struct CheckSummary: Codable, Equatable, Hashable {
        var date: Date
        var ok: Bool
        var note: String
    }

    var sshCommand: String { "ssh \(sshUser)@\(address)" }
}

struct ProfileSecrets: Codable, Equatable {
    var hysteriaPassword: String
    var obfsPassword: String
    var certPEM: String
    var keyPEM: String
    var certPin: String
    var lanPassword: String
}

struct TunnelSettings: Codable, Equatable {
    var socksPort = 10808
    var socks2Port = 10809
    var httpPort = 10810
    var lanPort = 10811
    var relayLocalPort = 18095
    var rotateEvery = 22
    var keepOldSocketsSeconds = 8
    var brutalUpMbps = 20
    var brutalDownMbps = 60
    var sni = "www.bing.com"
    var lanUser = "phone"

    static let `default` = TunnelSettings()
}

enum Versions {
    static let serverScripts = 1
    static let serverRelay = 2
}
