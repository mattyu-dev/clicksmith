import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct CreateActionTests {
    @Test func newFileFromTemplateInFolderBackground() async throws {
        let d = try tempDir()
        var c = context([]); c.targetDirectory = d; c.options = ["template": "shell"]
        let r = try await NewFileAction().run(c)
        let out = try #require(r.created.first)
        #expect(out.lastPathComponent == "Untitled.sh")
        #expect(r.revealCreated)
        let perm = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(perm == 0o755)
        let again = try await NewFileAction().run(c)
        #expect(again.created.first?.lastPathComponent == "Untitled 2.sh")
    }

    @Test func dotfileTemplatesUseTheirName() async throws {
        let d = try tempDir()
        var c = context([d]); c.options = ["template": "gitignore"]
        let r = try await NewFileAction().run(c)
        #expect(r.created.first?.lastPathComponent == ".gitignore")
        #expect(r.created.first?.deletingLastPathComponent().standardizedFileURL == d.standardizedFileURL)
    }

    @Test func userTemplatesAppearAndCopy() async throws {
        let p = SharedPaths(root: try tempDir("root")); try p.ensureExists()
        try FileManager.default.createDirectory(at: UserTemplates.folder(p), withIntermediateDirectories: true)
        try touch(UserTemplates.folder(p), "Invoice.numbers", "x")
        guard case .variants(let v) = NewFileAction().dynamicMenu(.init(settings: .init(), paths: p)) else { Issue.record("variants"); return }
        #expect(v.first?.title == "Invoice.numbers")
        let d = try tempDir()
        var c = context([], paths: p); c.targetDirectory = d; c.options = ["user": "Invoice.numbers"]
        let r = try await NewFileAction().run(c)
        #expect(r.created.first?.lastPathComponent == "Invoice.numbers")
        c.options = ["user": "../../etc/passwd"]
        await #expect(throws: PowerError.self) { _ = try await NewFileAction().run(c) }
    }

    @Test func fromClipboardSavesJSONByteExact() async throws {
        let d = try tempDir()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: #"{"price": 19.99, "b": 1.0}"#)
        var c = context([], env: env); c.targetDirectory = d
        let r = try await NewFileFromClipboardAction().run(c)
        let out = try #require(r.created.first)
        #expect(out.pathExtension == "json")
        #expect(try String(contentsOf: out, encoding: .utf8).contains("19.99"))
    }

    @Test func emptyClipboardFails() async throws {
        var c = context([]); c.targetDirectory = try tempDir()
        await #expect(throws: PowerError.self) { _ = try await NewFileFromClipboardAction().run(c) }
    }
}

@Suite struct BatchRenameTests {
    @Test func headlessRulesRenameAndUndo() async throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let files = try ["IMG 1.JPG", "IMG 2.JPG"].map { try touch(d, $0) }
        let rules: [RenameRule] = [.replace(find: "IMG ", with: "trip-", caseSensitive: true), .extension(.lower)]
        let json = String(data: try JSONEncoder().encode(rules), encoding: .utf8)!
        let runner = ActionRunner(registry: ActionRegistry([BatchRenameAction()]), journal: j, environment: FakeEnvironment(), settings: .init())
        let o = await runner.run(ActionRequest(actionID: "organize.batchRename", paths: files.map(\.path), options: ["rules": json], source: .cli))
        #expect(o.error == nil, "\(String(describing: o.error))")
        #expect(names(d) == ["trip-1.jpg", "trip-2.jpg"])
        _ = j.undo(try #require(o.transaction))
        #expect(names(d) == ["IMG 1.JPG", "IMG 2.JPG"])
    }

    @Test func overridesAreCheckedForConflicts() throws {
        let d = try tempDir()
        let a = try touch(d, "a.txt"), b = try touch(d, "b.txt")
        let items = RenameSession.items([a, b])
        let plans = RenameSession.plans(items, rules: [], overrides: [a: "same.txt", b: "same.txt"])
        #expect(plans.allSatisfy { $0.conflict == .duplicateInBatch })
        let ok = RenameSession.plans(items, rules: [], overrides: [a: "x.txt"])
        #expect(ok.first { $0.source == a }?.conflict == nil)
    }

    @Test func swapNamesWorks() throws {
        let d = try tempDir()
        let a = try touch(d, "a.txt", "A"), b = try touch(d, "b.txt", "B")
        let plans = RenameSession.plans(RenameSession.items([a, b]), rules: [], overrides: [a: "b.txt", b: "a.txt"])
        try RenameSession.apply(plans, files: FileOps())
        #expect(try String(contentsOf: d.appendingPathComponent("a.txt"), encoding: .utf8) == "B")
    }

    @Test func withoutRulesItNeedsTheApp() async throws {
        let a = try touch(try tempDir(), "a.txt")
        await #expect(throws: PowerError.self) { _ = try await BatchRenameAction().run(context([a])) }
    }
}

/// Codex review of T-0012 part 1 (2026-11-16).
@Suite struct WiringReviewTests {
    @Test("#1 rename undo with the old name taken keeps the file and the history") func renameUndoRetry() throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let a = try touch(d, "a.txt", "A")
        let ops = FileOps()
        try RenameSession.apply(RenameSession.plans(RenameSession.items([a]), rules: [], overrides: [a: "b.txt"]), files: ops)
        let tx = try #require(try ops.commit(to: j, actionID: "r", title: "R"))
        #expect(tx.entries.count == 1, "staging moves collapse into one rename")
        try touch(d, "a.txt", "NEW")
        _ = j.undo(tx)
        #expect(names(d) == ["a.txt", "b.txt"], "no stranded temp file")
        let rest = try #require(j.last)
        try FileManager.default.removeItem(at: d.appendingPathComponent("a.txt"))
        _ = j.undo(rest)
        #expect(names(d) == ["a.txt"])
        #expect(try String(contentsOf: d.appendingPathComponent("a.txt"), encoding: .utf8) == "A")
    }

    @Test("#1 swap undo restores both") func swapUndo() throws {
        let d = try tempDir(); let j = UndoJournal(directory: try tempDir("j"))
        let a = try touch(d, "a.txt", "A"), b = try touch(d, "b.txt", "B")
        let ops = FileOps()
        try RenameSession.apply(RenameSession.plans(RenameSession.items([a, b]), rules: [], overrides: [a: "b.txt", b: "a.txt"]), files: ops)
        let tx = try #require(try ops.commit(to: j, actionID: "r", title: "R"))
        #expect(try String(contentsOf: a, encoding: .utf8) == "B")
        let rep = j.undo(tx)
        #expect(rep.skipped.isEmpty, "\(rep.skipped)")
        #expect(try String(contentsOf: a, encoding: .utf8) == "A")
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
    }

    @Test("#2 failed journal save keeps the records for a retry") func commitRetry() throws {
        let d = try tempDir(); let ops = FileOps()
        try ops.write(Data("x".utf8), base: "x", ext: "txt", in: d)
        let blocker = try touch(try tempDir(), "file")
        #expect(throws: (any Error).self) { try ops.commit(to: UndoJournal(directory: blocker.appendingPathComponent("j")), actionID: "a", title: "A") }
        #expect(ops.recorded.count == 1)
        #expect(try ops.commit(to: UndoJournal(directory: try tempDir("j")), actionID: "a", title: "A") != nil)
    }

    @Test("#3 special template names are refused") func templateNames() async throws {
        let p = SharedPaths(root: try tempDir("root")); try p.ensureExists()
        try FileManager.default.createDirectory(at: UserTemplates.folder(p), withIntermediateDirectories: true)
        var c = context([], paths: p); c.targetDirectory = try tempDir()
        for bad in ["", ".", "..", ".hidden", "../settings.json"] {
            c.options = ["user": bad]
            await #expect(throws: PowerError.self) { _ = try await NewFileAction().run(c) }
        }
    }

    @Test("#4 editing one row keeps rule errors on the others") func overrideKeepsRuleErrors() throws {
        let d = try tempDir(); let a = try touch(d, "a.txt"), b = try touch(d, "b.txt")
        let items = RenameSession.items([a, b])
        let rules: [RenameRule] = [.prefix("x "), .regex(pattern: "([", template: "$1")]
        let plans = RenameSession.plans(items, rules: rules, overrides: [a: "fine.txt"])
        #expect(plans.first { $0.source == b }?.conflict == .invalidName)
    }

    @Test("#5 a photo taken just after midnight keeps its day") func midnightExif() throws {
        let paris = TimeZone(identifier: "Europe/Paris")!
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = paris
        let taken = f.date(from: "2026:11:16 00:30:00")!
        let item = RenameItem(url: URL(fileURLWithPath: "/tmp/p.jpg"), facts: .init(exifDate: taken, timeZone: paris))
        let plan = RenameEngine.preview([item], rules: [.datePrefix(source: .exifTaken, format: "yyyy-MM-dd ")])
        #expect(plan[0].newName == "2026-11-16 p.jpg")
    }
}

@Suite struct MenuDesignTests {
    @Test("New File is one level, templates first, clipboard after a line") func newFileFlat() throws {
        let p = SharedPaths(root: try tempDir("root"))
        var grouped = ClicksmithSettings(); grouped.groupSubmenus = true
        let menu = ActionRegistry(BuiltInActions.all()).menuModel(settings: grouped, paths: p)
        guard case let .submenu(title, _, kids)? = menu.items.first else { Issue.record("no first submenu"); return }
        #expect(title == "New File")
        #expect(!kids.contains { if case .submenu = $0 { true } else { false } }, "no New File ▸ New File")
        #expect("\(kids)".contains("Text File"))
        guard case let .action(last)? = kids.last else { Issue.record("last is not an action"); return }
        #expect(last.title == "New File from Clipboard")
    }
}
