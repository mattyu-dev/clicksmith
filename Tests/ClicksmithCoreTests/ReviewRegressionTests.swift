import Foundation
import Testing
@testable import ClicksmithCore

/// Regressions for Codex review of T-0002 (2026-11-16). Numbers match the review.
@Suite struct ReviewRegressionTests {
    func runner(_ actions: [any PowerAction], journal: UndoJournal? = nil) throws -> ActionRunner {
        ActionRunner(registry: ActionRegistry(actions), journal: try journal ?? UndoJournal(directory: tempDir("j")),
                     environment: FakeEnvironment(), settings: .init())
    }

    @Test("1: a file named -m never becomes a zip option") func zipOptionInjection() async throws {
        let d = try tempDir()
        let dash = try touch(d, "-m", "dash"); let report = try touch(d, "report.txt", "keep me")
        let r = try await ZipAction().run(context([dash, report]))
        #expect(r.created.count == 1)
        #expect(FileManager.default.fileExists(atPath: report.path), "originals must survive")
        #expect(FileManager.default.fileExists(atPath: dash.path))
    }

    @Test("11: zip refuses items from different folders") func zipMixedParents() async throws {
        let a = try touch(try tempDir("a"), "one.txt"), b = try touch(try tempDir("b"), "two.txt")
        await #expect(throws: PowerError.self) { _ = try await ZipAction().run(context([a, b])) }
    }

    @Test("2: case-only rename keeps the file and never leaves a temp") func caseOnlyRenameIsClean() throws {
        let d = try tempDir(); let a = try touch(d, "photo.JPG", "data")
        let r = try FileOps().rename(a, to: "photo.jpg")
        #expect(r.lastPathComponent == "photo.jpg")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []) == ["photo.jpg"])
        #expect(try String(contentsOf: r, encoding: .utf8) == "data")
    }

    @Test("4: undo keeps an extracted folder the user added files to") func undoSkipsChangedFolder() async throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let folder = d.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try touch(folder, "a.txt")
        let zipOut = try await runner([ZipAction()], journal: j).run(ActionRequest(actionID: "tools.zip", paths: [folder.path], source: .cli))
        let zip = try #require(zipOut.result.created.first)
        let un = try await runner([UnzipAction()], journal: j).run(ActionRequest(actionID: "tools.unzip", paths: [zip.path], source: .cli))
        let extracted = try #require(un.result.created.first)
        try touch(extracted, "precious.txt", "user work")
        let rep = j.undo(try #require(un.transaction))
        #expect(rep.reverted.isEmpty)
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("precious.txt").path))
    }

    @Test("4: undo of an untouched extracted folder works") func undoCleanFolder() async throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let f = try touch(d, "x.txt")
        let z = try await runner([ZipAction()], journal: j).run(ActionRequest(actionID: "tools.zip", paths: [f.path], source: .cli))
        let un = try await runner([UnzipAction()], journal: j).run(ActionRequest(actionID: "tools.unzip", paths: [z.result.created[0].path], source: .cli))
        let rep = j.undo(try #require(un.transaction))
        #expect(rep.reverted.count == 1)
    }

    @Test("4: undo skips a file replaced by an atomic save with same size and date") func undoSkipsReplacedFile() throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let ops = FileOps()
        let made = try ops.write(Data("1234".utf8), base: "made", ext: "txt", in: d)
        let tx = try #require(try ops.commit(to: j, actionID: "t", title: "T"))
        let mdate = try #require(try FileManager.default.attributesOfItem(atPath: made.path)[.modificationDate] as? Date)
        let other = try touch(d, "tmp", "abcd")
        try FileManager.default.setAttributes([.modificationDate: mdate], ofItemAtPath: other.path)
        _ = try FileManager.default.replaceItemAt(made, withItemAt: other)
        #expect(j.undo(tx).reverted.isEmpty)
        #expect(try String(contentsOf: made, encoding: .utf8) == "abcd")
    }

    @Test("7: runner enforces counts and file types") func runnerValidates() async throws {
        let r = try runner([ZipAction(), UnzipAction()])
        let empty = await r.run(ActionRequest(actionID: "tools.zip", paths: [], source: .cli))
        #expect(empty.error != nil)
        let txt = try touch(try tempDir(), "a.txt")
        let wrongType = await r.run(ActionRequest(actionID: "tools.unzip", paths: [txt.path], source: .cli))
        #expect(wrongType.error != nil)
    }

    @Test("8: journal failure is reported, not hidden") func journalFailureSurfaces() async throws {
        let blocker = try touch(try tempDir(), "not-a-dir")   // a file where the journal folder should be
        let j = UndoJournal(directory: blocker.appendingPathComponent("journal"))
        let f = try touch(try tempDir(), "x.txt")
        let o = await try runner([ZipAction()], journal: j).run(ActionRequest(actionID: "tools.zip", paths: [f.path], source: .cli))
        #expect(o.result.created.isEmpty, "An unsavable intent must prevent file changes")
        #expect(o.journalError != nil)
        #expect(!o.succeeded)
    }

    @Test("9: cancel returns the partial results") func cancelKeepsPartialResults() async throws {
        let d = try tempDir()
        let files = try (0..<5).map { try touch(d, "f\($0).txt") }
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let o = await try runner([SlowAction()]).run(ActionRequest(actionID: "test.slow", paths: files.map(\.path), source: .cli),
                                                    isCancelled: { calls.n += 1; return calls.n > 2 })
        #expect(o.error == .cancelled)
        #expect(o.result.created.count == 2)
        #expect(o.result.cancelled)
    }

    @Test("10: entries recorded during commit are kept") func commitDetachesAtomically() throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let ops = FileOps()
        try ops.write(Data("a".utf8), base: "a", ext: "txt", in: d)
        _ = try ops.commit(to: j, actionID: "t", title: "T")
        try ops.write(Data("b".utf8), base: "b", ext: "txt", in: d)
        #expect(ops.recorded.count == 1)
    }

    @Test("5: a tool that floods stderr does not hang") func shellDrainsStderr() throws {
        // 1 MB to stderr then exit 1: must throw quickly with the tail of stderr, not deadlock.
        #expect(throws: PowerError.self) {
            try Shell.run("/bin/sh", ["-c", "head -c 1048576 /dev/zero | tr '\\\\0' x >&2; exit 1"])
        }
    }
}
