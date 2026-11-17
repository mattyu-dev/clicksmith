import Foundation
import Darwin

/// Offline heuristics, not a certificate of trust. No host is fetched or resolved.
public struct LinkRisk: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case safe, caution, danger
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let level: Level
    public let reasons: [String]

    public init(level: Level, reasons: [String]) { self.level = level; self.reasons = reasons }
}

public extension CodeReader {
    static func assess(_ url: URL) -> LinkRisk {
        var level = LinkRisk.Level.safe
        var reasons: [String] = []
        func flag(_ severity: LinkRisk.Level, _ reason: String) {
            level = max(level, severity); reasons.append(reason)
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "javascript" || scheme == "data" { flag(.danger, "This link can contain executable or embedded content.") }
        else if scheme == "http" { flag(.caution, "This link uses HTTP without TLS.") }
        else if scheme != "https" { flag(.caution, "This link does not use HTTPS.") }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host(percentEncoded: false) ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".[]"))
        let displayHost = components?.host?.lowercased() ?? host
        let familiarDomains = ["paypal.com", "apple.com", "icloud.com", "google.com", "microsoft.com", "amazon.com", "facebook.com", "instagram.com", "bankofamerica.com"]
        if components?.user != nil || components?.password != nil { flag(.danger, "This link has user information before @, which can hide the actual host.") }
        if host.isEmpty && (scheme == "https" || scheme == "http") { flag(.danger, "This web link has no host.") }
        if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) { flag(.caution, "This host uses an internationalized punycode name. Check its spelling.") }

        // Inspect each label. The ASCII TLD must not make a single-script IDN look mixed.
        for label in displayHost.split(separator: ".") {
            let latin = label.range(of: "\\p{Latin}", options: .regularExpression) != nil
            let cyrillic = label.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil
            let greek = label.range(of: "\\p{Greek}", options: .regularExpression) != nil
            if [latin, cyrillic, greek].filter({ $0 }).count > 1 {
                flag(.danger, "This host mixes writing systems and may imitate another name."); break
            }
            let latinTLD = displayHost.split(separator: ".").last?.allSatisfy { $0.isASCII && $0.isLetter } == true
            if (cyrillic || greek), latinTLD, familiarDomains.contains(where: { $0.hasPrefix(confusableSkeleton(String(label)) + ".") }) {
                flag(.danger, "This internationalized host imitates a familiar name."); break
            }
        }
        let shorteners: Set<String> = ["bit.ly", "t.co", "tinyurl.com", "goo.gl", "ow.ly", "is.gd", "buff.ly", "cutt.ly", "rebrand.ly", "rb.gy", "shorturl.at", "tiny.cc", "lnkd.in", "s.id"]
        if shorteners.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { flag(.caution, "This short link hides its final destination.") }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_aton(host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 { flag(.caution, "This host is an IP address.") }
        if familiarDomains.contains(where: { domain in
            if host == domain || host.hasSuffix("." + domain) { return false }
            let brand = domain.split(separator: ".")[0]
            let labels = host.split(separator: ".")
            for i in labels.indices where i + 2 < labels.count {
                guard labels[i].contains(brand), labels[i + 1] == "com" else { continue }
                if labels[i] != brand || !countrySuffix(Array(labels[(i + 2)...])) { return true }
            }
            return false
        }) {
            flag(.danger, "A familiar domain appears inside a different host's subdomain.")
        }
        if (components?.percentEncodedQuery?.utf8.count ?? 0) > 2_048 { flag(.caution, "This link has an unusually long query.") }
        return LinkRisk(level: level, reasons: reasons)
    }

    /// Country variants such as amazon.com.au must end at the country suffix.
    /// This narrow heuristic is not a public suffix database or a reputation check.
    private static func countrySuffix(_ labels: [Substring]) -> Bool {
        guard let country = labels.last, country.count == 2, country.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return labels.count == 1 || (labels.count == 2 && ["ac", "co", "com", "edu", "gov", "net", "org"].contains(String(labels[0])))
    }

    private static func confusableSkeleton(_ label: String) -> String {
        // Common Cyrillic/Greek look-alikes. Only an exact known-brand match raises danger.
        let substitutions: [Character: Character] = [
            "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "ӏ": "l",
            "к": "k", "м": "m", "т": "t", "в": "b", "н": "h",
            "α": "a", "ε": "e", "ο": "o", "ρ": "p", "ι": "i", "κ": "k", "τ": "t", "υ": "y", "χ": "x", "ν": "v", "λ": "l"
        ]
        return String(label.map { substitutions[$0] ?? $0 })
    }
}
