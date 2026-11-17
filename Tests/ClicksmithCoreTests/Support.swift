import Foundation
@testable import ClicksmithCore

/// Fresh temp folder per test.
func tempDir(_ name: String = #function) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("pc-tests/\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
func touch(_ dir: URL, _ name: String, _ text: String = "x") throws -> URL {
    let u = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: u)
    return u
}

func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

final class FakeEnvironment: ActionEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var _clipboard: String?
    private var _opened: [([URL], URL?)] = []
    var clipboardIn = ClipboardSnapshot()

    var clipboard: String? { lock.withLock { _clipboard } }
    var opened: [([URL], URL?)] { lock.withLock { _opened } }

    func setClipboard(_ text: String) async { lock.withLock { _clipboard = text } }
    func readClipboard() async -> ClipboardSnapshot { clipboardIn }
    func reveal(_ urls: [URL]) async {}
    func open(_ urls: [URL], withApplicationAt app: URL?) async throws { lock.withLock { _opened.append((urls, app)) } }
    func notify(title: String, body: String) async {}
    var chosenFolder: URL?
    func chooseFolder(prompt: String) async -> URL? { chosenFolder }
}

func context(_ inputs: [URL], options: [String: String] = [:], env: FakeEnvironment = FakeEnvironment(), ops: FileOps = FileOps(),
             paths: SharedPaths = SharedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("pc-tests/root-\(UUID().uuidString)")),
             settings: ClicksmithSettings = .init(), cancel: @escaping @Sendable () -> Bool = { false }) -> ActionContext {
    ActionContext(inputs: inputs, options: options, files: ops, environment: env, settings: settings, paths: paths, isCancelled: cancel)
}
