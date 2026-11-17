import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct OrganizeTests {
    func rootPaths() throws -> SharedPaths { let p = SharedPaths(root: try tempDir("root")); try p.ensureExists(); return p }

    @Test func copyToFavouriteKeepsOriginalAndRemembers() async throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try touch(src, "a.txt", "A"); try touch(dst, "a.txt", "existing")
        let r = try await CopyToAction().run(context([a], options: ["dest": dst.path]))
        #expect(r.created.map(\.lastPathComponent) == ["a 2.txt"])
        #expect(r.rememberFolder?.path == dst.path)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8) == "existing")
    }

    @Test func moveToChosenFolder() async throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try touch(src, "a.txt")
        let env = FakeEnvironment(); env.chosenFolder = dst
        let r = try await MoveToAction().run(context([a], options: ["dest": "?choose"], env: env))
        #expect(r.changed.map(\.lastPathComponent) == ["a.txt"])
        #expect(names(src).isEmpty)
    }

    @Test func chooserCancelIsCancel() async throws {
        let a = try touch(try tempDir(), "a.txt")
        await #expect(throws: PowerError.cancelled) { _ = try await MoveToAction().run(context([a], options: ["dest": "?choose"])) }
    }

    @Test func folderCannotGoInsideItself() async throws {
        let d = try tempDir(); let folder = d.appendingPathComponent("f", isDirectory: true)
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        await #expect(throws: PowerError.self) { _ = try await MoveToAction().run(context([folder], options: ["dest": inner.path])) }
        #expect(FileManager.default.fileExists(atPath: inner.path))
    }

    @Test func cutThenMoveHereThenUndo() async throws {
        let p = try rootPaths(); let j = UndoJournal(directory: p.journal)
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try touch(src, "a.txt"), b = try touch(src, "b.txt")
        let runner = ActionRunner(registry: ActionRegistry([CutAction(), MoveHereAction()]), journal: j,
                                  environment: FakeEnvironment(), settings: .init(), paths: p)
        let cut = await runner.run(ActionRequest(actionID: "organize.cut", paths: [a.path, b.path], source: .cli))
        #expect(cut.result.menuChanged)
        // Menu now offers "Move 2 Items Here".
        var on = ClicksmithSettings(); on.shownActions = ["organize.cut", "organize.moveHere"]   // off by default (⌥⌘V)
        let menu = ActionRegistry([CutAction(), MoveHereAction()]).menuModel(settings: on, paths: p)
        #expect("\(menu.items)".contains("Move 2 Items Here"))
        let here = await runner.run(ActionRequest(actionID: "organize.moveHere", paths: [], targetDirectory: dst.path, source: .cli))
        #expect(here.error == nil)
        #expect(names(dst) == ["a.txt", "b.txt"])
        #expect(Cutboard.load(p) == nil, "cutboard cleared")
        #expect(!"\(ActionRegistry([MoveHereAction()]).menuModel(settings: .init(), paths: p).items)".contains("Here"))
        j.undo(try #require(here.transaction))
        #expect(names(src) == ["a.txt", "b.txt"])
    }

    @Test func moveHereOntoAFolderMovesInto() async throws {
        let p = try rootPaths()
        let src = try tempDir("src"), parent = try tempDir("parent")
        let target = parent.appendingPathComponent("Target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let a = try touch(src, "a.txt")
        try Cutboard(urls: [a]).save(p)
        _ = try await MoveHereAction().run(context([target], paths: p))
        #expect(names(target) == ["a.txt"])
    }

    @Test func destinationsListFavouritesRecentsAndChoose() throws {
        let fav = try tempDir("fav"), rec = try tempDir("rec")
        var s = ClicksmithSettings(); s.favoriteFolders = [fav.path, "/does/not/exist"]; s.recentFolders = [rec.path, fav.path]
        let v = Destinations.variants(s)
        #expect(v.map { $0.options["dest"] } == [fav.path, rec.path, "?choose"])
        #expect(v[0].symbol == "star" && v[1].symbol == "clock")
    }

    @Test func transferSameDiskIsAtomicMove() throws {
        let src = try tempDir("src"), dst = try tempDir("dst"); let a = try touch(src, "a.txt", "A")
        let ops = FileOps()
        let out = try ops.transfer(a, into: dst)
        #expect(out.destination.lastPathComponent == "a.txt" && out.originalRemoved)
        #expect(ops.recorded.map(\.kind) == [.moved])
    }

    // MARK: Codex review of T-0011

    @Test("#1 cross-disk undo keeps the copy when the original left the Trash") func groupedUndoKeepsOnlyCopy() throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let copy = try touch(d, "copy.txt", "only survivor")
        let g = UUID()
        let tx = JournalTransaction(actionID: "organize.moveTo", title: "Move To", entries: [
            JournalEntry(kind: .created, from: "/elsewhere/orig.txt", to: copy.path, fingerprint: .of(copy), group: g),
            JournalEntry(kind: .trashed, from: d.appendingPathComponent("orig.txt").path, to: "/nonexistent/.Trash/orig.txt", fingerprint: nil, group: g),
        ])
        let rep = j.undo(tx)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(rep.reverted.isEmpty)
    }

    @Test("#1 retryable pair is kept in history") func groupedUndoRetryKept() throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let copy = try touch(d, "copy.txt"), trashed = try touch(d, "in-trash.txt")
        try touch(d, "orig.txt", "a new file now owns the original name")
        let g = UUID()
        let tx = JournalTransaction(actionID: "organize.moveTo", title: "Move To", entries: [
            JournalEntry(kind: .created, from: nil, to: copy.path, fingerprint: .of(copy), group: g),
            JournalEntry(kind: .trashed, from: d.appendingPathComponent("orig.txt").path, to: trashed.path, fingerprint: .of(trashed), group: g),
        ])
        _ = j.undo(tx)
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(j.list().first?.entries.count == 2)
    }

    @Test("#2 a different file at a cut path is never moved") func cutIdentity() async throws {
        let p = try rootPaths(); let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try touch(src, "a.txt", "original")
        try Cutboard(urls: [a]).save(p)
        try FileManager.default.moveItem(at: a, to: src.appendingPathComponent("renamed.txt"))
        try touch(src, "a.txt", "impostor")
        await #expect(throws: PowerError.self) { _ = try await MoveHereAction().run(context([], paths: p).with(target: dst)) }
        #expect(names(dst).isEmpty)
    }

    @Test("#3 a click from an older menu is refused") func staleGeneration() async throws {
        let p = try rootPaths(); let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try touch(src, "a.txt"), b = try touch(src, "b.txt")
        try Cutboard(urls: [a]).save(p)
        let oldGen = Cutboard.load(p)!.generation.uuidString
        try Cutboard(urls: [b]).save(p)
        await #expect(throws: PowerError.self) {
            _ = try await MoveHereAction().run(context([], options: ["gen": oldGen], paths: p).with(target: dst))
        }
        #expect(names(dst).isEmpty)
    }

    @Test("#4 settling an old cut leaves a newer cut alone; #5 remaining items stay cut") func settle() throws {
        let p = try rootPaths(); let src = try tempDir("src")
        let a = try touch(src, "a.txt"), b = try touch(src, "b.txt")
        let first = Cutboard(urls: [a, b]); try first.save(p)
        Cutboard.settle(p, generation: first.generation, remaining: [first.items[1]])
        #expect(Cutboard.load(p)?.items.map(\.path) == [b.path])
        let newer = Cutboard(urls: [a]); try newer.save(p)
        Cutboard.settle(p, generation: first.generation, remaining: [])
        #expect(Cutboard.load(p)?.generation == newer.generation)
    }
}

extension ActionContext {
    func with(target: URL) -> ActionContext { var c = self; c.targetDirectory = target; return c }
}
