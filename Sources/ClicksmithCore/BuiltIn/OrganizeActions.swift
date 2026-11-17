import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Destinations shared by Copy To / Move To

enum Destinations {
    static let choose = "?choose"

    /// Favourites first, then recents not already in favourites, then "Choose Folder…".
    static func variants(_ s: ClicksmithSettings) -> [ActionVariant] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [ActionVariant] = []
        for (path, symbol) in s.favoriteFolders.map({ ($0, "star") }) + s.recentFolders.map({ ($0, "clock") }) {
            guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
            seen.insert(path)
            out.append(ActionVariant(display(path), symbol: symbol, options: ["dest": path]))
        }
        out.append(ActionVariant("Choose Folder…", symbol: "folder.badge.plus", options: ["dest": choose]))
        return out
    }

    static func display(_ path: String) -> String {
        let home = SharedPaths.realHome().path
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString)
        let shortParent = parent.hasPrefix(home) ? "~" + parent.substring(from: home.count) : parent as String
        return "\(name)  —  \(shortParent)"
    }

    static func resolve(_ c: ActionContext, verb: String) async throws -> URL {
        let dest = c.option("dest", default: choose)
        if dest == choose {
            guard let u = await c.environment.chooseFolder(prompt: "\(verb) \(c.inputs.count) item\(c.inputs.count == 1 ? "" : "s") to…") else {
                throw PowerError.cancelled
            }
            return u
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dest, isDirectory: &isDir), isDir.boolValue else {
            throw PowerError.badInput("Folder not found: \(dest)")
        }
        return URL(fileURLWithPath: dest, isDirectory: true)
    }

    /// A folder cannot go inside itself.
    static func checkNotInside(_ items: [URL], _ dest: URL) throws {
        let d = dest.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for u in items where u.hasDirectoryPath || (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            if d.hasPrefix(p) { throw PowerError.badInput("“\(u.lastPathComponent)” cannot go inside itself.") }
        }
    }
}

struct CopyToAction: PowerAction {
    let descriptor = ActionDescriptor(id: "organize.copyTo", title: "Copy To", symbol: "plus.rectangle.on.folder", group: .organize,
                                      summary: "Copy to a favourite, recent or chosen folder.", isLongRunning: true)
    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu { .variants(Destinations.variants(env.settings)) }

    func run(_ c: ActionContext) async throws -> ActionResult {
        let dest = try await Destinations.resolve(c, verb: "Copy")
        try Destinations.checkNotInside(c.inputs, dest)
        var r = ActionResult(); r.rememberFolder = dest
        for (i, u) in c.inputs.enumerated() {
            if (try? c.checkCancelled()) == nil { r.cancelled = true; break }
            await c.progress.update(done: i, total: c.inputs.count, current: u.lastPathComponent)
            do { r.created.append(try c.files.copy(u, into: dest)) }
            catch { r.failures.append(.init(url: u, message: error.localizedDescription)) }
        }
        r.message = "Copied \(r.created.count) item\(r.created.count == 1 ? "" : "s") to \(dest.lastPathComponent)."
        return r
    }
}

struct MoveToAction: PowerAction {
    let descriptor = ActionDescriptor(id: "organize.moveTo", title: "Move To", symbol: "folder", group: .organize,
                                      summary: "Move to a favourite, recent or chosen folder. Other disks: copy, then original to Trash.",
                                      isLongRunning: true)
    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu { .variants(Destinations.variants(env.settings)) }

    func run(_ c: ActionContext) async throws -> ActionResult {
        let dest = try await Destinations.resolve(c, verb: "Move")
        try Destinations.checkNotInside(c.inputs, dest)
        return try await Self.moveAll(c.inputs, into: dest, c)
    }

    static func moveAll(_ items: [URL], into dest: URL, _ c: ActionContext) async throws -> ActionResult {
        var r = ActionResult(); r.rememberFolder = dest
        for (i, u) in items.enumerated() {
            if (try? c.checkCancelled()) == nil { r.cancelled = true; break }
            await c.progress.update(done: i, total: items.count, current: u.lastPathComponent)
            if u.deletingLastPathComponent().standardizedFileURL.path == dest.standardizedFileURL.path { r.movedSources.append(u.path); continue }
            do {
                let t = try c.files.transfer(u, into: dest, isCancelled: c.isCancelled)
                if t.originalRemoved {
                    r.changed.append(t.destination); r.movedSources.append(u.path)
                } else {
                    r.created.append(t.destination)        // the copy exists: always report it
                    if t.cancelled { r.cancelled = true; break }
                    r.failures.append(.init(url: u, message: t.problem ?? "Original left in place."))
                }
            } catch PowerError.cancelled {
                r.cancelled = true; break
            } catch {
                r.failures.append(.init(url: u, message: error.localizedDescription))
            }
        }
        r.message = "Moved \(r.changed.count) item\(r.changed.count == 1 ? "" : "s") to \(dest.lastPathComponent)."
        return r
    }
}

// MARK: - Cut / Move Here

/// Files marked with "Cut", waiting for "Move Here". Stored in the shared folder.
/// Each item keeps its file identity, so a different file that later takes the same path is never moved.
/// `generation` ties a Finder menu entry to the cut it was built from (stale clicks are refused).
public struct Cutboard: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var path: String
        public var device: Int64
        public var inode: UInt64

        public init?(_ url: URL) {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { return nil }
            path = url.path; device = Int64(st.st_dev); inode = UInt64(st.st_ino)
        }

        /// Same file still at this path?
        public var isIntact: Bool {
            var st = stat()
            return lstat(path, &st) == 0 && Int64(st.st_dev) == device && UInt64(st.st_ino) == inode
        }
    }

    public var items: [Item]
    public var generation: UUID
    public var date: Date

    public init(urls: [URL], date: Date = Date()) {
        items = urls.compactMap(Item.init); generation = UUID(); self.date = date
    }

    static func file(_ p: SharedPaths) -> URL { p.root.appendingPathComponent("cutboard.json") }
    static let lock = NSLock()   // serializes read-modify-write inside this process

    public static func load(_ p: SharedPaths) -> Cutboard? {
        guard var c = try? JSONDecoder.clicksmith.decode(Cutboard.self, from: Data(contentsOf: file(p))) else { return nil }
        c.items = c.items.filter(\.isIntact)
        return c.items.isEmpty ? nil : c
    }
    public func save(_ p: SharedPaths) throws {
        try p.ensureExists()
        try JSONEncoder.clicksmith.encode(self).write(to: Self.file(p), options: .atomic)
    }
    public static func clear(_ p: SharedPaths) { try? FileManager.default.removeItem(at: file(p)) }

    /// After a Move Here: keep only `remaining`, and only if the board is still the same generation.
    static func settle(_ p: SharedPaths, generation: UUID, remaining: [Item]) {
        lock.withLock {
            guard let raw = try? JSONDecoder.clicksmith.decode(Cutboard.self, from: Data(contentsOf: file(p))),
                  raw.generation == generation else { return }     // a newer Cut happened: leave it alone
            if remaining.isEmpty { clear(p) } else {
                var c = raw; c.items = remaining; try? c.save(p)
            }
        }
    }
}

struct CutAction: PowerAction {
    let descriptor = ActionDescriptor(id: "organize.cut", title: "Cut", symbol: "scissors", group: .organize,
                                      summary: "Mark items, then right-click a folder background › Move Here.")
    func run(_ c: ActionContext) async throws -> ActionResult {
        let board = Cutboard(urls: c.inputs)
        try Cutboard.lock.withLock { try board.save(c.paths) }
        var r = ActionResult(message: "Cut \(board.items.count) item\(board.items.count == 1 ? "" : "s"). Right-click where they go › Move Here.")
        r.menuChanged = true
        return r
    }
}

struct MoveHereAction: PowerAction {
    let descriptor = ActionDescriptor(id: "organize.moveHere", title: "Move Here", symbol: "arrow.down.doc", group: .organize,
                                      contexts: [.container, .items], minCount: 0, isLongRunning: true)

    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu {
        guard let cb = Cutboard.load(env.paths) else { return .hidden }
        let n = cb.items.count
        let title = n == 1 ? "Move “\((cb.items[0].path as NSString).lastPathComponent)” Here" : "Move \(n) Items Here"
        return .entry(title: title, options: ["gen": cb.generation.uuidString])
    }

    func run(_ c: ActionContext) async throws -> ActionResult {
        guard let cb = Cutboard.load(c.paths) else { throw PowerError.badInput("Nothing is cut. Use Cut first.") }
        if let g = c.options["gen"], g != cb.generation.uuidString {
            throw PowerError.badInput("The cut items changed since this menu opened. Right-click again.")
        }
        // Background click → targetDirectory. Click on a folder → into that folder. Click on a file → its folder.
        let dest: URL = {
            if c.inputs.count == 1, let u = c.inputs.first, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return u }
            return c.inputs.first?.deletingLastPathComponent() ?? c.targetDirectory
        }()
        let items = cb.items.map { URL(fileURLWithPath: $0.path) }
        try Destinations.checkNotInside(items, dest)
        var r = try await MoveToAction.moveAll(items, into: dest, c)
        r.rememberFolder = nil
        // Keep what did not move (failed, cancelled, not reached); drop what moved.
        let moved = Set(r.movedSources)
        Cutboard.settle(c.paths, generation: cb.generation, remaining: cb.items.filter { !moved.contains($0.path) })
        r.menuChanged = true
        return r
    }
}

// MARK: - Open in Editor

public struct EditorApp: Sendable, Equatable {
    public var bundleID: String
    public var name: String
}

public enum Editors {
    /// Known code editors, most popular first.
    public static let known: [EditorApp] = [
        .init(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code"),
        .init(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        .init(bundleID: "dev.zed.Zed", name: "Zed"),
        .init(bundleID: "com.exafunction.windsurf", name: "Windsurf"),
        .init(bundleID: "com.sublimetext.4", name: "Sublime Text"),
        .init(bundleID: "com.panic.Nova", name: "Nova"),
        .init(bundleID: "com.barebones.bbedit", name: "BBEdit"),
        .init(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
        .init(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        .init(bundleID: "com.jetbrains.WebStorm", name: "WebStorm"),
        .init(bundleID: "com.jetbrains.pycharm", name: "PyCharm"),
        .init(bundleID: "com.vscodium", name: "VSCodium"),
        .init(bundleID: "com.coteditor.CotEditor", name: "CotEditor"),
        .init(bundleID: "com.macromates.TextMate", name: "TextMate"),
    ]

    public static func appURL(_ bundleID: String) -> URL? {
        #if canImport(AppKit)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        #else
        return nil
        #endif
    }

    public static func installed() -> [EditorApp] { known.filter { appURL($0.bundleID) != nil } }
}

struct OpenInEditorAction: PowerAction {
    let descriptor = ActionDescriptor(id: "open.editor", title: "Open in Editor", symbol: "chevron.left.forwardslash.chevron.right",
                                      group: .open, summary: "Open files or folders in your code editor.",
                                      extensions: OpenInEditorAction.codeExtensions, contexts: [.items, .container], minCount: 0)

    /// Folders and text/code files only: an editor is useless for photos, videos, PDFs.
    static let codeExtensions: Set<String> = ["/", "", // "" = Makefile, Dockerfile, .env, .gitignore
        "txt", "md", "markdown", "json", "yaml", "yml", "toml", "xml", "plist", "csv", "tsv",
        "html", "htm", "css", "scss", "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "php", "go", "rs", "swift",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "sh", "bash", "zsh", "fish", "sql", "lua", "r", "dart",
        "env", "ini", "conf", "cfg", "log", "gitignore", "dockerfile", "makefile", "gradle", "tex", "svg"]

    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu {
        var list = Editors.installed()
        if let pref = env.settings.preferredEditor, let i = list.firstIndex(where: { $0.bundleID == pref }) {
            list.insert(list.remove(at: i), at: 0)
        }
        return .variants(list.map { ActionVariant($0.name, options: ["app": $0.bundleID]) })
    }

    func run(_ c: ActionContext) async throws -> ActionResult {
        let id = c.option("app", default: c.settings.preferredEditor ?? Editors.installed().first?.bundleID ?? "")
        guard let app = Editors.appURL(id) else { throw PowerError.unsupported("No code editor found.") }
        let items = c.inputs.isEmpty ? [c.targetDirectory] : c.inputs
        try await c.environment.open(items, withApplicationAt: app)
        return .none
    }
}
