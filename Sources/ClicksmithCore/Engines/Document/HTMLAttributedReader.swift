import AppKit

/// A local, non-network HTML reader for document text. No WebKit service or run loop.
/// It retains structural rich text; browser CSS layout and external resources are not rendered.
enum HTMLAttributedReader {
    static func read(_ html: String, isCancelled: () -> Bool) throws -> NSAttributedString {
        let reader = Reader()
        return try reader.read(html, isCancelled: isCancelled)
    }

    private final class Reader {
        let output = NSMutableAttributedString(string: "")
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        var stack: [(tag: String, attributes: [NSAttributedString.Key: Any])] = []
        var lists: [(ordered: Bool, next: Int, marker: NSTextList)] = []
        var tables: [(table: NSTextTable, row: Int, column: Int)] = []
        var ignored: [String] = []
        var preDepth = 0
        var lastCharacter: Character?
        static let attributeRegex = try? NSRegularExpression(pattern: "([a-zA-Z_:][a-zA-Z0-9_:.-]*)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+)))?")
        static let entityRegex = try? NSRegularExpression(pattern: "&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[A-Za-z]+);")
        static let whitespaceRegex = try? NSRegularExpression(pattern: "\\s+")
        static let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}", "copy": "©", "reg": "®", "mdash": "—", "ndash": "–", "hellip": "…", "bull": "•", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"]

        func read(_ html: String, isCancelled: () -> Bool) throws -> NSAttributedString {
            let pattern = "(?s)<!--.*?-->|<![^>]*>|<(?:[^>\"']|\"[^\"]*\"|'[^']*')*>|[^<]+|<"
            let tokens = try NSRegularExpression(pattern: pattern)
            let source = html as NSString
            // Enumeration avoids allocating a second copy of the whole token stream.
            var failure: Error?
            tokens.enumerateMatches(in: html, range: NSRange(location: 0, length: source.length)) { match, _, stop in
                do {
                    try DocumentIO.checkCancellation(isCancelled)
                    guard let match else { return }
                    let token = source.substring(with: match.range)
                    if token.hasPrefix("<"), token.hasSuffix(">") {
                        try self.tag(token)
                    } else if self.ignored.isEmpty {
                        var text = Self.entities(token)
                        if self.preDepth == 0 {
                            if let regex = Self.whitespaceRegex {
                                text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: " ")
                            }
                            if self.lastCharacter == nil || self.lastCharacter == "\n" || self.lastCharacter == " " {
                                if text.hasPrefix(" ") { text.removeFirst() }
                            }
                        }
                        self.append(text)
                    }
                } catch { failure = error; stop.pointee = true }
            }
            if let failure { throw failure }
            return output
        }

        func append(_ text: String) {
            output.append(NSAttributedString(string: text, attributes: attributes))
            if let last = text.last { lastCharacter = last }
        }

        func newline() {
            if lastCharacter != nil, lastCharacter != "\n" { append("\n") }
        }

        func paragraph(_ change: (NSMutableParagraphStyle) -> Void) {
            let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            change(style)
            attributes[.paragraphStyle] = style
        }

        func font(_ trait: NSFontDescriptor.SymbolicTraits) {
            let old = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 12)
            let descriptor = old.fontDescriptor.withSymbolicTraits(old.fontDescriptor.symbolicTraits.union(trait))
            attributes[.font] = NSFont(descriptor: descriptor, size: old.pointSize) ?? old
        }

        func tag(_ token: String) throws {
            if token.hasPrefix("<!") || token.hasPrefix("<?") { return }
            let closing = token.hasPrefix("</")
            let body = String(token.dropFirst(closing ? 2 : 1).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard !name.isEmpty else { return }
            if ["head", "script", "style", "iframe", "object"].contains(name) {
                if closing {
                    if let index = ignored.lastIndex(of: name) { ignored.removeSubrange(index...) }
                } else { ignored.append(name) }
                return
            }
            guard ignored.isEmpty else { return }
            let blockTags = ["p", "div", "section", "article", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "ul", "ol", "li", "table", "tr"]
            if blockTags.contains(name), !(name == "p" && lastCharacter == "\t" && !lists.isEmpty) { newline() }
            if closing {
                if name == "td" || name == "th" { newline() }
                if name == "pre" { preDepth = max(0, preDepth - 1) }
                if name == "ul" || name == "ol" { if !lists.isEmpty { lists.removeLast() } }
                if name == "tr", !tables.isEmpty { tables[tables.count - 1].row += 1; tables[tables.count - 1].column = 0 }
                if name == "table", !tables.isEmpty { tables.removeLast() }
                if let index = stack.lastIndex(where: { $0.tag == name }) {
                    attributes = stack[index].attributes
                    stack.removeSubrange(index...)
                }
                return
            }
            let attrs = try Self.tagAttributes(body)
            let void = ["br", "hr", "img", "input", "meta", "link", "wbr", "source"].contains(name) || body.hasSuffix("/")
            if !void { stack.append((name, attributes)) }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(name.dropFirst()) ?? 1
                attributes[.font] = NSFont.boldSystemFont(ofSize: CGFloat(28 - level * 2))
                paragraph { $0.headerLevel = level; $0.paragraphSpacing = 10 }
            case "b", "strong", "th": font(.bold)
            case "i", "em": font(.italic)
            case "s", "del", "strike": attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case "u": attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case "pre": preDepth += 1; attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            case "code", "tt", "kbd", "samp": attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            case "blockquote": paragraph { $0.headIndent += 18; $0.firstLineHeadIndent += 18 }
            case "a":
                if let href = attrs["href"], let url = URL(string: href), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    attributes[.link] = url
                }
            case "ul", "ol":
                let start = min(1_000_000, max(1, Int(attrs["start"] ?? "1") ?? 1))
                let marker = NSTextList(markerFormat: name == "ol" ? .decimal : .disc, options: 0)
                marker.startingItemNumber = start
                lists.append((name == "ol", start, marker))
            case "li":
                if let list = lists.last {
                    let marker = list.ordered ? "\(list.next)." : "•"
                    paragraph {
                        $0.headIndent = CGFloat(self.lists.count * 18); $0.firstLineHeadIndent = $0.headIndent - 12
                        $0.textLists = self.lists.map(\.marker)
                    }
                    append(marker + "\t")
                    lists[lists.count - 1].next += 1
                }
            case "table":
                let table = NSTextTable(); table.numberOfColumns = 1
                table.setValue(100, type: .percentageValueType, for: .width)
                tables.append((table, 0, 0))
            case "br": append("\n")
            case "hr": newline(); append("────────\n")
            case "img": if let alt = attrs["alt"] { append(alt) }
            case "input": if attrs["type"]?.lowercased() == "checkbox" { append(attrs["checked"] == nil ? "☐ " : "☑ ") }
            default: break
            }
            if name == "td" || name == "th", !tables.isEmpty {
                newline()
                let index = tables.count - 1
                let state = tables[index]
                let span = min(100, max(1, Int(attrs["colspan"] ?? "1") ?? 1))
                state.table.numberOfColumns = max(state.table.numberOfColumns, state.column + span)
                let cell = NSTextTableBlock(table: state.table, startingRow: state.row, rowSpan: 1, startingColumn: state.column, columnSpan: span)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(4, type: .absoluteValueType, for: .padding)
                cell.setBorderColor(.gray)
                paragraph { $0.textBlocks = [cell] }
                tables[index].column += span
            }
            if let align = attrs["align"] { paragraph { $0.alignment = align == "right" ? .right : align == "center" ? .center : .left } }
        }

        static func tagAttributes(_ body: String) throws -> [String: String] {
            guard body.contains(where: { $0.isWhitespace }), let regex = attributeRegex else { return [:] }
            let source = body as NSString
            var result: [String: String] = [:]
            for match in regex.matches(in: body, range: NSRange(location: 0, length: source.length)).dropFirst() {
                let valueRange = (2...4).map { match.range(at: $0) }.first { $0.location != NSNotFound }
                result[source.substring(with: match.range(at: 1)).lowercased()] = valueRange.map { entities(source.substring(with: $0)) } ?? ""
            }
            return result
        }

        static func entities(_ text: String) -> String {
            guard text.contains("&"), let regex = entityRegex else { return text }
            let result = NSMutableString(string: text)
            let source = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
                let key = source.substring(with: match.range(at: 1))
                var value = namedEntities[key]
                if key.hasPrefix("#") {
                    let hex = key.lowercased().hasPrefix("#x")
                    if let n = UInt32(key.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(n) { value = String(scalar) }
                }
                if let value { result.replaceCharacters(in: match.range, with: value) }
            }
            return result as String
        }
    }
}
