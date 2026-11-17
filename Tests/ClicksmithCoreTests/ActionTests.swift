import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct BuiltInActionTests {
    @Test func copyPathAndName() async throws {
        let d = try tempDir(); let a = try touch(d, "a b.txt"); let b = try touch(d, "c.txt")
        let env = FakeEnvironment()
        _ = try await CopyPathAction().run(context([a, b], env: env))
        #expect(env.clipboard == "\(a.path)\n\(b.path)")
        _ = try await CopyNameAction().run(context([a, b], env: env))
        #expect(env.clipboard == "a b.txt\nc.txt")
    }

    @Test func shellQuoting() {
        #expect(ShellQuote.quote("/usr/bin") == "/usr/bin")
        #expect(ShellQuote.quote("/tmp/a b") == "'/tmp/a b'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("") == "''")
    }

    @Test func checksumsMatchKnownValues() throws {
        let d = try tempDir(); let f = try touch(d, "abc.txt", "abc")
        #expect(try ChecksumAction.hash(f, algorithm: "sha256") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try ChecksumAction.hash(f, algorithm: "md5") == "900150983cd24fb0d6963f7d28e17f72")
        #expect(try ChecksumAction.hash(f, algorithm: "sha1") == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test func zipExcludesJunkAndUnzipRoundTrips() async throws {
        let d = try tempDir(); let folder = d.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try touch(folder, "main.swift", "print(1)"); try touch(folder, ".DS_Store", "junk")
        let ops = FileOps()
        let r = try await ZipAction().run(context([folder], ops: ops))
        let zip = try #require(r.created.first)
        #expect(zip.lastPathComponent == "proj.zip")
        let listing = try Self.unzipList(zip)
        #expect(listing.contains("proj/main.swift"))
        #expect(!listing.contains(".DS_Store"))
        try FileManager.default.removeItem(at: folder)
        let u = try await UnzipAction().run(context([zip], ops: ops))
        let out = try #require(u.created.first)
        #expect(out.lastPathComponent == "proj")
        // One top-level folder: no double nesting (T-0016).
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("main.swift").path))
    }

    static func unzipList(_ zip: URL) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-Z1", zip.path]
        let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

/// Per-file action that records order and can be cancelled midway.
struct SlowAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "test.slow", title: "Slow", symbol: "tortoise", group: .tools)
    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        if url.lastPathComponent.hasPrefix("bad") { throw PowerError.failed("bad file") }
        return [try c.files.produce(from: url, ext: "out") { try Data().write(to: $0) }]
    }
}

@Suite struct RunnerTests {
    func runner(_ actions: [any PowerAction], env: FakeEnvironment = FakeEnvironment()) throws -> ActionRunner {
        ActionRunner(registry: ActionRegistry(actions), journal: UndoJournal(directory: try tempDir("j")), environment: env, settings: .init())
    }

    @Test func perFileCollectsFailuresAndContinues() async throws {
        let d = try tempDir()
        let files = try ["a", "bad1", "c"].map { try touch(d, "\($0).txt") }
        let r = try runner([SlowAction()])
        let o = await r.run(ActionRequest(actionID: "test.slow", paths: files.map(\.path), source: .cli))
        #expect(o.error == nil)
        #expect(o.result.created.map(\.lastPathComponent) == ["a.out", "c.out"])
        #expect(o.result.failures.count == 1)
        #expect(o.transaction?.entries.count == 2, "partial work is undoable")
    }

    @Test func cancelStopsBetweenItems() async throws {
        let d = try tempDir()
        let files = try (0..<5).map { try touch(d, "f\($0).txt") }
        let r = try runner([SlowAction()])
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let o = await r.run(ActionRequest(actionID: "test.slow", paths: files.map(\.path), source: .cli),
                            isCancelled: { calls.n += 1; return calls.n > 2 })
        #expect(o.error == .cancelled)
        #expect(names(d).filter { $0.hasSuffix(".out") }.count == 2)
        #expect(o.transaction?.entries.count == 2)
    }

    @Test func unknownActionAndMissingFiles() async throws {
        let r = try runner([SlowAction()])
        #expect(await r.run(ActionRequest(actionID: "nope", paths: [], source: .cli)).error == .unknownAction("nope"))
        let o = await r.run(ActionRequest(actionID: "test.slow", paths: ["/definitely/not/here.txt"], source: .cli))
        #expect(o.error != nil)
    }
}

@Suite struct RegistryTests {
    @Test func standardHasUniqueIDs() {
        let ids = ActionRegistry.standard().descriptors.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("copy.path"))
    }

    @Test func menuHonorsHiddenAndGroups() {
        var s = ClicksmithSettings(); s.hiddenActions = ["copy.name"]
        s.groupSubmenus = true   // off by default since 2026-11-16; still supported
        let m = ActionRegistry.standard().menuModel(settings: s)
        func ids(_ nodes: [MenuNode]) -> [String] {
            nodes.flatMap { n -> [String] in
                switch n { case .action(let a): [a.actionID]; case .submenu(_, _, let c): ids(c); case .separator: [] }
            }
        }
        let all = ids(m.items)
        #expect(!all.contains("copy.name"))
        #expect(all.contains("copy.path"))
        #expect(m.items.contains { if case .submenu("Copy", _, _) = $0 { true } else { false } })
    }

    @Test func variantsBecomeSubmenu() {
        let node = ActionRegistry.node(ChecksumAction().descriptor)
        guard case let .submenu(title, _, kids) = node else { Issue.record("expected submenu"); return }
        #expect(title == "Copy Checksum")
        #expect(kids.count == 3)
    }

    @Test func settingsDecodeTolerantly() throws {
        let s = try JSONDecoder().decode(ClicksmithSettings.self, from: Data(#"{"flattenMenu": true}"#.utf8))
        #expect(s.flattenMenu)
        #expect(s.menuTitle == "Clicksmith")
    }
}
