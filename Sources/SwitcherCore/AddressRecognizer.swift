import Foundation

/// Offline syntax recognition. Never resolves DNS, opens URLs or retains input.
public final class AddressRecognizer {
    public static let shared = AddressRecognizer()
    private let tlds: Set<String>
    public var available: Bool { tlds.contains("ru") && tlds.contains("com") && tlds.count > 1000 }
    public var zoneCount: Int { tlds.count }

    public init(directory: URL? = nil) {
        let app = Bundle.main.bundleURL.pathExtension == "app"
        let root = directory ?? (app ? Bundle.main.resourceURL?.appendingPathComponent("Dictionaries") :
            Bundle.module.url(forResource: "Dictionaries", withExtension: nil))
        let text = root.flatMap { try? String(contentsOf: $0.appendingPathComponent("iana_tlds.txt"), encoding: .utf8) } ?? ""
        tlds = Set(text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.lowercased() })
    }

    public func recognizes(_ text: String) -> Bool {
        guard available, (3...128).contains(text.utf16.count),
              text.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              !text.contains("\\"), !text.contains("<"), !text.contains(">"), !text.contains("\"") else { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("mailto:") { return recognizes(String(text.dropFirst(7))) }
        let schemeEnd = text.range(of: "://")
        let explicit = schemeEnd != nil
        if let schemeEnd {
            let scheme = text[..<schemeEnd.lowerBound]
            guard scheme.first?.isLetter == true, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return false }
        }
        if text.contains("@") && !explicit {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let local = parts[0]
            let allowed = "!#$%&'*+-/=?^_`{|}~."
            guard !local.isEmpty, local.utf8.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."),
                  !local.contains(".."), local.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || allowed.contains($0)) }) else { return false }
            return domain(String(parts[1]), allowLocal: false)
        }
        let authority = (schemeEnd.map { String(text[$0.upperBound...]) } ?? text)
            .prefix { !"/?#".contains($0) }
        // Validate the literal host, not URLComponents.host, which can decode
        // a legitimate xn-- ASCII name to Unicode on recent macOS versions.
        let hostParts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(hostParts.count), !authority.isEmpty,
              !authority.hasSuffix(":"), !authority.contains("%"),
              let rawHost = hostParts.first, domain(String(rawHost), allowLocal: explicit) else { return false }
        // Colons, slashes or query fragments are only accepted as URL syntax.
        guard !lower.contains("://") || explicit,
              let components = URLComponents(string: explicit ? text : "https://" + text),
              components.host != nil, components.user == nil, components.password == nil,
              components.scheme != nil else { return false }
        if let port = components.port, !(1...65535).contains(port) { return false }
        if let query = components.query, query.isEmpty { return false }
        if let fragment = components.fragment, fragment.isEmpty { return false }
        // Reject parser recovery such as an empty port or percent-encoded host.
        guard validPercentEncoding(text) else { return false }
        return true
    }

    private func domain(_ host: String, allowLocal: Bool) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host.allSatisfy({ $0.isASCII }) else { return false }
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        }) else { return false }
        if labels.count == 4 && labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return labels.allSatisfy { label in
                guard let number = Int(label), (0...255).contains(number) else { return false }
                return label == "0" || !label.hasPrefix("0")
            }
        }
        if labels.count == 1 { return allowLocal && labels[0].contains(where: \.isLetter) }
        return labels.count >= 2 && tlds.contains(String(labels.last!))
    }

    private func validPercentEncoding(_ text: String) -> Bool {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            if chars[index] == "%" {
                guard index + 2 < chars.count, chars[index + 1].isHexDigit, chars[index + 2].isHexDigit else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
}
