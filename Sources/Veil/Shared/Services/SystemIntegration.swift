import AppKit
import CoreImage
import Foundation
import ServiceManagement
import UserNotifications

enum ProxyHelper {
    static let sudoersPath = "/etc/sudoers.d/veil-proxy"
    static let helperPath = "/usr/local/bin/veil-proxy"
    static let helperVersion = "1.0.0"

    enum HelperError: LocalizedError {
        case cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Admin permission was cancelled."
            case .failed(let m): return "Could not install the system proxy helper: \(m)"
            }
        }
    }

    static var looksInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: helperPath) && FileManager.default.fileExists(atPath: sudoersPath)
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperPath), FileManager.default.fileExists(atPath: sudoersPath) else { return false }
        let o = ProcessRunner.runSync("/usr/bin/sudo", ["-n", helperPath, "--self-check"], timeout: 5)
        return o.status == 0 && o.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == helperVersion
    }

    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        ProcessRunner.runSync("/usr/bin/sudo", ["-n", helperPath] + args, timeout: 20).status
    }

    static func install() throws {
        let script = #"""
        #!/bin/bash
        # veil-proxy: turns the macOS system proxy on or off for every network service. Installed by Veil.
        set -uo pipefail
        [ "${1:-}" = "--self-check" ] && { echo "__VERSION__"; exit 0; }
        services() { /usr/sbin/networksetup -listallnetworkservices | /usr/bin/tail -n +2 | /usr/bin/sed 's/^\*//'; }
        case "${1:-}" in
          enable)
            SOCKS="${2:?}"; HTTP="${3:?}"
            [[ "$SOCKS" =~ ^[0-9]+$ && "$HTTP" =~ ^[0-9]+$ ]] || exit 1
            services | while IFS= read -r s; do
              /usr/sbin/networksetup -setsocksfirewallproxy "$s" 127.0.0.1 "$SOCKS" off 2>/dev/null
              /usr/sbin/networksetup -setwebproxy "$s" 127.0.0.1 "$HTTP" off 2>/dev/null
              /usr/sbin/networksetup -setsecurewebproxy "$s" 127.0.0.1 "$HTTP" off 2>/dev/null
            done ;;
          disable)
            services | while IFS= read -r s; do
              /usr/sbin/networksetup -setsocksfirewallproxystate "$s" off 2>/dev/null
              /usr/sbin/networksetup -setwebproxystate "$s" off 2>/dev/null
              /usr/sbin/networksetup -setsecurewebproxystate "$s" off 2>/dev/null
            done ;;
          *) echo "usage: veil-proxy enable SOCKS_PORT HTTP_PORT | disable" >&2; exit 1 ;;
        esac
        """#.replacingOccurrences(of: "__VERSION__", with: helperVersion)
        let sudoers = "\(NSUserName()) ALL=(root) NOPASSWD: \(helperPath)\n"
        let shell = """
        set -e; mkdir -p /usr/local/bin
        echo '\(Data(script.utf8).base64EncodedString())' | /usr/bin/base64 -D > '\(helperPath)'
        chown root:wheel '\(helperPath)'; chmod 755 '\(helperPath)'
        echo '\(Data(sudoers.utf8).base64EncodedString())' | /usr/bin/base64 -D > '\(sudoersPath).tmp'
        chown root:wheel '\(sudoersPath).tmp'; chmod 440 '\(sudoersPath).tmp'
        /usr/sbin/visudo -cf '\(sudoersPath).tmp' >/dev/null && mv '\(sudoersPath).tmp' '\(sudoersPath)'
        """
        try runAsAdmin(shell, prompt: "Veil needs one-time permission to install a small helper that turns the system proxy on and off. You will not be asked again.")
    }

    static func runAsAdmin(_ shell: String, prompt: String) throws {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let src = "do shell script \"\(esc(shell))\" with administrator privileges with prompt \"\(esc(prompt))\""
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let e = err {
            if (e[NSAppleScript.errorNumber] as? Int) == -128 { throw HelperError.cancelled }
            throw HelperError.failed((e[NSAppleScript.errorMessage] as? String) ?? "unknown error")
        }
    }
}

enum SystemProxy {
    static func enable(socks: Int, http: Int) throws {
        if !ProxyHelper.isInstalled() { try ProxyHelper.install() }
        guard ProxyHelper.run(["enable", String(socks), String(http)]) == 0 else {
            throw ProxyHelper.HelperError.failed("the helper returned an error")
        }
    }

    static func disable() {
        guard ProxyHelper.isInstalled() else { return }
        ProxyHelper.run(["disable"])
    }

    static func isEnabled(socks: Int) -> Bool {
        let o = ProcessRunner.runSync("/usr/sbin/scutil", ["--proxy"], timeout: 5).stdout
        return o.contains("SOCKSEnable : 1") && o.contains("SOCKSPort : \(socks)")
    }
}

// MARK: - Launch at login

enum LaunchAtLogin {
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.g3ntrix.veil.login.plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func set(_ on: Bool) throws {
        if on {
            do {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .enabled { return }
            } catch {}
            let plist: [String: Any] = [
                "Label": "com.g3ntrix.veil.login",
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath, "--args", "--background"],
                "RunAtLoad": true,
            ]
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL)
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: agentURL)
        }
    }
}

// MARK: - Notifications (only for events the user must act on)

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}

// MARK: - QR code

enum QRCode {
    static func image(_ text: String, size: CGFloat = 220) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scale = size / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

// MARK: - Phone sharing links

enum ShareLinks {
    static func v2rayN(host: String, port: Int, user: String, pass: String, name: String = "Veil") -> String {
        let cred = Data("\(user):\(pass)".utf8).base64EncodedString()
        return "socks://\(cred)@\(host):\(port)#\(name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? name)"
    }

    static func socks5(host: String, port: Int, user: String, pass: String) -> String {
        "socks5://\(user):\(pass)@\(host):\(port)"
    }
}
