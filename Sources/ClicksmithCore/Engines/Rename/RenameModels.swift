import Foundation

public enum RenameRule: Codable, Sendable, Hashable {
    public enum CaseStyle: String, Codable, Sendable, Hashable, CaseIterable {
        case lower, upper, title, sentence, camel, pascal, kebab, snake
    }

    public enum Position: String, Codable, Sendable, Hashable {
        case prefix, suffix
    }

    public enum DateSource: String, Codable, Sendable, Hashable {
        case created, modified, exifTaken, now
    }

    public enum ExtensionChange: Codable, Sendable, Hashable {
        case lower, upper, set(String), remove
    }

    case prefix(String)
    case suffix(String)
    case replace(find: String, with: String, caseSensitive: Bool)
    case regex(pattern: String, template: String)
    case changeCase(CaseStyle)
    case trimWhitespace
    case collapseWhitespace
    case removeCharacters(set: String)
    case sequence(start: Int, step: Int, padding: Int, position: Position, separator: String)
    case datePrefix(source: DateSource, format: String)
    case `extension`(ExtensionChange)
    case insert(text: String, at: Int)
    case truncate(maxLength: Int)
}

public struct RenameItem: Sendable {
    /// Caller-supplied metadata keeps date rules independent of metadata readers and the clock.
    public struct Facts: Sendable {
        public let isDirectory: Bool
        public let created: Date?
        public let modified: Date?
        public let exifDate: Date?
        public let now: Date
        /// Zone used to print dates. App uses the Mac's zone (EXIF wall-clock is parsed in the same zone).
        public let timeZone: TimeZone

        public init(isDirectory: Bool = false, created: Date? = nil, modified: Date? = nil, exifDate: Date? = nil, now: Date = Date(),
                    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) {
            self.timeZone = timeZone
            self.isDirectory = isDirectory
            self.created = created
            self.modified = modified
            self.exifDate = exifDate
            self.now = now
        }
    }

    public let url: URL
    public let facts: Facts

    public init(url: URL, facts: Facts = .init()) {
        self.url = url
        self.facts = facts
    }
}

public enum RenameConflict: String, Codable, Sendable, Hashable {
    case duplicateInBatch, existsOnDisk, invalidName, unchanged

    var message: String {
        switch self {
        case .duplicateInBatch: "More than one selected file uses the same source or destination."
        case .existsOnDisk: "The destination is already occupied."
        case .invalidName: "The name or a rename rule is invalid."
        case .unchanged: "The name has not changed."
        }
    }
}

public struct RenamePlan: Sendable, Hashable {
    public let source: URL
    public let newName: String
    public let conflict: RenameConflict?

    public init(source: URL, newName: String, conflict: RenameConflict? = nil) {
        self.source = source
        self.newName = newName
        self.conflict = conflict
    }
}
