import Foundation

enum Brand {
    static let name = "Veil"
    static let bundleID = "com.g3ntrix.veil"
    static let developer = "g3ntrix"
    static var developerURL: URL { URL(string: "https://github.com/\(developer)")! }
    static let license = "GPL-3.0"
    static var licenseURL: URL { URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")! }
}
