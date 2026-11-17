import Foundation

/// Where an action lives in menus and the palette.
public enum ActionGroup: String, Codable, Sendable, CaseIterable {
    case convert, compress, create, copy, organize, open, image, media, document, qr, text, tools, app

    public var title: String {
        switch self {
        case .convert: "Convert"
        case .compress: "Compress"
        case .create: "New File"
        case .copy: "Copy"
        case .organize: "Organize"
        case .open: "Open With"
        case .image: "Image"
        case .media: "Media"
        case .document: "Documents"
        case .qr: "QR & Barcodes"
        case .text: "Text"
        case .tools: "Tools"
        case .app: "Clicksmith"
        }
    }

    public var symbol: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .create: "doc.badge.plus"
        case .copy: "doc.on.doc"
        case .organize: "tray.full"
        case .open: "arrow.up.forward.app"
        case .image: "photo"
        case .media: "film"
        case .document: "doc.richtext"
        case .qr: "qrcode"
        case .text: "text.quote"
        case .tools: "wrench.and.screwdriver"
        case .app: "bolt.circle"
        }
    }
}

/// One menu entry of an action with preset options (e.g. "Convert → JPEG").
public struct ActionVariant: Codable, Sendable, Hashable {
    public var title: String
    public var symbol: String?
    public var options: [String: String]
    /// Restrict this variant to these extensions (empty = inherit from the action).
    public var extensions: Set<String>

    public init(_ title: String, symbol: String? = nil, options: [String: String], extensions: Set<String> = []) {
        self.title = title; self.symbol = symbol; self.options = options; self.extensions = extensions
    }
}

/// Static description of an action. Drives menus, `csx list`, the palette and settings.
public struct ActionDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var symbol: String
    public var group: ActionGroup
    public var summary: String
    /// Lower-cased extensions; empty = any file or folder; "/" = folders.
    public var extensions: Set<String>
    public var contexts: Set<MenuContext>
    public var minCount: Int
    public var maxCount: Int?
    /// When non-empty, the menu shows one entry per variant (in a submenu titled `title`).
    public var variants: [ActionVariant]
    /// Long jobs show progress in the menu bar and can be cancelled.
    public var isLongRunning: Bool
    /// Hidden from menus by default (still in palette / CLI).
    public var hiddenByDefault: Bool
    /// Options of the single menu entry (actions without variants).
    public var entryOptions: [String: String] = [:]

    public init(id: String, title: String, symbol: String, group: ActionGroup, summary: String = "",
                extensions: Set<String> = [], contexts: Set<MenuContext> = [.items], minCount: Int = 1, maxCount: Int? = nil,
                variants: [ActionVariant] = [], isLongRunning: Bool = false, hiddenByDefault: Bool = false) {
        self.id = id; self.title = title; self.symbol = symbol; self.group = group; self.summary = summary
        self.extensions = extensions; self.contexts = contexts; self.minCount = minCount; self.maxCount = maxCount
        self.variants = variants; self.isLongRunning = isLongRunning
        self.hiddenByDefault = hiddenByDefault || Self.builtIntoMacOS.contains(id)
    }

    /// macOS already does these (Finder, Quick Actions, Archive Utility): off by default to keep the menu short.
    /// Each can be turned back on in Settings ▸ Menu.
    public static let builtIntoMacOS: Set<String> = [
        "copy.name", "copy.info", "tools.checksum",          // Get Info, ⌥⌘C Copy as Pathname
        "tools.unzip",                                        // double-click (Archive Utility)
        "organize.batchRename",                               // Finder ▸ Rename…
        "organize.cut", "organize.moveHere",                  // ⌘C then ⌥⌘V
        "media.convertVideo", "media.convertAudio",           // Quick Action "Encode Selected Video/Audio Files"
        "pdf.fromImages",                                     // Quick Action "Create PDF"
        "pdf.split",                                          // Preview
        "tools.zip",                                          // Finder ▸ Compress
        // Rarely used: off by default to keep the menu short.
        "copy.shellPath", "organize.copyTo", "organize.moveTo", "qr.makeFromClipboard", "app.open",
    ]
}

/// What every Clicksmith action implements. Actions never touch files directly: they use `context.files`.
public protocol PowerAction: Sendable {
    var descriptor: ActionDescriptor { get }
    func run(_ context: ActionContext) async throws -> ActionResult
    /// Menu shape that depends on state (favourite folders, installed apps, cut items…).
    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu
}

public struct MenuEnvironment: Sendable {
    public var settings: ClicksmithSettings
    public var paths: SharedPaths
    public init(settings: ClicksmithSettings, paths: SharedPaths) { self.settings = settings; self.paths = paths }
}

public enum DynamicMenu: Sendable, Equatable {
    case standard                    // use the descriptor as is
    case hidden                      // not in the menu right now
    case variants([ActionVariant])   // replace descriptor.variants
    case title(String)               // rename the single entry
    case entry(title: String, options: [String: String])   // single entry with baked-in options
}

public extension PowerAction {
    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu { .standard }
}

public struct ActionResult: Sendable, Equatable {
    public var created: [URL]
    public var changed: [URL]
    public var message: String?
    public var failures: [Failure]
    /// Stopped early by the user. Outputs listed above still exist (and are journaled).
    public var cancelled = false
    /// Inputs that a move action actually moved (Move Here keeps the rest cut).
    public var movedSources: [String] = []
    /// Select new files in Finder (e.g. New File, so the user can type a name).
    public var revealCreated = false
    /// Folder to add to "recent destinations".
    public var rememberFolder: URL?
    /// Menu depends on state this action changed (e.g. cut items): app rewrites menu.json.
    public var menuChanged = false

    public struct Failure: Sendable, Equatable {
        public var url: URL?
        public var message: String
        public init(url: URL?, message: String) { self.url = url; self.message = message }
    }

    public init(created: [URL] = [], changed: [URL] = [], message: String? = nil, failures: [Failure] = []) {
        self.created = created; self.changed = changed; self.message = message; self.failures = failures
    }

    public static let none = ActionResult()
}

public enum PowerError: Error, LocalizedError, Sendable, Equatable {
    case unknownAction(String)
    case badInput(String)
    case missingOption(String)
    case unsupported(String)
    case cancelled
    case failed(String, detail: String? = nil)

    /// Technical detail for logs and `csx`, not for the user.
    public var detail: String? { if case .failed(_, let d) = self { d } else { nil } }

    public var errorDescription: String? {
        switch self {
        case .unknownAction(let id): "Unknown action “\(id)”."
        case .badInput(let s): s
        case .missingOption(let o): "Missing option “\(o)”."
        case .unsupported(let s): s
        case .cancelled: "Cancelled."
        case .failed(let s, _): s   // detail is for logs (`detail`), never shown to the user
        }
    }
}

/// Convenience for actions that process each input file independently.
/// Gives progress, cancellation between items, and per-file error collection for free.
public protocol PerFileAction: PowerAction {
    /// Returns the files it created.
    func process(_ url: URL, _ context: ActionContext) async throws -> [URL]
}

public extension PerFileAction {
    func run(_ context: ActionContext) async throws -> ActionResult {
        var result = ActionResult()
        let total = context.inputs.count
        for (i, url) in context.inputs.enumerated() {
            // Cancel keeps partial results: earlier outputs exist and must stay visible + undoable.
            if (try? context.checkCancelled()) == nil { result.cancelled = true; return result }
            await context.progress.update(done: i, total: total, current: url.lastPathComponent)
            do {
                result.created += try await process(url, context)
            } catch PowerError.cancelled {
                result.cancelled = true; return result
            } catch is CancellationError {
                result.cancelled = true; return result
            } catch {
                result.failures.append(.init(url: url, message: error.localizedDescription))
            }
        }
        await context.progress.update(done: total, total: total, current: nil)
        return result
    }
}
