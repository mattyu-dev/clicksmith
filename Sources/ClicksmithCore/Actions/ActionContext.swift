import Foundation

/// Side effects outside the file system. The app gives the real one; tests give a fake.
public protocol ActionEnvironment: Sendable {
    func setClipboard(_ text: String) async
    func readClipboard() async -> ClipboardSnapshot
    func reveal(_ urls: [URL]) async
    func open(_ urls: [URL], withApplicationAt app: URL?) async throws
    func notify(title: String, body: String) async
    /// Ask the user for a folder (NSOpenPanel in the app). nil = cancelled or no UI (CLI).
    func chooseFolder(prompt: String) async -> URL?
}

/// Raw clipboard data handed to Core (Core never reads NSPasteboard itself).
public struct ClipboardSnapshot: Sendable, Equatable {
    public var string: String?
    public var png: Data?
    public var rtf: Data?
    public var html: String?
    public var fileURLs: [URL]

    public init(string: String? = nil, png: Data? = nil, rtf: Data? = nil, html: String? = nil, fileURLs: [URL] = []) {
        self.string = string; self.png = png; self.rtf = rtf; self.html = html; self.fileURLs = fileURLs
    }
}

/// Progress sink. Thread-safe; UI observes it.
public protocol ProgressSink: Sendable {
    func update(done: Int, total: Int, current: String?) async
}

public struct NoProgress: ProgressSink {
    public init() {}
    public func update(done: Int, total: Int, current: String?) async {}
}

/// Everything an action needs to run once.
public struct ActionContext: Sendable {
    public var inputs: [URL]
    /// Where outputs go when they are not "next to the input" (folder background clicks).
    public var targetDirectory: URL
    public var options: [String: String]
    public var files: FileOps
    public var environment: ActionEnvironment
    public var progress: ProgressSink
    public var settings: ClicksmithSettings
    public var paths: SharedPaths
    public var isCancelled: @Sendable () -> Bool

    public init(inputs: [URL], targetDirectory: URL? = nil, options: [String: String] = [:], files: FileOps,
                environment: ActionEnvironment, progress: ProgressSink = NoProgress(),
                settings: ClicksmithSettings = .init(), paths: SharedPaths = .standard, isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) {
        self.inputs = inputs
        self.targetDirectory = targetDirectory ?? inputs.first?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        self.options = options; self.files = files; self.environment = environment; self.progress = progress
        self.settings = settings; self.paths = paths; self.isCancelled = isCancelled
    }

    public func checkCancelled() throws {
        if isCancelled() || Task.isCancelled { throw PowerError.cancelled }
    }

    public func option(_ key: String) throws -> String {
        guard let v = options[key], !v.isEmpty else { throw PowerError.missingOption(key) }
        return v
    }

    public func option(_ key: String, default value: String) -> String { options[key].flatMap { $0.isEmpty ? nil : $0 } ?? value }
}
