import Foundation

extension RenameEngine {
    static let maximumNameBytes = 255

    static func transform(_ item: RenameItem, index: Int, rules: [RenameRule]) -> RenamePlan {
        let original = item.url.lastPathComponent
        var ext = item.facts.isDirectory ? "" : (original as NSString).pathExtension
        var stem = item.facts.isDirectory ? original : (original as NSString).deletingPathExtension
        var valid = true
        let locale = Locale(identifier: "en_US_POSIX")

        for rule in rules {
            switch rule {
            case .prefix(let text): stem = text + stem
            case .suffix(let text): stem += text
            case .replace(let find, let replacement, let sensitive):
                guard !find.isEmpty else { valid = false; continue }
                stem = stem.replacingOccurrences(
                    of: find, with: replacement, options: sensitive ? [] : [.caseInsensitive]
                )
            case .regex(let pattern, let template):
                do {
                    let regex = try NSRegularExpression(pattern: pattern)
                    stem = regex.stringByReplacingMatches(
                        in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: template
                    )
                } catch { valid = false }
            case .changeCase(let style): stem = changeCase(stem, to: style)
            case .trimWhitespace: stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
            case .collapseWhitespace:
                var collapsed = ""
                var wasWhitespace = false
                for character in stem {
                    if character.isWhitespace {
                        if !wasWhitespace { collapsed += " " }
                        wasWhitespace = true
                    } else {
                        collapsed.append(character)
                        wasWhitespace = false
                    }
                }
                stem = collapsed
            case .removeCharacters(let set):
                let characters = Set(set)
                stem = String(stem.filter { !characters.contains($0) })
            case .sequence(let start, let step, let padding, let position, let separator):
                let product = index.multipliedReportingOverflow(by: step)
                let value = start.addingReportingOverflow(product.partialValue)
                guard !product.overflow, !value.overflow, (0...255).contains(padding) else {
                    valid = false; continue
                }
                let digits = String(value.partialValue.magnitude)
                let number = (value.partialValue < 0 ? "-" : "")
                    + String(repeating: "0", count: max(0, padding - digits.count)) + digits
                stem = position == .prefix ? number + separator + stem : stem + separator + number
            case .datePrefix(let source, let format):
                let date: Date?
                switch source {
                case .created: date = item.facts.created
                case .modified: date = item.facts.modified
                case .exifTaken: date = item.facts.exifDate
                case .now: date = item.facts.now
                }
                guard let date, !format.isEmpty, date.timeIntervalSinceReferenceDate.isFinite else {
                    valid = false; continue
                }
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = item.facts.timeZone
                formatter.dateFormat = format
                stem = formatter.string(from: date) + stem
            case .extension(let change):
                guard !item.facts.isDirectory else { continue }
                switch change {
                case .lower: ext = ext.lowercased(with: locale)
                case .upper: ext = ext.uppercased(with: locale)
                case .set(let value): ext = value
                case .remove: ext = ""
                }
            case .insert(let text, let offset):
                guard offset >= 0, offset <= stem.count else { valid = false; continue }
                stem.insert(contentsOf: text, at: stem.index(stem.startIndex, offsetBy: offset))
            case .truncate(let length):
                guard length >= 0 else { valid = false; continue }
                stem = String(stem.prefix(length))
            }
        }

        let name = ext.isEmpty ? stem : stem + "." + ext
        valid = valid && !stem.isEmpty && validName(name, original: original) && item.url.isFileURL
        return RenamePlan(source: item.url, newName: name, conflict: valid ? nil : .invalidName)
    }

    static func validName(_ name: String, original: String) -> Bool {
        let scalars = name.unicodeScalars
        // A separator or leading dot can share a grapheme with a combining mark.
        return !name.isEmpty && name.utf8.count <= maximumNameBytes && name != "." && name != ".."
            && !scalars.contains(where: { $0 == "/" || $0 == ":" || $0 == "\0" })
            && (scalars.first != "." || original.unicodeScalars.first == ".")
    }

    private static func changeCase(_ text: String, to style: RenameRule.CaseStyle) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        switch style {
        case .lower: return text.lowercased(with: locale)
        case .upper: return text.uppercased(with: locale)
        case .title: return text.capitalized(with: locale)
        case .sentence:
            var result = text.lowercased(with: locale)
            if let index = result.firstIndex(where: { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }) {
                let end = result.index(after: index)
                result.replaceSubrange(index..<end, with: String(result[index]).uppercased(with: locale))
            }
            return result
        case .camel, .pascal, .kebab, .snake:
            let separated = text
                .replacingOccurrences(of: #"(\p{Lu})(\p{Lu}\p{Ll})"#, with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: #"([\p{Ll}\p{N}])(\p{Lu})"#, with: "$1 $2", options: .regularExpression)
            let words = separated.components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted)
                .filter { !$0.isEmpty }.map { $0.lowercased(with: locale) }
            switch style {
            case .kebab: return words.joined(separator: "-")
            case .snake: return words.joined(separator: "_")
            case .camel:
                return words.enumerated().map { $0.offset == 0 ? $0.element : capitalizedWord($0.element) }.joined()
            default: return words.map(capitalizedWord).joined()
            }
        }
    }

    private static func capitalizedWord(_ word: String) -> String {
        String(word.prefix(1)).uppercased(with: Locale(identifier: "en_US_POSIX")) + word.dropFirst()
    }
}
