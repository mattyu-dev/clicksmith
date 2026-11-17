import Foundation

/// What the Finder extension shows. Written by the app, read by the extension.
public struct MenuModel: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var generated: Date
    /// Top-level title of the submenu in Finder ("Clicksmith").
    public var rootTitle: String
    /// Show items flat in the context menu instead of one submenu.
    public var flatten: Bool
    public var items: [MenuNode]

    public init(version: Int = MenuModel.currentVersion, generated: Date = Date(), rootTitle: String = "Clicksmith", flatten: Bool = false, items: [MenuNode]) {
        self.version = version; self.generated = generated; self.rootTitle = rootTitle; self.flatten = flatten; self.items = items
    }
}

/// When a menu entry is visible.
public enum MenuContext: String, Codable, Sendable, CaseIterable {
    case items       // right-click on selected files/folders
    case container   // right-click on folder background
    case sidebar     // right-click in sidebar
    case toolbar     // toolbar button menu
}

public indirect enum MenuNode: Codable, Sendable, Equatable {
    case action(MenuAction)
    case submenu(title: String, symbol: String?, children: [MenuNode])
    case separator
}

public struct MenuAction: Codable, Sendable, Equatable {
    public var actionID: String
    public var title: String
    public var symbol: String?
    public var contexts: Set<MenuContext>
    /// Lower-cased file extensions accepted; empty = any. "/" means folders.
    public var extensions: Set<String>
    public var minCount: Int
    public var maxCount: Int?
    /// Extra options baked into this entry (e.g. format=jpeg).
    public var options: [String: String]

    public init(actionID: String, title: String, symbol: String? = nil, contexts: Set<MenuContext> = [.items], extensions: Set<String> = [], minCount: Int = 1, maxCount: Int? = nil, options: [String: String] = [:]) {
        self.actionID = actionID; self.title = title; self.symbol = symbol; self.contexts = contexts
        self.extensions = extensions; self.minCount = minCount; self.maxCount = maxCount; self.options = options
    }

    /// Does this entry apply to the current Finder selection?
    public func matches(context: MenuContext, selection: [URL]) -> Bool {
        guard contexts.contains(context) else { return false }
        // Background / toolbar entries act on the folder itself, not on a file selection.
        if context == .container || context == .toolbar { return true }
        guard selection.count >= minCount else { return false }
        if let maxCount, selection.count > maxCount { return false }
        guard !extensions.isEmpty else { return true }
        return selection.allSatisfy { url in
            if url.hasDirectoryPath { return extensions.contains("/") }
            return extensions.contains(url.pathExtension.lowercased())
        }
    }
}

public extension MenuModel {
    static func load(from url: URL) throws -> MenuModel {
        try JSONDecoder.clicksmith.decode(MenuModel.self, from: Data(contentsOf: url))
    }
    func write(to url: URL) throws {
        try JSONEncoder.clicksmith.encode(self).write(to: url, options: .atomic)
    }
}

public extension JSONEncoder {
    static var clicksmith: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .deferredToDate; return e  // lossless (IPC compares dates)
    }
}
public extension JSONDecoder {
    static var clicksmith: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate; return d }
}
