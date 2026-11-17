import Foundation

/// The app reads NSPasteboard and passes its chosen representation to this engine.
public enum ClipboardContent: Sendable {
    case text(String)
    case image(Data)
    case fileURLs([URL])
    case rtf(Data)
    case html(String)
}

public struct DetectedFile: Sendable {
    /// A filename stem, without the extension. At most 40 characters.
    public let suggestedName: String
    public let ext: String
    public let data: Data
    public let kind: String

    public init(suggestedName: String, ext: String, data: Data, kind: String) {
        self.suggestedName = suggestedName
        self.ext = ext
        self.data = data
        self.kind = kind
    }
}

/// Classifies content without reading the pasteboard, referenced files, or the network.
public enum ClipboardDetector {
    public static func detect(_ content: ClipboardContent) -> DetectedFile {
        switch content {
        case .text(let text):
            return detectText(text)
        case .image(let data):
            return file(ext: "png", data: data, kind: "PNG image")
        case .rtf(let data):
            return file(ext: "rtf", data: data, kind: "RTF")
        case .html(let html):
            return file(ext: "html", data: Data(html.utf8), kind: "HTML", title: htmlHeading(html))
        case .fileURLs(let urls):
            return file(ext: "txt", data: Data(urls.map(\.absoluteString).joined(separator: "\n").utf8),
                        kind: "File URLs")
        }
    }

    private static func detectText(_ text: String) -> DetectedFile {
        let data = Data(text.utf8)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Bound heuristic work, including regexes on malformed input. Output and JSON
        // validation still use the entire paste; tables must have consistent rows throughout.
        let probe = String(decoding: trimmed.utf8.prefix(65_536), as: UTF8.self)
        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           (try? JSONSerialization.jsonObject(with: data)) != nil,
           !hasTrailingJSONComma(data) {
            // Parsing only validates. Re-serialization can round numbers, discard
            // duplicate keys, reorder fields, and change escapes or whitespace.
            return file(ext: "json", data: data, kind: "JSON", title: firstJSONKey(probe))
        }
        if let url = absoluteURL(trimmed),
           let plist = try? PropertyListSerialization.data(
               fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0
           ) {
            return file(ext: "webloc", data: plist, kind: "URL", title: url.host)
        }
        let heading = markdownHeading(probe)
        let markdownList = matches("(?m)^ {0,3}(?:[-+*]|[0-9]+[.)])[ \\t]+\\S", probe)
        if matches("(?m)^ {0,3}(?:`{3,}|~{3,})", probe) {
            return file(ext: "md", data: data, kind: "Markdown", title: heading)
        }
        let code = codeType(probe)
        if probe.hasPrefix("<"), heading != nil || markdownList {
            return file(ext: "md", data: data, kind: "Markdown", title: heading)
        }
        // JSX begins with source code. A README can start with an HTML badge but
        // still contain Markdown. Only classify markup at the beginning as HTML.
        if probe.hasPrefix("<"), heading == nil, !markdownList,
           matches("(?is)^(?:<!doctype\\s+html\\b|<html\\b|<(h[1-6]|div|p|body|head|table|ul|ol|a|span)\\b[^<>]{0,500}>.{0,500}?</\\1\\s*>)", probe) {
            return file(ext: "html", data: data, kind: "HTML", title: htmlHeading(probe))
        }
        // A query or script header is stronger evidence than delimiters in source.
        // Otherwise prefer a complete table over code syntax inside one of its cells.
        if let code, code.ext == "sql" || trimmed.hasPrefix("#!") {
            return file(ext: code.ext, data: data, kind: code.kind)
        }
        if isTable(text, delimiter: "\t") {
            return file(ext: "tsv", data: data, kind: "TSV")
        }
        if isTable(text, delimiter: ",") {
            return file(ext: "csv", data: data, kind: "CSV")
        }
        if let code {
            return file(ext: code.ext, data: data, kind: code.kind)
        }
        if heading != nil || isMarkdown(probe) {
            return file(ext: "md", data: data, kind: "Markdown", title: heading)
        }
        return file(ext: "txt", data: data, kind: "Plain text")
    }

    private static func firstJSONKey(_ text: String) -> String? {
        guard let range = text.range(of: #"^\{\s*"(?:\\.|[^"\\])*""#, options: .regularExpression),
              let quote = text[range].firstIndex(of: "\"") else { return nil }
        let key = Data(text[quote..<range.upperBound].utf8)
        return (try? JSONSerialization.jsonObject(with: key, options: [.fragmentsAllowed])) as? String
    }

    /// Foundation accepts trailing commas. Check token boundaries outside strings so
    /// invalid JSON stays unchanged, while string contents such as ",}" remain valid.
    private static func hasTrailingJSONComma(_ data: Data) -> Bool {
        var inString = false
        var escaped = false
        var previous: UInt8 = 0
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
                previous = byte
            } else if ![0x20, 0x09, 0x0a, 0x0d].contains(byte) {
                if (byte == 0x7d || byte == 0x5d), previous == 0x2c { return true }
                previous = byte
            }
        }
        return false
    }

    private static func absoluteURL(_ text: String) -> URL? {
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let url = components.url else { return nil }
        if scheme == "file" { return url.path.isEmpty ? nil : url }
        if scheme == "mailto" { return components.path.contains("@") ? url : nil }
        guard text.contains("://"), let host = components.host, !host.isEmpty else { return nil }
        return url
    }

    /// Requires at least two records with the same number of fields. Quoted delimiters,
    /// escaped quotes and quoted newlines do not count as record or field boundaries.
    private static func isTable(_ text: String, delimiter: Character) -> Bool {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .newlines)
        guard normalized.contains(delimiter), normalized.contains("\n") else { return false }
        let characters = Array(normalized)
        var index = 0
        var quoted = false
        var afterQuote = false
        var fieldStart = true
        var recordHasCharacters = false
        var fields = 1
        var records: [Int] = []
        var cellStart = 0
        var simpleCells = true
        var typedCell = false
        var quotedCell = false
        func inspectCell(endingAt end: Int) {
            guard delimiter == "," else { return }
            let cell = String(characters[cellStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cell.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { simpleCells = false }
            if Double(cell) != nil || ["true", "false", "null"].contains(cell.lowercased()) { typedCell = true }
        }
        while index < characters.count {
            let character = characters[index]
            index += 1
            if quoted {
                if character == "\"" {
                    if index < characters.count, characters[index] == "\"" {
                        index += 1
                    } else {
                        quoted = false
                        afterQuote = true
                    }
                }
                continue
            }
            if afterQuote, character != delimiter, character != "\n" { return false }
            if character == delimiter {
                inspectCell(endingAt: index - 1)
                cellStart = index
                fields += 1
                fieldStart = true
                afterQuote = false
                recordHasCharacters = true
            } else if character == "\n" {
                guard recordHasCharacters else { return false }
                inspectCell(endingAt: index - 1)
                cellStart = index
                records.append(fields)
                fields = 1
                fieldStart = true
                afterQuote = false
                recordHasCharacters = false
            } else if character == "\"" {
                guard fieldStart else { return false }
                quotedCell = true
                quoted = true
                fieldStart = false
                recordHasCharacters = true
            } else {
                fieldStart = false
                recordHasCharacters = true
            }
        }
        guard !quoted else { return false }
        if recordHasCharacters {
            inspectCell(endingAt: characters.count)
            records.append(fields)
        }
        guard records.count >= 2, let first = records.first, first >= 2 else { return false }
        guard records.allSatisfy({ $0 == first }) else { return false }
        // Two comma-separated prose lines are common in messages. Small CSV needs
        // stronger evidence; TSV retains the two-record rule.
        return delimiter != "," || records.count >= 3 || first >= 3 || quotedCell || typedCell || simpleCells
    }

    private static func codeType(_ text: String) -> (ext: String, kind: String)? {
        // Test specific syntax before ambiguous declarations such as `let` and `import`.
        if matches("(?m)^#![^\\n]*\\bpython[0-9.]*\\b", text) {
            return ("py", "Python")
        }
        if matches("(?m)^#![^\\n]*/(?:env\\s+(?:-S\\s+)?)?(?:ba|z|da|k)?sh\\b", text)
            || matches("(?m)^\\$ \\S", text)
            || matches("(?m)^(?:set -[a-zA-Z]+(?:\\s|$)|export [A-Za-z_][A-Za-z0-9_]*=|(?:echo|printf)\\s+[\"'$]|for .+;\\s*do\\b)", text) {
            return ("sh", "Shell")
        }
        if matches("(?m)^\\s*(?:export\\s+)?(?:interface\\s+[A-Za-z_$][\\w$]*(?:\\s+extends\\s+[^{}]+)?\\s*\\{|type\\s+[A-Za-z_$][\\w$]*(?:<[^>]+>)?\\s*=)", text)
            || matches("(?m)\\b(?:const|let|var)\\s+[A-Za-z_$][\\w$]*\\s*:\\s*(?:string|number|boolean|unknown|never|any|Record\\s*<)", text)
            || matches("\\bfunction\\s+\\w+\\s*\\([^)]*:\\s*(?:string|number|boolean)\\b", text)
            || matches("\\([^)]*:\\s*(?:string|number|boolean)\\b[^)]*\\)\\s*(?::[^=]+)?=>", text) {
            return ("ts", "TypeScript")
        }
        if matches("(?m)^\\s*(?:(?:(?:public|private|internal|fileprivate|open|final)\\s+)*(?:struct|enum|protocol|extension|actor|class)\\s+\\w+[^\\n]*\\{|(?:(?:public|private|internal|fileprivate|open|static|mutating)\\s+)*func\\s+\\w+\\s*\\(|import\\s+(?:Foundation|SwiftUI|AppKit|Swift|Darwin|Dispatch|Testing)\\b)", text)
            || matches("(?m)^\\s*(?:let|var)\\s+\\w+\\s*:\\s*(?:String|Int|Double|Bool|URL|Data|\\[)", text) {
            return ("swift", "Swift")
        }
        if matches("(?m)^\\s*(?:(?:export\\s+)?(?:async\\s+)?function\\s+\\w+\\s*\\(|(?:export\\s+)?const\\s+\\w+\\s*=|(?:let|var)\\s+\\w+\\s*=.*;\\s*$|(?:import|export)\\s+.+\\s+from\\s+['\"]|console\\.(?:log|warn|error)\\s*\\()", text)
            || matches(#"(?m)^[ \t]*(?:async[ \t]+)?(?:\([^\r\n()]*\)|[A-Za-z_$][\w$]*)[ \t]*=>[ \t]*(?:\{|\(|['"`]|[\w$.]+[ \t]*(?:\(|[+*/%-][ \t]*\S|;?[ \t]*$))"#, text) {
            return ("js", "JavaScript")
        }
        if matches("(?m)^\\s*(?:(?:async\\s+)?def\\s+\\w+\\s*\\([^)]*\\)\\s*(?:->[^:]+)?\\s*:|class\\s+(?:[A-Z]\\w*(?:\\([^)]*\\))?\\s*:|\\w+(?:\\([^)]*\\))?[ \\t]*:[ \\t]*\\r?\\n[ \\t]+\\S)|from\\s+[\\w.]+\\s+import\\s+|import\\s+[a-z_][\\w.]*(?:\\s+as\\s+\\w+)?\\s*$|print\\s*\\()", text) {
            return ("py", "Python")
        }
        if isSQL(text) {
            return ("sql", "SQL")
        }
        if isYAML(text) { return ("yaml", "YAML") }
        return nil
    }

    private static func isSQL(_ text: String) -> Bool {
        let query = text.replacingOccurrences(of: "(?m)^[ \\t]*--[^\\n]*(?:\\n|$)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = #"(?:[A-Za-z_][\w.$]*|"[^"\r\n]+"|`[^`\r\n]+`|\[[^]\r\n]+\])"#
        let column = "(?:\\*|\(identifier)(?:\\([^;\\r\\n]{0,200}\\))?)(?:\\s+as\\s+\(identifier))?"
        if matches("(?is)^select\\s+(?:distinct\\s+)?\(column)(?:\\s*,\\s*\(column))*\\s+from\\s+\(identifier)(?:[\\s;,]|$)", query) {
            return query.hasSuffix(";") || matches("(?i)\\b(?:where|join|group\\s+by|order\\s+by|limit|having|union)\\b", query)
                || (matches("^SELECT\\s", query) && matches("\\bFROM\\b", query))
        }
        guard matches("(?is)^(?:insert\\s+into\\s+|update\\s+\\S+\\s+set\\s+|delete\\s+from\\s+|create\\s+(?:table|index|view)\\s+|alter\\s+table\\s+|drop\\s+(?:table|index|view)\\s+)", query) else { return false }
        let keyword = query.components(separatedBy: .whitespacesAndNewlines).first ?? ""
        return query.hasSuffix(";") || keyword == keyword.uppercased()
    }

    private static func isYAML(_ text: String) -> Bool {
        var mappings = 0
        var typedValue = false
        var simpleValues = true
        var yamlSyntax = false
        let explicitDocument = text.hasPrefix("---\n") || text.hasPrefix("---\r\n")
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line == "---" || line == "..." { continue }
            if line.hasPrefix("- "), mappings > 0 {
                yamlSyntax = true
                continue
            }
            guard matches("^[A-Za-z_][A-Za-z0-9_.-]*:(?:[ \\t]+.*)?$", line),
                  let colon = line.firstIndex(of: ":") else { return false }
            mappings += 1
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t") { yamlSyntax = true }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty || matches("(?i)^(?:true|false|null|~|\\[.*\\]|\\{.*\\}|\".*\"|'.*')$", value) {
                typedValue = true
                yamlSyntax = true
            } else if Double(value) != nil {
                typedValue = true
            }
            if value.rangeOfCharacter(from: .whitespaces) != nil { simpleValues = false }
        }
        guard explicitDocument || mappings > 3 || yamlSyntax else { return false }
        return mappings >= (explicitDocument ? 1 : 2) && (explicitDocument || typedValue || simpleValues)
    }

    private static func isMarkdown(_ text: String) -> Bool {
        if matches("(?m)^ {0,3}(?:```|~~~)|^>\\s+|\\[[^]\\n]+\\]\\([^\\s)]+\\)|\\*\\*[^*\\n]+\\*\\*", text) { return true }
        let listLines = text.components(separatedBy: .newlines).filter {
            matches("^ {0,3}(?:[-+*]|[0-9]+[.)])\\s+\\S", $0)
        }
        return listLines.count >= 2
    }

    private static func markdownHeading(_ text: String) -> String? {
        guard let range = text.range(
            of: "(?m)^ {0,3}#{1,6}[ \\t]+\\S[^\\r\\n]*$|^[^\\r\\n]+\\r?\\n(?:={3,}|-{3,})[ \\t]*$",
            options: .regularExpression
        ) else { return nil }
        let heading = String(text[range]).components(separatedBy: .newlines)[0]
        return heading.replacingOccurrences(of: "^ {0,3}#{1,6}[ \\t]+|[ \\t]+#+[ \\t]*$", with: "", options: .regularExpression)
    }

    private static func htmlHeading(_ text: String) -> String? {
        let probe = String(decoding: text.utf8.prefix(65_536), as: UTF8.self)
        for element in ["h[1-6]", "title"] {
            if let range = probe.range(of: "(?is)<(\(element))\\b[^<>]{0,500}>.{0,500}?</\\1\\s*>", options: .regularExpression) {
                return String(probe[range]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }
        }
        return nil
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func file(ext: String, data: Data, kind: String, title: String? = nil) -> DetectedFile {
        DetectedFile(suggestedName: suggestedName(title), ext: ext, data: data, kind: kind)
    }

    private static func suggestedName(_ title: String?) -> String {
        if let title {
            let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            var slug = ""
            for scalar in folded.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    slug.unicodeScalars.append(scalar)
                } else if !slug.isEmpty, !slug.hasSuffix("-") {
                    slug.append("-")
                }
                if slug.count >= 40 { break }
            }
            slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if !slug.isEmpty { return slug }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'Clipboard' yyyy-MM-dd 'at' HH.mm"
        return formatter.string(from: Date())
    }
}
