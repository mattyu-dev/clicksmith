import Foundation

/// Locations shared by the app and the sandboxed Finder extension.
/// The extension reaches them through a home-relative temporary exception (ADR-0003),
/// so paths are built from the *real* home, never the sandbox container.
public struct SharedPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static let bundleID = "dev.clicksmith.app"
    public static let extensionBundleID = "dev.clicksmith.app.finder"
    public static let urlScheme = "clicksmith"

    /// `~/Library/Application Support/Clicksmith` using the real home even inside a sandbox.
    /// `CLICKSMITH_ROOT` overrides it (tests, agents: keeps the real undo history clean).
    public static var standard: SharedPaths {
        if let r = ProcessInfo.processInfo.environment["CLICKSMITH_ROOT"], !r.isEmpty {
            return SharedPaths(root: URL(fileURLWithPath: r, isDirectory: true))
        }
        return SharedPaths(root: realHome()
            .appendingPathComponent("Library/Application Support/Clicksmith", isDirectory: true))
    }

    public var menuFile: URL { root.appendingPathComponent("menu.json") }
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
    public var heartbeat: URL { root.appendingPathComponent("extension-heartbeat.json") }

    public func requestFile(_ id: UUID) -> URL { inbox.appendingPathComponent("\(id.uuidString).json") }

    public func ensureExists() throws {
        for dir in [root, inbox, journal] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Real user home. In a sandbox, `NSHomeDirectory()` is the container; getpwuid is not.
    public static func realHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
