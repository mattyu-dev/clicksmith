import Foundation

/// Dependency-free recovery path for Markdown documents. Supports the structural
/// Markdown/GFM forms used by document conversion; raw HTML is deliberately omitted.
enum SwiftMarkdownRenderer {
    static func render(_ markdown: String) -> String {
        var parser = Parser()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var content: [String] = []
        var codeFence: (character: Character, count: Int)?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = codeFence {
                content.append(line)
                if trimmed.count >= current.count, trimmed.allSatisfy({ $0 == current.character }) { codeFence = nil }
                continue
            }
            if let fence = captures(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, line), let character = fence[0].first {
                codeFence = (character, fence[0].count); content.append(line); continue
            }
            if let groups = captures(#"^ {0,3}\[([^\]]+)\]:\s*(<[^>]+>|\S+)(?:\s+["'](.*)["'])?\s*$"#, line) {
                let url = groups[1].hasPrefix("<") ? String(groups[1].dropFirst().dropLast()) : groups[1]
                parser.references[referenceKey(groups[0])] = (url, groups.count > 2 ? groups[2] : "")
                content.append("")
            } else { content.append(line) }
        }
        return parser.blocks(content, depth: 0)
    }

    private static func captures(_ pattern: String, _ input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(location: 0, length: (input as NSString).length)) else { return nil }
        let source = input as NSString
        return (1..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : source.substring(with: match.range(at: $0)) }
    }

    private static func referenceKey(_ string: String) -> String {
        string.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func escaped(_ text: String) -> String { MarkdownRenderer.escape(text) }

    private struct Parser {
        var references: [String: (url: String, title: String)] = [:]

        func blocks(_ lines: [String], depth: Int) -> String {
            guard depth < 64 else { return "<pre>\(escaped(lines.joined(separator: "\n")))</pre>\n" }
            var result = "", index = 0
            while index < lines.count {
                let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { index += 1; continue }
                if let fence = fence(line) {
                    index += 1
                    var code: [String] = []
                    while index < lines.count {
                        let end = lines[index].trimmingCharacters(in: .whitespaces)
                        if end.count >= fence.count, end.allSatisfy({ $0 == fence.character }) { index += 1; break }
                        code.append(lines[index]); index += 1
                    }
                    let language = fence.info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                    let attribute = language.isEmpty ? "" : " class=\"language-\(escaped(language))\""
                    result += "<pre><code\(attribute)>\(escaped(code.joined(separator: "\n") + (code.isEmpty ? "" : "\n")))</code></pre>\n"
                } else if let heading = captures(#"^ {0,3}(#{1,6})(?:[ \t]+(.*)|$)"#, line) {
                    let level = heading[0].count
                    let text = heading[1].replacingOccurrences(of: #"[ \t]+#+[ \t]*$"#, with: "", options: .regularExpression)
                    result += "<h\(level)>\(inline(text))</h\(level)>\n"; index += 1
                } else if rule(trimmed) {
                    result += "<hr />\n"; index += 1
                } else if trimmed.hasPrefix(">") {
                    var quoted: [String] = []
                    while index < lines.count {
                        let current = lines[index].trimmingCharacters(in: .whitespaces)
                        guard current.hasPrefix(">") else { break }
                        var text = String(current.dropFirst())
                        if text.first == " " { text.removeFirst() }
                        quoted.append(text); index += 1
                    }
                    result += "<blockquote>\n\(blocks(quoted, depth: depth + 1))</blockquote>\n"
                } else if let marker = listMarker(line) {
                    let list = list(lines, start: index, marker: marker, depth: depth)
                    result += list.html; index = list.end
                } else if index + 1 < lines.count, line.contains("|"), let alignments = tableAlignments(lines[index + 1]), cells(line).count == alignments.count {
                    let headers = cells(line)
                    result += "<table>\n<thead>\n<tr>\n"
                    for (column, header) in headers.enumerated() { result += tableCell(header, tag: "th", alignment: alignments[column]) }
                    result += "</tr>\n</thead>\n<tbody>\n"; index += 2
                    while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let row = cells(lines[index]); result += "<tr>\n"
                        for column in headers.indices { result += tableCell(column < row.count ? row[column] : "", tag: "td", alignment: alignments[column]) }
                        result += "</tr>\n"; index += 1
                    }
                    result += "</tbody>\n</table>\n"
                } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                    var code: [String] = []
                    while index < lines.count {
                        let text = lines[index]
                        if text.hasPrefix("    ") { code.append(String(text.dropFirst(4))) }
                        else if text.hasPrefix("\t") { code.append(String(text.dropFirst())) }
                        else if text.isEmpty { code.append("") }
                        else { break }
                        index += 1
                    }
                    result += "<pre><code>\(escaped(code.joined(separator: "\n") + "\n"))</code></pre>\n"
                } else if rawHTMLBlock(trimmed) {
                    let lower = trimmed.lowercased()
                    let activeTag = ["script", "style", "iframe"].first { lower.hasPrefix("<" + $0) }
                    repeat {
                        let current = lines[index].lowercased(); index += 1
                        if let activeTag, current.contains("</" + activeTag + ">") { break }
                        if activeTag == nil, index == lines.count || lines[index].trimmingCharacters(in: .whitespaces).isEmpty { break }
                    } while index < lines.count
                    result += "<!-- raw HTML omitted -->\n"
                } else if index + 1 < lines.count, let level = setext(lines[index + 1]) {
                    result += "<h\(level)>\(inline(trimmed))</h\(level)>\n"; index += 2
                } else {
                    var paragraph: [String] = [line]; index += 1
                    while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(lines[index]) {
                        if index + 1 < lines.count, setext(lines[index + 1]) != nil { break }
                        paragraph.append(lines[index]); index += 1
                    }
                    let html = paragraph.map { text -> String in
                        if text.hasSuffix("  ") { return inline(text.trimmingCharacters(in: .whitespaces)) + "<br />" }
                        if text.hasSuffix("\\") { return inline(String(text.dropLast())) + "<br />" }
                        return inline(text)
                    }.joined(separator: "\n")
                    result += "<p>\(html)</p>\n"
                }
            }
            return result
        }

        private func fence(_ line: String) -> (character: Character, count: Int, info: String)? {
            guard let match = captures(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, line), let character = match[0].first else { return nil }
            if character == "`", match[1].contains("`") { return nil }
            return (character, match[0].count, match[1].trimmingCharacters(in: .whitespaces))
        }

        private func rule(_ line: String) -> Bool {
            let text = line.filter { !$0.isWhitespace }
            return text.count >= 3 && ["-", "*", "_"].contains(text.first.map(String.init) ?? "") && text.allSatisfy { $0 == text.first }
        }

        private func setext(_ line: String) -> Int? {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text.allSatisfy({ $0 == "=" }) { return 1 }
            if !text.isEmpty, text.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        private func rawHTMLBlock(_ text: String) -> Bool {
            let lower = text.lowercased()
            return ["<!--", "<!doctype", "<script", "<style", "<iframe", "<div", "<table", "<details", "<summary", "<section", "<p>", "<img", "<br"].contains { lower.hasPrefix($0) }
        }

        private func startsBlock(_ line: String) -> Bool {
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix(">") || fence(line) != nil || listMarker(line) != nil || rule(text) ||
                captures(#"^ {0,3}#{1,6}(?:\s|$)"#, line) != nil || rawHTMLBlock(text)
        }

        private func listMarker(_ line: String) -> (marker: String, ordered: Bool, start: Int, indent: Int, content: String)? {
            guard let match = captures(#"^( {0,3})([-+*]|[0-9]{1,9}[.)])([ \t]+)(.*)$"#, line) else { return nil }
            let ordered = match[1].first?.isNumber == true
            return (ordered ? String(match[1].suffix(1)) : match[1], ordered, Int(match[1].dropLast()) ?? 1,
                    match[0].count + match[1].count + match[2].count, match[3])
        }

        private func list(_ lines: [String], start: Int, marker: (marker: String, ordered: Bool, start: Int, indent: Int, content: String), depth: Int) -> (html: String, end: Int) {
            var index = start, items: [[String]] = [], loose = false
            while index < lines.count, let next = listMarker(lines[index]), next.ordered == marker.ordered, next.marker == marker.marker {
                var item = [next.content]; index += 1
                while index < lines.count {
                    let line = lines[index]
                    if line.trimmingCharacters(in: .whitespaces).isEmpty {
                        if index + 1 < lines.count, let following = listMarker(lines[index + 1]), following.ordered == marker.ordered, following.marker == marker.marker {
                            loose = true; index += 1; break
                        }
                        item.append(""); index += 1; continue
                    }
                    let spaces = line.prefix { $0 == " " }.count
                    if spaces >= next.indent { item.append(String(line.dropFirst(next.indent))); index += 1 }
                    else if listMarker(line) != nil || startsBlock(line) || item.last == "" { break }
                    else { item.append(line); index += 1 }
                }
                while item.last == "" { item.removeLast() }
                if item.contains("") { loose = true }
                items.append(item)
            }
            let tag = marker.ordered ? "ol" : "ul"
            let startAttribute = marker.ordered && marker.start != 1 ? " start=\"\(marker.start)\"" : ""
            var html = "<\(tag)\(startAttribute)>\n"
            for var item in items {
                var checkbox = ""
                if let first = item.first, let task = captures(#"^\[([ xX])\](?:\s+|$)(.*)$"#, first) {
                    checkbox = "<input type=\"checkbox\" disabled=\"\"\(task[0].lowercased() == "x" ? " checked=\"\"" : "") /> "
                    item[0] = task[1]
                }
                var body = blocks(item, depth: depth + 1)
                if !loose, body.hasPrefix("<p>"), let end = body.range(of: "</p>") {
                    body.removeSubrange(end); body.removeFirst(3)
                }
                html += "<li>\(checkbox)\(body)</li>\n"
            }
            return (html + "</\(tag)>\n", index)
        }

        private func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.first == "|" { text.removeFirst() }
            if text.last == "|", !text.hasSuffix("\\|") { text.removeLast() }
            var cells: [String] = [], current = "", escapedPipe = false, inCode = false
            for character in text {
                if character == "|", !escapedPipe, !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(character) }
                if character == "`", !escapedPipe { inCode.toggle() }
                escapedPipe = character == "\\" && !escapedPipe
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        private func tableAlignments(_ line: String) -> [String]? {
            let values = cells(line)
            guard !values.isEmpty, values.allSatisfy({ captures(#"^:?-+:?$"#, $0) != nil }) else { return nil }
            return values.map { $0.hasPrefix(":") ? ($0.hasSuffix(":") ? "center" : "left") : ($0.hasSuffix(":") ? "right" : "") }
        }

        private func tableCell(_ text: String, tag: String, alignment: String) -> String {
            "<\(tag)\(alignment.isEmpty ? "" : " align=\"\(alignment)\"")>\(inline(text))</\(tag)>\n"
        }

        private func safeURL(_ url: String, image: Bool = false) -> Bool {
            let cleaned = url.filter { !$0.isWhitespace && !$0.isNewline && $0.asciiValue != 0 }.lowercased()
            guard let colon = cleaned.firstIndex(of: ":"), !cleaned[..<colon].contains("/"), !cleaned[..<colon].contains("#") else { return true }
            let scheme = String(cleaned[..<colon])
            if ["https", "http", "mailto", "file"].contains(scheme) { return true }
            return image && ["data:image/png;", "data:image/jpeg;", "data:image/gif;", "data:image/webp;"].contains { cleaned.hasPrefix($0) }
        }

        private func inline(_ text: String, depth: Int = 0) -> String {
            guard depth < 32 else { return escaped(text) }
            let chars = Array(text)
            var result = "", index = 0
            func run(_ at: Int, character: Character) -> Int { var end = at; while end < chars.count, chars[end] == character { end += 1 }; return end - at }
            while index < chars.count {
                let c = chars[index]
                if c == "\\", index + 1 < chars.count, chars[index + 1].isPunctuation || chars[index + 1].isSymbol {
                    result += escaped(String(chars[index + 1])); index += 2; continue
                }
                if c == "`" {
                    let count = run(index, character: c)
                    var end = index + count
                    while end < chars.count {
                        if chars[end] == c, run(end, character: c) == count { break }
                        end += chars[end] == c ? run(end, character: c) : 1
                    }
                    if end < chars.count {
                        var code = String(chars[(index + count)..<end]).replacingOccurrences(of: "\n", with: " ")
                        if code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) { code.removeFirst(); code.removeLast() }
                        result += "<code>\(escaped(code))</code>"; index = end + count; continue
                    }
                    result += String(repeating: "`", count: count); index += count; continue
                }
                if (c == "[" || (c == "!" && index + 1 < chars.count && chars[index + 1] == "[")), let link = link(chars, at: index) {
                    let image = c == "!"
                    let label = image ? escaped(link.label) : inline(link.label, depth: depth + 1)
                    if safeURL(link.url, image: image) {
                        let title = link.title.isEmpty ? "" : " title=\"\(escaped(link.title))\""
                        result += image ? "<img src=\"\(escaped(link.url))\" alt=\"\(label)\"\(title) />" : "<a href=\"\(escaped(link.url))\"\(title)>\(label)</a>"
                    } else { result += label }
                    index = link.end; continue
                }
                if c == "<", let end = chars[(index + 1)...].firstIndex(of: ">") {
                    let inside = String(chars[(index + 1)..<end])
                    if inside.hasPrefix("https://") || inside.hasPrefix("http://") || inside.hasPrefix("mailto:") {
                        result += "<a href=\"\(escaped(inside))\">\(escaped(inside))</a>"
                    } else if captures(#"^[^ <>@]+@[^ <>@]+\.[^ <>@]+$"#, inside) != nil {
                        result += "<a href=\"mailto:\(escaped(inside))\">\(escaped(inside))</a>"
                    } else { result += "<!-- raw HTML omitted -->" }
                    index = end + 1; continue
                }
                if ["*", "_", "~"].contains(c) {
                    let count = min(c == "~" ? 2 : 3, run(index, character: c))
                    let intraword = c == "_" && index > 0 && chars[index - 1].isLetter
                    if (c != "~" || count == 2), !intraword, index + count < chars.count, !chars[index + count].isWhitespace {
                        var end = index + count
                        while end < chars.count {
                            if chars[end] == c, run(end, character: c) == count, !chars[end - 1].isWhitespace { break }
                            end += 1
                        }
                        if end < chars.count {
                            let tags = c == "~" ? ("<del>", "</del>") : count == 1 ? ("<em>", "</em>") : count == 2 ? ("<strong>", "</strong>") : ("<em><strong>", "</strong></em>")
                            result += tags.0 + inline(String(chars[(index + count)..<end]), depth: depth + 1) + tags.1
                            index = end + count; continue
                        }
                    }
                }
                if index == 0 || chars[index - 1].isWhitespace || "([".contains(chars[index - 1]) {
                    var end = index
                    while end < chars.count, !chars[end].isWhitespace, chars[end] != "<", chars[end] != ">" { end += 1 }
                    var candidate = String(chars[index..<end])
                    while let last = candidate.last, ".,:;!?".contains(last) || (last == ")" && candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count) { candidate.removeLast(); end -= 1 }
                    let web = candidate.hasPrefix("https://") || candidate.hasPrefix("http://") || candidate.hasPrefix("www.")
                    let email = captures(#"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, candidate) != nil
                    if web || email {
                        let url = email ? "mailto:" + candidate : candidate.hasPrefix("www.") ? "https://" + candidate : candidate
                        result += "<a href=\"\(escaped(url))\">\(escaped(candidate))</a>"; index = end; continue
                    }
                }
                if c == "&", let end = chars[(index + 1)...].firstIndex(of: ";"), end - index < 32 {
                    let entity = String(chars[index...end])
                    if captures(#"^&(?:#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]+);$"#, entity) != nil {
                        result += entity; index = end + 1; continue
                    }
                }
                result += escaped(String(c)); index += 1
            }
            return result
        }

        private func link(_ chars: [Character], at index: Int) -> (label: String, url: String, title: String, end: Int)? {
            let start = index + (chars[index] == "!" ? 2 : 1)
            var end = start, nesting = 0
            while end < chars.count {
                if chars[end] == "\\", end + 1 < chars.count { end += 2; continue }
                if chars[end] == "]", nesting == 0 { break }
                if chars[end] == "[" { nesting += 1 }
                if chars[end] == "]" { nesting -= 1 }
                end += 1
            }
            guard end < chars.count else { return nil }
            let label = String(chars[start..<end]); end += 1
            if end < chars.count, chars[end] == "(" {
                let begin = end + 1
                end = begin; nesting = 0
                var quote: Character?
                while end < chars.count {
                    let c = chars[end]
                    if c == "\\", end + 1 < chars.count { end += 2; continue }
                    if c == "\"" || c == "'" { quote = quote == c ? nil : (quote ?? c) }
                    if quote == nil {
                        if c == ")", nesting == 0 { break }
                        if c == "(" { nesting += 1 }; if c == ")" { nesting -= 1 }
                    }
                    end += 1
                }
                guard end < chars.count else { return nil }
                let value = String(chars[begin..<end]).trimmingCharacters(in: .whitespaces)
                let pieces = captures(#"^(<[^>]*>|\S*?)(?:\s+["'](.*)["'])?$"#, value)
                guard let pieces else { return nil }
                var url = pieces[0]
                if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
                return (label, url, pieces[1], end + 1)
            }
            var key = label
            if end < chars.count, chars[end] == "[", let close = chars[(end + 1)...].firstIndex(of: "]") {
                let explicit = String(chars[(end + 1)..<close]); if !explicit.isEmpty { key = explicit }; end = close + 1
            }
            guard let reference = references[referenceKey(key)] else { return nil }
            return (label, reference.url, reference.title, end)
        }
    }
}
