import Darwin
import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct PendingJournalTests {
    @Test func legacyJournalWithoutNewOptionalFieldsStillDecodes() throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try touch(directory, "original", "precious")
        let tx = JournalTransaction(actionID: "move", title: "Move", entries: [
            .init(kind: .moved, from: original.path, to: original.path, fingerprint: .of(original))
        ])
        let encoded = try JSONEncoder.clicksmith.encode(tx)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        var fingerprint = try #require(entries[0]["fingerprint"] as? [String: Any])
        fingerprint.removeValue(forKey: "device")
        entries[0]["fingerprint"] = fingerprint
        entries[0].removeValue(forKey: "recoveryBookmark")
        json["entries"] = entries
        let decoded = try JSONDecoder.clicksmith.decode(JournalTransaction.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.id == tx.id)
        #expect(decoded.entries.first?.fingerprint?.matches(original) == true)
    }

    @Test func liveSessionIsNotRecoveredAndInterruptedTemporaryIsUndoable() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "precious")
        let temporary = directory.appendingPathComponent(FileOps.temporaryName(for: original))
        var ops: FileOps? = try FileOps(journal: journal, actionID: "rename", title: "Rename")
        try ops?.moveExact(original, to: temporary)
        let pendingFile = try #require(try FileManager.default.contentsOfDirectory(at: journal.pendingDirectory, includingPropertiesForKeys: nil).first { ["json", "jsonl"].contains($0.pathExtension) })
        let pending = try journal.readPending(pendingFile)
        #expect(pending.transaction.entries.map(\.to) == [temporary.path])
        #expect(!journal.recoverPending().hasFindings, "An active session holds an OS lock")
        ops = nil
        let recovered = journal.recoverPending()
        #expect(recovered.recovered.count == 1)
        #expect(recovered.summary.contains(temporary.path))
        #expect(FileOps.entryExists(temporary), "Recovery reports and journals, without replaying filesystem operations")
        #expect(journal.undo(try #require(journal.last)).skipped.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "precious")
        #expect(!journal.recoverPending().hasFindings)
    }

    @Test(arguments: [false, true])
    func crashOnEitherSideOfRenameUsesPersistedIntent(didRename: Bool) throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "precious"), moved = directory.appendingPathComponent("moved")
        var session: JournalSession? = try JournalSession(journal: journal, actionID: "move", title: "Move")
        try session?.begin(.init(kind: .moved, from: original.path, to: moved.path, fingerprint: .of(original)))
        if didRename { try FileOps.renameExclusive(original, moved) }
        // Release the process-owned lock without writing a receipt, like process exit.
        session = nil
        let report = journal.recoverPending()
        #expect(report.problems.isEmpty)
        #expect(report.recovered.count == (didRename ? 1 : 0))
        #expect(FileOps.entryExists(didRename ? moved : original))
        if didRename { #expect(journal.undo(try #require(journal.last)).skipped.isEmpty) }
        #expect(try String(contentsOf: original, encoding: .utf8) == "precious")
    }

    @Test func uncertainIntentKeepsEvidenceForLaterInspection() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "precious"), moved = directory.appendingPathComponent("moved")
        var session: JournalSession? = try JournalSession(journal: journal, actionID: "move", title: "Move")
        try session?.begin(.init(kind: .moved, from: original.path, to: moved.path, fingerprint: .of(original)))
        try FileOps.renameExclusive(original, moved)
        try Data("user changed this".utf8).write(to: moved)
        let id = try #require(session?.record.transaction.id)
        session = nil
        let report = journal.recoverPending()
        #expect(report.recovered.isEmpty)
        #expect(report.problems.contains { $0.contains(moved.path) })
        #expect(FileOps.entryExists(storage.appendingPathComponent("inspected").appendingPathComponent("\(id.uuidString).jsonl")))
        #expect(!journal.recoverPending().hasFindings)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "user changed this")
    }

    @Test func nativeTrashIntentLocatesMovedFileThroughBookmark() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "precious"), moved = directory.appendingPathComponent("fake-trash")
        var session: JournalSession? = try JournalSession(journal: journal, actionID: "trash", title: "Trash")
        let bookmark = try original.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try session?.begin(.init(kind: .trashed, from: original.path, to: original.path, fingerprint: .of(original), recoveryBookmark: bookmark))
        try FileOps.renameExclusive(original, moved)
        session = nil
        let report = journal.recoverPending()
        #expect(report.problems.isEmpty, "\(report.problems)")
        let recoveredPath = try #require(report.recovered.first?.entries.first?.to)
        #expect(URL(fileURLWithPath: recoveredPath).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        #expect(journal.undo(try #require(journal.last)).skipped.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "precious")
    }

    @Test func intentSaveFailurePreventsMoveAndCanBeRetried() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "precious"), moved = directory.appendingPathComponent("moved")
        let ops = try FileOps(journal: journal, actionID: "move", title: "Move")
        let pending = try #require(try FileManager.default.contentsOfDirectory(at: journal.pendingDirectory, includingPropertiesForKeys: nil).first { ["json", "jsonl"].contains($0.pathExtension) })
        try FileManager.default.removeItem(at: pending)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try ops.moveExact(original, to: moved) }
        #expect(FileOps.entryExists(original) && !FileOps.entryExists(moved))
        #expect(ops.recorded.isEmpty)
        try FileManager.default.removeItem(at: pending)
        try ops.moveExact(original, to: moved)
        #expect(try ops.commit(to: journal, actionID: "move", title: "Move")?.entries.count == 1)
    }

    @Test func failedCommitAndRecoverySavesStayRetryableWithoutDuplicates() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original"), moved = directory.appendingPathComponent("moved")
        let (pendingURL, blocker, commitFailed, recordedCount) = try interruptedFailedCommit(journal, original, moved)
        let evidence = try Data(contentsOf: pendingURL)
        #expect(commitFailed)
        #expect(recordedCount == 1)
        #expect(!journal.recoverPending().problems.isEmpty)
        #expect(FileOps.entryExists(storage.appendingPathComponent("inspected/retry").appendingPathComponent(pendingURL.lastPathComponent)))
        #expect(!journal.recoverPending().hasFindings, "A repeated failed save retries quietly after its first report")
        try FileManager.default.removeItem(at: blocker)
        #expect(journal.recoverPending().recovered.count == 1)
        #expect(journal.list().count == 1)
        #expect(!journal.recoverPending().hasFindings)
        #expect(try Data(contentsOf: storage.appendingPathComponent("inspected").appendingPathComponent(pendingURL.lastPathComponent)) == evidence)
    }

    @Test func failedRetryArchivalDoesNotTurnARetryableSaveIntoFinalInspection() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original"), moved = directory.appendingPathComponent("moved")
        let (pendingURL, historyBlocker, _, _) = try interruptedFailedCommit(journal, original, moved)
        let inspected = storage.appendingPathComponent("inspected")
        try FileManager.default.createDirectory(at: inspected, withIntermediateDirectories: true)
        let archiveBlocker = try touch(inspected, "retry", "blocker")
        #expect(!journal.recoverPending().problems.isEmpty)
        #expect(FileOps.entryExists(pendingURL), "An archival error must leave the original retry path intact")
        try FileManager.default.removeItem(at: historyBlocker)
        try FileManager.default.removeItem(at: archiveBlocker)
        #expect(journal.recoverPending().recovered.count == 1)
        #expect(journal.last?.entries.first?.to == moved.path)
        #expect(!journal.recoverPending().hasFindings)
    }

    /// Keep the FileOps lifetime out of Testing's captured assertion expressions.
    /// Return only values so recovery sees an abandoned session.
    private func interruptedFailedCommit(_ journal: UndoJournal, _ original: URL, _ moved: URL) throws -> (URL, URL, Bool, Int) {
        let ops = try FileOps(journal: journal, actionID: "move", title: "Move")
        try ops.moveExact(original, to: moved)
        let pendingURL = try #require(try FileManager.default.contentsOfDirectory(at: journal.pendingDirectory, includingPropertiesForKeys: nil).first { ["json", "jsonl"].contains($0.pathExtension) })
        let pending = try journal.readPending(pendingURL)
        let name = String(format: "%.6f-%@.json", pending.transaction.date.timeIntervalSinceReferenceDate, pending.transaction.id.uuidString)
        let blocker = journal.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        var failed = false
        do { try ops.commit(to: journal, actionID: "move", title: "Move") }
        catch { failed = true }
        return (pendingURL, blocker, failed, ops.recorded.count)
    }

    @Test func savedCommitWithLeftoverPendingDoesNotDuplicateHistory() throws {
        let storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        var session: JournalSession? = try JournalSession(journal: journal, actionID: "move", title: "Move")
        let tx = try #require(session?.record.transaction)
        try journal.save(tx)
        session = nil
        #expect(!journal.recoverPending().hasFindings)
        #expect(journal.list().count == 1)
        #expect(!FileOps.entryExists(journal.pendingFile(tx.id)))
    }
}
