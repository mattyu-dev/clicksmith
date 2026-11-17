import Foundation

public enum QRPayload: Sendable, Equatable {
    case url(URL)
    case wifi(ssid: String, password: String?, security: String, hidden: Bool)
    case contact(vcard: String, name: String?)
    case event(ics: String, title: String?, start: Date?)
    case email(to: String, subject: String?, body: String?)
    case phone(String)
    case sms(number: String, body: String?)
    case geo(lat: Double, lon: Double)
    case text(String)
}

public enum CodeReader {}

public extension CodeReader {
    /// Classification only. Never opens a URL, joins a network, or imports a contact.
    static func parse(_ s: String) -> QRPayload {
        let value = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        if upper.hasPrefix("WIFI:") {
            guard let fields = escapedFields(String(value.dropFirst(5)), stripQuotes: true), let ssid = fields["S"]?.first, !ssid.isEmpty else { return .text(s) }
            return .wifi(ssid: ssid, password: fields["P"]?.first, security: fields["T"]?.first ?? "nopass", hidden: fields["H"]?.first?.lowercased() == "true")
        }
        if upper.hasPrefix("MECARD:") {
            guard let fields = escapedFields(String(value.dropFirst(7))), let name = fields["N"]?.first, !name.isEmpty else { return .text(s) }
            return mecard(fields, name: name)
        }
        if upper.hasPrefix("MATMSG:") {
            guard let fields = escapedFields(String(value.dropFirst(7))), let to = fields["TO"]?.first, !to.isEmpty else { return .text(s) }
            return .email(to: to, subject: fields["SUB"]?.first, body: fields["BODY"]?.first)
        }
        let lines = unfoldedLines(value)
        if lines.first?.uppercased() == "BEGIN:VCARD", lines.last?.uppercased() == "END:VCARD" {
            let fullName = property("FN", in: lines)?.value
            let name = fullName.map(unescape) ?? property("N", in: lines).map {
                $0.value.split(separator: ";", omittingEmptySubsequences: true).map { unescape(String($0)) }.joined(separator: " ")
            }
            return .contact(vcard: s, name: name)
        }
        if let begin = lines.firstIndex(where: { $0.uppercased() == "BEGIN:VEVENT" }),
           let end = lines[begin...].firstIndex(where: { $0.uppercased() == "END:VEVENT" }) {
            let event = Array(lines[(begin + 1)..<end])
            return .event(ics: s, title: property("SUMMARY", in: event).map { unescape($0.value) },
                          start: property("DTSTART", in: event).flatMap(eventDate))
        }
        if upper.hasPrefix("SMSTO:") {
            let parts = value.dropFirst(6).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let number = parts.first, !number.isEmpty else { return .text(s) }
            return .sms(number: String(number), body: parts.count == 2 ? String(parts[1]) : nil)
        }
        if upper.hasPrefix("GEO:") {
            let coords = value.dropFirst(4).prefix { $0 != "?" && $0 != ";" }.split(separator: ",", omittingEmptySubsequences: false)
            guard coords.count >= 2, coords.count <= 3, let lat = Double(coords[0]), let lon = Double(coords[1]),
                  lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return .text(s) }
            return .geo(lat: lat, lon: lon)
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .text(s) }
        let query = components.queryItems ?? []
        switch scheme {
        case "mailto":
            guard !components.path.isEmpty else { return .text(s) }
            return .email(to: components.path, subject: query.first { $0.name.lowercased() == "subject" }?.value,
                          body: query.first { $0.name.lowercased() == "body" }?.value)
        case "tel":
            return components.path.isEmpty ? .text(s) : .phone(components.path)
        case "sms":
            guard !components.path.isEmpty else { return .text(s) }
            return .sms(number: components.path, body: query.first { $0.name.lowercased() == "body" }?.value)
        case "http", "https", "ftp":
            guard let host = url.host(), !host.isEmpty else { return .text(s) }
            return .url(url)
        case "data", "javascript", "file": return .url(url)
        default: return .text(s)
        }
    }

    private static func escapedFields(_ body: String, stripQuotes: Bool = false) -> [String: [String]]? {
        var result: [String: [String]] = [:]
        var key: String?, part = "", escaped = false
        func store() {
            guard let key else { return }
            var raw = part
            let closingIsEscaped = raw.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
            if stripQuotes, raw.count >= 2, raw.first == "\"", raw.last == "\"", !closingIsEscaped { raw = String(raw.dropFirst().dropLast()) }
            var decoded = "", escapeNext = false
            for c in raw {
                if escapeNext { decoded.append(c); escapeNext = false }
                else if c == "\\" { escapeNext = true }
                else { decoded.append(c) }
            }
            result[key, default: []].append(decoded)
        }
        for c in body {
            if escaped { part.append(c); escaped = false }
            else if c == "\\" { part.append(c); escaped = true }
            else if c == ":", key == nil { key = part.uppercased(); part = "" }
            else if c == ";" {
                store()
                key = nil; part = ""
            } else { part.append(c) }
        }
        guard !escaped else { return nil }
        store()
        return result
    }

    private static func mecard(_ fields: [String: [String]], name: String) -> QRPayload {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
        }
        let parts = name.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let family = parts[0], given = parts.count == 2 ? parts[1] : ""
        let displayName = given.isEmpty ? family : "\(given) \(family)"
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "N:\(escape(family));\(escape(given));;;", "FN:\(escape(displayName))"]
        for key in ["TEL", "EMAIL", "ADR", "ORG", "URL", "BDAY", "NOTE"] {
            for value in fields[key] ?? [] {
                lines.append("\(key):\(key == "ADR" ? ";;" : "")\(escape(value))\(key == "ADR" ? ";;;;" : "")")
            }
        }
        lines.append("END:VCARD")
        return .contact(vcard: lines.joined(separator: "\r\n") + "\r\n", name: displayName)
    }

    private static func unfoldedLines(_ value: String) -> [String] {
        var result: [String] = []
        for line in value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else { result.append(line) }
        }
        return result
    }

    private static func property(_ name: String, in lines: [String]) -> (header: String, value: String)? {
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].split(separator: ";", maxSplits: 1).first?.split(separator: ".").last
            if key?.uppercased() == name { return (String(parts[0]), String(parts[1])) }
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        var output = "", escaped = false
        for c in value {
            if escaped { output.append(c == "n" || c == "N" ? "\n" : c); escaped = false }
            else if c == "\\" { escaped = true }
            else { output.append(c) }
        }
        if escaped { output.append("\\") }
        return output
    }

    private static func eventDate(_ property: (header: String, value: String)) -> Date? {
        let format: String
        switch property.value.count {
        case 8: format = "yyyyMMdd"
        case 15: format = "yyyyMMdd'T'HHmmss"
        case 16 where property.value.hasSuffix("Z"): format = "yyyyMMdd'T'HHmmss'Z'"
        default: return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = property.value.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0) : .current
        if !property.value.hasSuffix("Z"), let tz = property.header.components(separatedBy: ";").first(where: { $0.uppercased().hasPrefix("TZID=") }) {
            guard let zone = TimeZone(identifier: String(tz.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) else { return nil }
            formatter.timeZone = zone
        }
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: property.value), formatter.string(from: date) == property.value else { return nil }
        return date
    }
}
