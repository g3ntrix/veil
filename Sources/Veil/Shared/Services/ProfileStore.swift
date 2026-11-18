import Foundation

enum ProfileStore {
    static var url: URL { AppPaths.support.appendingPathComponent("profiles.json") }

    static func load() -> [ServerProfile] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ServerProfile].self, from: d)) ?? []
    }

    static func save(_ profiles: [ServerProfile]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(profiles).write(to: url, options: .atomic)
    }
}

enum ProfileTransfer {
    static let fileExtension = "veilprofile"

    struct File: Codable {
        var format = "veil-profile"
        var version = 1
        var warning = "This file contains the keys to your Veil server. Anyone with it can use your server. Do not share it."
        var profile: ServerProfile
        var secrets: ProfileSecrets
    }

    static func export(_ p: ServerProfile, _ s: ProfileSecrets) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(File(profile: p, secrets: s))
    }

    enum ImportError: LocalizedError {
        case notVeil
        var errorDescription: String? { "This is not a Veil profile file." }
    }

    static func `import`(_ data: Data) throws -> (ServerProfile, ProfileSecrets) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(File.self, from: data), f.format == "veil-profile" else { throw ImportError.notVeil }
        var p = f.profile
        p.id = UUID()
        p.name += " (imported)"
        return (p, f.secrets)
    }
}

struct WizardProgress: Codable, Equatable {
    var step: Int = 0
    var draftProfileID: UUID?

    static var url: URL { AppPaths.support.appendingPathComponent("wizard.json") }
    static func load() -> WizardProgress {
        (try? JSONDecoder().decode(WizardProgress.self, from: Data(contentsOf: url))) ?? WizardProgress()
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic) }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

struct AppPreferences: Codable, Equatable {
    var activeProfileID: UUID?
    var wizardComplete = false
    var systemProxy = false
    var lanSharing = false
    var connectOnLaunch = false
    var lanLinkStyle = 0
    var tunnel = TunnelSettings.default
    var theme = 0
    var lastLanIP: String?
    var checkUpdates = true

    static var url: URL { AppPaths.support.appendingPathComponent("settings.json") }
    static func load() -> AppPreferences {
        (try? JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))) ?? AppPreferences()
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic) }
}
