import Foundation

/// User settings shared by app, CLI and (through menu.json) the Finder extension.
public struct ClicksmithSettings: Codable, Sendable, Equatable {
    public var hiddenActions: Set<String> = []
    /// Actions that are hidden by default but the user turned on.
    public var shownActions: Set<String> = []
    /// Put actions directly in the context menu instead of a "Clicksmith" submenu.
    public var flattenMenu = false
    public var menuTitle = "Clicksmith"
    /// Show action groups as submenus (Convert ▸, Copy ▸ …).
    public var groupSubmenus = false
    public var favoriteFolders: [String] = []
    public var recentFolders: [String] = []
    /// Bundle id of the preferred code editor for "Open in Editor".
    public var preferredEditor: String?
    public var revealOutputs = false

    public init() {}

    /// "groupByKind": new key (2026-11-16) so the old saved default (groupSubmenus=true) does not keep the old nested menu.
    enum CodingKeys: String, CodingKey {
        case hiddenActions, shownActions, flattenMenu, menuTitle, favoriteFolders, recentFolders, preferredEditor, revealOutputs
        case groupSubmenus = "groupByKind"
    }

    public init(from decoder: Decoder) throws {
        // Tolerant decoding: new keys get defaults, old files keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClicksmithSettings()
        hiddenActions = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenActions) ?? d.hiddenActions
        shownActions = try c.decodeIfPresent(Set<String>.self, forKey: .shownActions) ?? d.shownActions
        flattenMenu = try c.decodeIfPresent(Bool.self, forKey: .flattenMenu) ?? d.flattenMenu
        menuTitle = try c.decodeIfPresent(String.self, forKey: .menuTitle) ?? d.menuTitle
        groupSubmenus = try c.decodeIfPresent(Bool.self, forKey: .groupSubmenus) ?? d.groupSubmenus
        favoriteFolders = try c.decodeIfPresent([String].self, forKey: .favoriteFolders) ?? d.favoriteFolders
        recentFolders = try c.decodeIfPresent([String].self, forKey: .recentFolders) ?? d.recentFolders
        preferredEditor = try c.decodeIfPresent(String.self, forKey: .preferredEditor)
        revealOutputs = try c.decodeIfPresent(Bool.self, forKey: .revealOutputs) ?? d.revealOutputs
    }

    /// Missing file → defaults. Unreadable file → moved aside to `settings.broken-<time>.json`
    /// before defaults are used, so a later save never destroys it (review #3).
    public static func load(_ paths: SharedPaths) -> ClicksmithSettings {
        guard let data = try? Data(contentsOf: paths.settingsFile) else { return .init() }
        if let s = try? JSONDecoder.clicksmith.decode(ClicksmithSettings.self, from: data) { return s }
        let aside = paths.root.appendingPathComponent("settings.broken-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: paths.settingsFile, to: aside)
        return .init()
    }

    public func save(_ paths: SharedPaths) throws {
        try paths.ensureExists()
        try JSONEncoder.clicksmith.encode(self).write(to: paths.settingsFile, options: .atomic)
    }
}

public extension SharedPaths {
    var settingsFile: URL { root.appendingPathComponent("settings.json") }
}

public extension ClicksmithSettings {
    func isVisible(_ d: ActionDescriptor) -> Bool {
        !hiddenActions.contains(d.id) && (!d.hiddenByDefault || shownActions.contains(d.id))
    }
}
