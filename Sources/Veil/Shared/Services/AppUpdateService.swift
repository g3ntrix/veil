import Foundation

enum AppUpdateService {
    static let releasesRepo = "g3ntrix/veil-releases"
    static var latestURL: URL { URL(string: "https://api.github.com/repos/\(releasesRepo)/releases/latest")! }
    static var releasesPage: URL { URL(string: "https://github.com/\(releasesRepo)/releases")! }

    struct Release: Equatable {
        var version: String
        var notes: String
        var page: URL
        var dmg: URL?
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func latest() async throws -> Release {
        var req = URLRequest(url: latestURL)
        req.setValue("Veil macOS updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
        else { throw URLError(.badServerResponse) }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        return Release(version: normalized(tag), notes: obj["body"] as? String ?? "", page: page, dmg: dmg.flatMap(URL.init(string:)))
    }

    static func normalized(_ v: String) -> String {
        let t = v.trimmingCharacters(in: .whitespaces)
        return t.lowercased().hasPrefix("v") ? String(t.dropFirst()) : t
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = normalized(a).split { !$0.isNumber }.map { Int($0) ?? 0 }
        let pb = normalized(b).split { !$0.isNumber }.map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
