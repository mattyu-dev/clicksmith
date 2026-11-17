import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct OutputNamerTests {
    @Test func finderStyleNumbers() {
        #expect(OutputNamer.fileName(base: "a", ext: "jpg", index: 1) == "a.jpg")
        #expect(OutputNamer.fileName(base: "a", ext: "jpg", index: 2) == "a 2.jpg")
        #expect(OutputNamer.fileName(base: "folder", ext: "", index: 3) == "folder 3")
    }
    @Test func baseWithSuffix() {
        #expect(OutputNamer.base(for: URL(fileURLWithPath: "/x/IMG 1.heic"), suffix: "small") == "IMG 1 small")
        #expect(OutputNamer.base(for: URL(fileURLWithPath: "/x/archive.tar.gz")) == "archive.tar")
    }
}

@Suite struct FileOpsTests {
    @Test func produceNeverOverwrites() throws {
        let d = try tempDir(); let input = try touch(d, "photo.heic")
        try touch(d, "photo.jpg", "ORIGINAL")
        let ops = FileOps()
        let a = try ops.produce(from: input, ext: "jpg") { try Data("new1".utf8).write(to: $0) }
        let b = try ops.produce(from: input, ext: "jpg") { try Data("new2".utf8).write(to: $0) }
        #expect(a.lastPathComponent == "photo 2.jpg")
        #expect(b.lastPathComponent == "photo 3.jpg")
        #expect(try String(contentsOf: d.appendingPathComponent("photo.jpg"), encoding: .utf8) == "ORIGINAL")
        #expect(ops.recorded.count == 2)
        #expect(names(d) == ["photo 2.jpg", "photo 3.jpg", "photo.heic", "photo.jpg"])
    }

    @Test func writerThatWritesNothingFails() throws {
        let d = try tempDir()
        #expect(throws: PowerError.self) { try FileOps().produce(base: "x", ext: "txt", in: d) { _ in } }
        #expect(names(d).isEmpty)
    }

    @Test func renameRefusesToReplace() throws {
        let d = try tempDir(); let a = try touch(d, "a.txt", "A"); try touch(d, "b.txt", "B")
        #expect(throws: POSIXError.self) { try FileOps().rename(a, to: "b.txt") }
        #expect(try String(contentsOf: d.appendingPathComponent("b.txt"), encoding: .utf8) == "B")
    }

    @Test func caseOnlyRenameWorks() throws {
        let d = try tempDir(); let a = try touch(d, "readme.md")
        let r = try FileOps().rename(a, to: "README.md")
        #expect(r.lastPathComponent == "README.md")
        #expect(names(d) == ["README.md"])
    }

    @Test func invalidNamesRejected() throws {
        let d = try tempDir(); let a = try touch(d, "a.txt")
        for bad in ["", "x/y", ".", ".."] {
            #expect(throws: PowerError.self) { try FileOps().rename(a, to: bad) }
        }
    }

    @Test func moveAndCopyPickFreeNames() throws {
        let src = try tempDir("src"), dst = try tempDir("dst")
        let a = try touch(src, "a.txt", "1"); try touch(dst, "a.txt", "old")
        let ops = FileOps()
        let c = try ops.copy(a, into: dst)
        #expect(c.lastPathComponent == "a 2.txt")
        let m = try ops.move(a, into: dst)
        #expect(m.lastPathComponent == "a 3.txt")
        #expect(names(src).isEmpty)
        #expect(try String(contentsOf: dst.appendingPathComponent("a.txt"), encoding: .utf8) == "old")
    }
}

@Suite struct UndoJournalTests {
    func journal() throws -> UndoJournal { UndoJournal(directory: try tempDir("journal")) }

    @Test func undoTrashesCreatedAndRestoresRenames() throws {
        let d = try tempDir(); let j = try journal()
        let a = try touch(d, "a.txt")
        let ops = FileOps()
        try ops.write(Data("new".utf8), base: "made", ext: "txt", in: d)
        try ops.rename(a, to: "renamed.txt")
        let tx = try #require(try ops.commit(to: j, actionID: "t", title: "T"))
        #expect(names(d) == ["made.txt", "renamed.txt"])
        let rep = j.undo(tx)
        #expect(rep.skipped.isEmpty)
        #expect(names(d) == ["a.txt"])
        #expect(j.list().isEmpty)
    }

    @Test func undoSkipsFilesEditedSince() throws {
        let d = try tempDir(); let j = try journal()
        let ops = FileOps()
        let made = try ops.write(Data("v1".utf8), base: "made", ext: "txt", in: d)
        let tx = try #require(try ops.commit(to: j, actionID: "t", title: "T"))
        try Data("user edited this, longer".utf8).write(to: made)
        let rep = j.undo(tx)
        #expect(rep.reverted.isEmpty)
        #expect(rep.skipped.first?.1 == "modified since")
        #expect(names(d) == ["made.txt"])
    }

    @Test func undoDoesNotClobberReusedName() throws {
        let d = try tempDir(); let j = try journal()
        let a = try touch(d, "a.txt", "A")
        let ops = FileOps()
        try ops.rename(a, to: "b.txt")
        let tx = try #require(try ops.commit(to: j, actionID: "t", title: "T"))
        try touch(d, "a.txt", "NEW USER FILE")
        let rep = j.undo(tx)
        #expect(rep.skipped.count == 1)
        #expect(try String(contentsOf: d.appendingPathComponent("a.txt"), encoding: .utf8) == "NEW USER FILE")
        #expect(names(d) == ["a.txt", "b.txt"])
    }

    @Test func historyIsNewestFirstAndPruned() throws {
        let j = UndoJournal(directory: try tempDir("j"), limit: 3)
        for i in 0..<5 {
            try j.save(JournalTransaction(actionID: "a\(i)", title: "", date: Date(timeIntervalSinceNow: Double(i)), entries: []))
        }
        #expect(j.list().map(\.actionID) == ["a4", "a3", "a2"])
    }
}
