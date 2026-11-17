import Darwin
import Foundation
import Testing
@testable import ClicksmithCore

@Suite(.serialized) struct JournalReviewTests {
    @Test func deniedTrashStillAllowsUndoOfIndependentRename() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: storage)
        }
        let original = try touch(directory, "a.txt", "original")
        let ops = FileOps(), journal = UndoJournal(directory: storage)
        try ops.rename(original, to: "renamed.txt")
        let made = try ops.write(Data("created".utf8), base: "made", ext: "txt", in: locked)
        let tx = try #require(try ops.commit(to: journal, actionID: "test", title: "Test"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let report = journal.undo(tx)
        #expect(report.reverted.contains(original.path))
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOf: made, encoding: .utf8) == "created")
        #expect(journal.last?.entries.count == 1, "Only the failed Trash entry remains retryable")
        let pending = try FileManager.default.contentsOfDirectory(at: journal.pendingDirectory, includingPropertiesForKeys: nil)
        #expect(pending.filter { $0.pathExtension != "lock" }.isEmpty)
    }

    @Test func twoThousandDurableRenamesTakeUnderTwoSeconds() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let inputs = try (0..<2_000).map { try touch(directory, "source-\($0)") }
        let journal = UndoJournal(directory: storage)
        let ops = try FileOps(journal: journal, actionID: "rename", title: "Rename")
        let start = ContinuousClock.now
        for (index, input) in inputs.enumerated() {
            try ops.moveExact(input, to: directory.appendingPathComponent("renamed-\(index)"))
        }
        let tx = try ops.commit(to: journal, actionID: "rename", title: "Rename")
        let elapsed = start.duration(to: .now)
        print("2000 durable renames including commit: \(elapsed)")
        #expect(elapsed < .seconds(2))
        #expect(tx?.entries.count == 2_000)
        #expect(journal.last?.entries.count == 2_000)
    }

    @Test func completedSessionsLeaveNoPendingLockFiles() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        var file = try touch(directory, "original")
        for index in 0..<20 {
            let ops = try FileOps(journal: journal, actionID: "rename", title: "Rename")
            file = try ops.rename(file, to: "renamed-\(index)")
            try ops.commit(to: journal, actionID: "rename", title: "Rename")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.pendingDirectory.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func orphanLockCleanupExcludesALiveOwner(live: Bool) throws {
        let storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        try FileManager.default.createDirectory(at: journal.pendingDirectory, withIntermediateDirectories: true)
        let id = UUID(), fd = try journal.lockPending(id)
        let file = journal.pendingDirectory.appendingPathComponent("\(id.uuidString).lock")
        if live {
            #expect(!journal.recoverPending().hasFindings)
            #expect(FileOps.entryExists(file))
        }
        close(fd)
        #expect(!journal.recoverPending().hasFindings)
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.pendingDirectory.path).isEmpty)
    }

    @Test func uncertainRecordIsReportedOnceAndArchivedWithoutTouchingFiles() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "old"), moved = directory.appendingPathComponent("moved")
        let record = PendingJournalRecord(transaction: .init(actionID: "move", title: "Move", entries: []),
                                          intent: .init(kind: .moved, from: original.path, to: moved.path, fingerprint: .of(original)))
        try FileManager.default.createDirectory(at: journal.pendingDirectory, withIntermediateDirectories: true)
        let file = journal.pendingDirectory.appendingPathComponent("\(record.transaction.id.uuidString).json")
        let evidence = try JSONEncoder.clicksmith.encode(record)
        try evidence.write(to: file)
        try FileOps.renameExclusive(original, moved)
        try Data("user work".utf8).write(to: moved)
        #expect(!journal.recoverPending().problems.isEmpty)
        #expect(!journal.recoverPending().hasFindings)
        let inspected = journal.directory.appendingPathComponent("inspected").appendingPathComponent(file.lastPathComponent)
        #expect(try Data(contentsOf: inspected) == evidence)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "user work")
    }

    @Test func recoverySummaryCapsPaths() {
        var report = JournalRecoveryReport()
        report.recovered = [.init(actionID: "move", title: "Move", entries: (0..<15).map {
            .init(kind: .moved, from: "/source-\($0)", to: "/result-\($0)", fingerprint: nil)
        })]
        let summary = report.summary
        #expect(summary.contains("/result-9"))
        #expect(!summary.contains("/result-10"))
        #expect(summary.contains("+5 more"))
    }

    @Test func startupSummarySharesOneCapAcrossFilesAndRequests() {
        var report = JournalRecoveryReport()
        report.recovered = [.init(actionID: "move", title: "Move", entries: (0..<6).map {
            .init(kind: .moved, from: "/source-\($0)", to: "/result-\($0)", fingerprint: nil)
        })]
        let ids = (0..<10).map { _ in UUID() }
        let summary = report.summary(interrupted: ids)
        #expect(summary.contains(ids[3].uuidString))
        #expect(!summary.contains(ids[4].uuidString))
        #expect(summary.contains("+6 more"))
        #expect(summary.components(separatedBy: "\n").count == 12)
    }

    @Test func disappearedPendingReadIsAlreadyFinished() throws {
        let storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        try FileManager.default.createDirectory(at: journal.pendingDirectory, withIntermediateDirectories: true)
        let file = journal.pendingDirectory.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: storage.appendingPathComponent("finished"))
        #expect(!journal.recoverPending().hasFindings)
    }

    @Test func completeIntentSurvivesATornReceiptLine() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let journal = UndoJournal(directory: storage)
        let original = try touch(directory, "original", "precious"), moved = directory.appendingPathComponent("moved")
        let transaction = JournalTransaction(actionID: "rename", title: "Rename", entries: [])
        let intent = JournalEntry(kind: .moved, from: original.path, to: moved.path, fingerprint: .of(original))
        let header = try JSONSerialization.jsonObject(with: JSONEncoder.clicksmith.encode(PendingJournalRecord(transaction: transaction)))
        let entry = try JSONSerialization.jsonObject(with: JSONEncoder.clicksmith.encode(intent))
        var data = try JSONSerialization.data(withJSONObject: ["kind": "opened", "record": header])
        data.append(0x0A)
        data.append(try JSONSerialization.data(withJSONObject: ["kind": "intent", "entry": entry]))
        data.append(0x0A)
        data.append(Data("{\"kind\":\"rece".utf8))
        try FileManager.default.createDirectory(at: journal.pendingDirectory, withIntermediateDirectories: true)
        try data.write(to: journal.pendingDirectory.appendingPathComponent("\(transaction.id.uuidString).jsonl"))
        try FileOps.renameExclusive(original, moved)
        let report = journal.recoverPending()
        #expect(report.recovered.count == 1)
        #expect(report.recovered.first?.entries.first?.to == moved.path)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "precious")
        #expect(journal.undo(try #require(journal.last)).skipped.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "precious")
    }

    @Test func cancelledIntentDoesNotHideTheNextReceiptDuringRecovery() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let original = try touch(directory, "original", "precious"), moved = directory.appendingPathComponent("moved")
        let journal = UndoJournal(directory: storage)
        var session: JournalSession? = try JournalSession(journal: journal, actionID: "rename", title: "Rename")
        try session?.begin(.init(kind: .moved, from: original.path, to: directory.appendingPathComponent("unused").path, fingerprint: .of(original)))
        session?.cancel()
        let intent = JournalEntry(kind: .moved, from: original.path, to: moved.path, fingerprint: .of(original))
        try session?.begin(intent)
        try FileOps.renameExclusive(original, moved)
        session?.complete(intent)
        session = nil
        let report = journal.recoverPending()
        #expect(report.problems.isEmpty)
        #expect(report.recovered.first?.entries == [intent])
        #expect(journal.undo(try #require(journal.last)).skipped.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "precious")
    }
}
