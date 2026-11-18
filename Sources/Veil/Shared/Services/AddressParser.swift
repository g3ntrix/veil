import Foundation

enum AddressParser {
    struct Result: Equatable {
        var ips: [String] = []
        var sshUser: String?
    }

    static func parse(_ raw: String) -> Result {
        let text = stripPrompts(raw)
        return Result(ips: publicIPv4s(in: text), sshUser: sshUser(in: text))
    }

    static func stripPrompts(_ s: String) -> String {
        s.components(separatedBy: .newlines).map { line in
            if let r = line.range(of: #"^\s*(\[[^\]]+\]|[\w.-]+@[\w.-]+(:[^$#]*)?)\s*[$#]\s?"#, options: .regularExpression) {
                return String(line[r.upperBound...])
            }
            return line
        }.joined(separator: "\n")
    }

    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, let n = Int(p), (0...255).contains(n) else { return false }
            return !(p.count > 1 && p.hasPrefix("0"))
        }
    }

    static func isPublicIPv4(_ s: String) -> Bool {
        guard isIPv4(s) else { return false }
        let o = s.split(separator: ".").compactMap { Int($0) }
        switch (o[0], o[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false
        case (224...255, _): return false
        default: return true
        }
    }

    static func publicIPv4s(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])"#)
        var seen: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ip = String(text[Range(m.range(at: 1), in: text)!])
            if isPublicIPv4(ip), !seen.contains(ip) { seen.append(ip) }
        }
        return seen
    }

    static func sshUser(in text: String) -> String? {
        let re = try! NSRegularExpression(pattern: #"ssh\s+(?:-\S+\s+(?:\S+\s+)?)*([A-Za-z_][\w.-]*)@"#)
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

}
