import Foundation
import Testing
@testable import ClicksmithCore

private final class RenameFixture {
    let directory: URL

    init(_ files: [String: String] = [:]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clicksmith-Rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, content) in files { try Data(content.utf8).write(to: url(name)) }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func item(_ name: String) -> RenameItem { .init(url: url(name)) }
    func plan(_ source: String, _ name: String, conflict: RenameConflict? = nil) -> RenamePlan {
        .init(source: url(source), newName: name, conflict: conflict)
    }
    func read(_ name: String) throws -> String { try String(contentsOf: url(name), encoding: .utf8) }
    func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }
    func move(_ source: URL, _ destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }
}

private enum RenameTestFailure: Error { case injected }

@Suite("Rename conflicts and moves")
struct RenameApplyTests {
    @Test func duplicateBatchTargets() throws {
        let fixture = try RenameFixture(["a.txt": "A", "b.txt": "B"])
        let plans = RenameEngine.preview([fixture.item("a.txt"), fixture.item("b.txt")], rules: [.regex(pattern: ".*", template: "x")])
        #expect(plans.allSatisfy { $0.conflict == .duplicateInBatch })
    }

    @Test func duplicateSourcesAreRejected() throws {
        let fixture = try RenameFixture(["a": "A"])
        let plans = RenameEngine.preview([fixture.item("a"), fixture.item("a")], rules: [.sequence(start: 0, step: 1, padding: 0, position: .prefix, separator: "-")])
        #expect(plans.allSatisfy { $0.conflict == .duplicateInBatch })
        #expect(throws: PowerError.self) { try RenameEngine.apply(plans, using: fixture.move) }
        #expect(try fixture.read("a") == "A")
    }

    @Test func onDiskConflict() throws {
        let fixture = try RenameFixture(["a": "A", "new-a": "existing"])
        let plans = RenameEngine.preview([fixture.item("a")], rules: [.prefix("new-")])
        #expect(plans[0].conflict == .existsOnDisk)
        #expect(try fixture.read("new-a") == "existing")
    }

    @Test func diskConflictPropagatesThroughChain() throws {
        let fixture = try RenameFixture(["a": "A", "xa": "B", "xxa": "occupied"])
        let plans = RenameEngine.preview([fixture.item("a"), fixture.item("xa")], rules: [.prefix("x")])
        #expect(plans.map(\.conflict) == [.existsOnDisk, .existsOnDisk])
    }

    @Test func conflictPreflightMakesNoMoves() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B", "occupied": "C"])
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", "new"), fixture.plan("b", "occupied")]) { _, _ in calls += 1 }
        }
        #expect(calls == 0)
        #expect(try fixture.names() == ["a", "b", "occupied"])
    }

    @Test func stalePreviewIsRevalidated() throws {
        let fixture = try RenameFixture(["a": "A"])
        let plans = RenameEngine.preview([fixture.item("a")], rules: [.prefix("x")])
        try Data("new occupant".utf8).write(to: fixture.url("xa"))
        #expect(throws: PowerError.self) { try RenameEngine.apply(plans, using: fixture.move) }
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("xa") == "new occupant")
    }

    @Test func simpleRenameUsesTemporaryCallbackMoves() throws {
        let fixture = try RenameFixture(["a.txt": "A"])
        var calls: [(URL, URL)] = []
        try RenameEngine.apply([fixture.plan("a.txt", "b.txt")]) { source, destination in
            calls.append((source, destination))
            try fixture.move(source, destination)
        }
        #expect(calls.count == 2)
        #expect(calls[0].1.lastPathComponent.range(of: #"^a\.clicksmith-tmp-[0-9a-f]{8}\.txt$"#, options: .regularExpression) != nil)
        #expect(calls[0].1.deletingLastPathComponent().path == fixture.directory.path)
        #expect(calls[0].1 == calls[1].0)
        #expect(try fixture.read("b.txt") == "A")
        #expect(try fixture.names() == ["b.txt"])
    }

    @Test func swap() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "a")], using: fixture.move)
        #expect(try fixture.read("a") == "B")
        #expect(try fixture.read("b") == "A")
        #expect(try fixture.names() == ["a", "b"])
    }

    @Test func threeFileCycle() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B", "c": "C"])
        try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "c"), fixture.plan("c", "a")], using: fixture.move)
        #expect(try fixture.read("a") == "C")
        #expect(try fixture.read("b") == "A")
        #expect(try fixture.read("c") == "B")
        #expect(try fixture.names() == ["a", "b", "c"])
    }

    @Test func previewAllowsCycle() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        let plans = RenameEngine.preview([fixture.item("a"), fixture.item("b")], rules: [.regex(pattern: "a|b", template: "_$0"), .replace(find: "_a", with: "b", caseSensitive: true), .replace(find: "_b", with: "a", caseSensitive: true)])
        #expect(plans.map(\.newName) == ["b", "a"])
        #expect(plans.allSatisfy { $0.conflict == nil })
        try RenameEngine.apply(plans, using: fixture.move)
        #expect(try fixture.read("a") == "B")
    }

    @Test func chainToFreeDestination() throws {
        let fixture = try RenameFixture(["a": "A", "xa": "B"])
        let plans = RenameEngine.preview([fixture.item("a"), fixture.item("xa")], rules: [.prefix("x")])
        #expect(plans.allSatisfy { $0.conflict == nil })
        try RenameEngine.apply(plans, using: fixture.move)
        #expect(try fixture.read("xa") == "A")
        #expect(try fixture.read("xxa") == "B")
    }

    @Test func caseOnlyRenameOnCaseInsensitiveVolume() throws {
        let fixture = try RenameFixture(["photo.txt": "A"])
        let values = try fixture.directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey, .volumeLocalizedFormatDescriptionKey])
        #expect(values.volumeSupportsCaseSensitiveNames == false, "This acceptance test requires a case-insensitive volume.")
        #expect(FileManager.default.fileExists(atPath: fixture.url("PHOTO.TXT").path))
        let plans = RenameEngine.preview([fixture.item("photo.txt")], rules: [.changeCase(.upper), .extension(.upper)])
        #expect(plans[0].conflict == nil)
        try RenameEngine.apply(plans, using: fixture.move)
        #expect(try fixture.names() == ["PHOTO.TXT"])
        #expect(try fixture.read("PHOTO.TXT") == "A")
    }

    @Test func unicodeNormalizationOnlyRename() throws {
        let fixture = try RenameFixture(["cafe\u{301}.txt": "A"])
        try RenameEngine.apply([fixture.plan("cafe\u{301}.txt", "café.txt")], using: fixture.move)
        #expect(try fixture.read("café.txt") == "A")
        #expect(try fixture.names().count == 1)
    }

    @Test func normalizationDuplicateIsDetected() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", "café"), fixture.plan("b", "cafe\u{301}")]) { _, _ in calls += 1 }
        }
        #expect(calls == 0)
    }

    @Test func caseInsensitiveDuplicateIsDetected() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", "new"), fixture.plan("b", "NEW")], using: fixture.move)
        }
        #expect(try fixture.names() == ["a", "b"])
    }

    @Test func normalizationDiskCollision() throws {
        let fixture = try RenameFixture(["cafe\u{301}": "existing", "a": "A"])
        #expect(throws: PowerError.self) { try RenameEngine.apply([fixture.plan("a", "café")], using: fixture.move) }
        #expect(try fixture.read("café") == "existing")
    }

    @Test func independentDirectoriesAllowSameName() throws {
        let first = try RenameFixture(["a": "A"])
        let second = try RenameFixture(["b": "B"])
        try RenameEngine.apply([first.plan("a", "new"), second.plan("b", "new")], using: first.move)
        #expect(try first.read("new") == "A")
        #expect(try second.read("new") == "B")
    }

    @Test func unchangedAndEmptyBatchesDoNotMove() throws {
        let fixture = try RenameFixture(["a": "A"])
        var calls = 0
        try RenameEngine.apply([fixture.plan("a", "a", conflict: .unchanged)]) { _, _ in calls += 1 }
        try RenameEngine.apply([]) { _, _ in calls += 1 }
        #expect(calls == 0)
    }

    @Test func missingSourceMakesNoMoves() throws {
        let fixture = try RenameFixture(["a": "A"])
        var calls = 0
        do {
            try RenameEngine.apply([fixture.plan("a", "new"), fixture.plan("missing", "other")]) { _, _ in calls += 1 }
            Issue.record("Expected missing-source failure")
        } catch let error as PowerError {
            guard case .failed(let message, let detail) = error else { Issue.record("Wrong error: \(error)"); return }
            #expect(message.contains("no longer exists"))
            #expect(detail == fixture.url("missing").path)
        }
        #expect(calls == 0)
    }

    @Test func forgedInvalidNamesAreRejected() throws {
        let fixture = try RenameFixture(["a": "A"])
        for name in ["", ".", "..", "../escape", "bad:name", "bad\0name", ".hidden", "/\u{301}escape", ":\u{301}name", ".\u{301}hidden"] {
            #expect(throws: PowerError.self) { try RenameEngine.apply([fixture.plan("a", name)], using: fixture.move) }
        }
        #expect(try fixture.read("a") == "A")
    }

    @Test func overlongPlanIsRejectedBeforeAnyMove() throws {
        let fixture = try RenameFixture(["a": "A"])
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", String(repeating: "x", count: 256))]) { _, _ in calls += 1 }
        }
        #expect(calls == 0)
        #expect(try fixture.names() == ["a"])
        #expect(try fixture.read("a") == "A")
    }

    @Test func temporaryNamesKeepFileStemAndExtension() throws {
        for (original, expected) in [("archive.tar.gz", #"^archive\.tar\.clicksmith-tmp-[0-9a-f]{8}\.gz$"#),
                                     ("README", #"^README\.clicksmith-tmp-[0-9a-f]{8}$"#),
                                     (".secret.txt", #"^secret\.clicksmith-tmp-[0-9a-f]{8}\.txt$"#),
                                     (".env", #"^env\.clicksmith-tmp-[0-9a-f]{8}$"#)] {
            let fixture = try RenameFixture([original: "A"])
            var temporaryName: String?
            try RenameEngine.apply([fixture.plan(original, "renamed")]) { source, destination in
                if temporaryName == nil { temporaryName = destination.lastPathComponent }
                try fixture.move(source, destination)
            }
            let name = try #require(temporaryName)
            #expect(name.range(of: expected, options: .regularExpression) != nil)
            #expect(!name.hasPrefix("."))
            #expect(try fixture.names() == ["renamed"])
            #expect(try fixture.read("renamed") == "A")
        }
    }

    @Test func maximumLengthSourcesHaveBoundedTemporaryNames() throws {
        let names = [String(repeating: "a", count: 255), "a." + String(repeating: "x", count: 253),
                     String(repeating: "📷", count: 63) + ".a"]
        for original in names {
            let fixture = try RenameFixture([original: "A"])
            var temporaryName: String?
            try RenameEngine.apply([fixture.plan(original, "renamed")]) { source, destination in
                if temporaryName == nil { temporaryName = destination.lastPathComponent }
                try fixture.move(source, destination)
            }
            let name = try #require(temporaryName)
            #expect(name.utf8.count <= 255)
            #expect(name.contains(".clicksmith-tmp-"))
            #expect(name.hasPrefix(original.hasPrefix("📷") ? "📷" : "a"))
            #expect(!name.contains("�"))
            #expect(try fixture.names() == ["renamed"])
            #expect(try fixture.read("renamed") == "A")
        }
    }

    @Test func directoryPreviewAndTemporaryNameKeepDots() throws {
        let fixture = try RenameFixture()
        try FileManager.default.createDirectory(at: fixture.url("My.Folder"), withIntermediateDirectories: false)
        try Data("A".utf8).write(to: fixture.url("My.Folder/child.txt"))
        let item = RenameItem(url: fixture.url("My.Folder"), facts: .init(isDirectory: true))
        let plans = RenameEngine.preview([item], rules: [.changeCase(.upper)])
        #expect(plans[0].newName == "MY.FOLDER")
        #expect(plans[0].conflict == nil)
        var temporaryName: String?
        try RenameEngine.apply(plans) { source, destination in
            if temporaryName == nil { temporaryName = destination.lastPathComponent }
            try fixture.move(source, destination)
        }
        let name = try #require(temporaryName)
        #expect(name.range(of: #"^My\.Folder\.clicksmith-tmp-[0-9a-f]{8}$"#, options: .regularExpression) != nil)
        #expect(try fixture.read("MY.FOLDER/child.txt") == "A")
        #expect(try fixture.names() == ["MY.FOLDER"])
    }

    @Test func blockedPlanStaysBlocked() throws {
        let fixture = try RenameFixture(["a": "A"])
        do {
            try RenameEngine.apply([fixture.plan("a", "new", conflict: .invalidName)], using: fixture.move)
            Issue.record("Expected conflict failure")
        } catch let error as PowerError {
            guard case .badInput(let message) = error else { Issue.record("Wrong error: \(error)"); return }
            #expect(message.contains("invalid"))
        }
    }

    @Test func directoryAndChildAreRejectedBeforeMoves() throws {
        let fixture = try RenameFixture()
        try FileManager.default.createDirectory(at: fixture.url("folder"), withIntermediateDirectories: false)
        try Data("A".utf8).write(to: fixture.url("folder/a"))
        var calls = 0
        do {
            try RenameEngine.apply([fixture.plan("folder", "new-folder"), fixture.plan("folder/a", "b")]) { _, _ in calls += 1 }
            Issue.record("Expected nested selection failure")
        } catch let error as PowerError {
            guard case .badInput(let message) = error else { Issue.record("Wrong error: \(error)"); return }
            #expect(message.contains("separate batches"))
        }
        #expect(calls == 0)
    }

    @Test func directoryAndChildWithDifferentCaseAreRejected() throws {
        let fixture = try RenameFixture()
        try FileManager.default.createDirectory(at: fixture.url("folder"), withIntermediateDirectories: false)
        try Data("A".utf8).write(to: fixture.url("folder/a"))
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("folder", "new-folder"), fixture.plan("FOLDER/a", "b")]) { _, _ in calls += 1 }
        }
        #expect(calls == 0)
    }

    @Test func directoryAndChildStartingWithCombiningMarkAreRejected() throws {
        let fixture = try RenameFixture()
        try FileManager.default.createDirectory(at: fixture.url("folder"), withIntermediateDirectories: false)
        try Data("A".utf8).write(to: fixture.url("folder/\u{301}a"))
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("folder", "new-folder"), fixture.plan("folder/\u{301}a", "b")]) { _, _ in calls += 1 }
        }
        #expect(calls == 0)
    }

    @Test func symlinkDirectoryAndChildAreRejected() throws {
        let fixture = try RenameFixture()
        try FileManager.default.createDirectory(at: fixture.url("folder"), withIntermediateDirectories: false)
        try Data("A".utf8).write(to: fixture.url("folder/a"))
        try FileManager.default.createSymbolicLink(at: fixture.url("link"), withDestinationURL: fixture.url("folder"))
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("link", "renamed"), fixture.plan("link/a", "b")]) { _, _ in calls += 1 }
        }
        #expect(calls == 0)
    }

    @Test func parentDirectoryAliasesCannotRenameSameSourceTwice() throws {
        let fixture = try RenameFixture(["a": "A"])
        try FileManager.default.createSymbolicLink(at: fixture.url("alias"), withDestinationURL: fixture.directory)
        let plans = RenameEngine.preview([fixture.item("a"), fixture.item("alias/a")], rules: [.prefix("new-")])
        #expect(plans.map(\.conflict) == [.duplicateInBatch, .duplicateInBatch], "\(plans)")
    }

    @Test func renameThroughParentDirectoryAlias() throws {
        let fixture = try RenameFixture(["a": "A"])
        try FileManager.default.createSymbolicLink(at: fixture.url("alias"), withDestinationURL: fixture.directory)
        let plans = RenameEngine.preview([fixture.item("alias/a")], rules: [.prefix("new-")])
        #expect(plans[0].conflict == nil)
        try RenameEngine.apply(plans, using: fixture.move)
        #expect(try fixture.read("new-a") == "A")
        #expect(try fixture.names() == ["new-a", "alias"])
    }

    @Test func destinationCreatedDuringApplyIsNotOverwritten() throws {
        let fixture = try RenameFixture(["a": "A"])
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", "new")]) { source, destination in
                calls += 1
                if calls == 2 { try Data("concurrent file".utf8).write(to: fixture.url("new")) }
                try fixture.move(source, destination)
            }
        }
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("new") == "concurrent file")
        #expect(try fixture.names() == ["a", "new"])
    }

    @Test(arguments: 1...6) func failureAtEveryCycleMoveRestoresOriginals(failingCall: Int) throws {
        let fixture = try RenameFixture(["a": "A", "b": "B", "c": "C"])
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "c"), fixture.plan("c", "a")]) { source, destination in
                calls += 1
                if calls == failingCall { throw RenameTestFailure.injected }
                try fixture.move(source, destination)
            }
        }
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("b") == "B")
        #expect(try fixture.read("c") == "C")
        #expect(try fixture.names() == ["a", "b", "c"])
    }

    @Test func failedStagingRestoresOriginals() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        var count = 0
        do {
            try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "a")]) { source, destination in
                count += 1
                if count == 2 { throw RenameTestFailure.injected }
                try fixture.move(source, destination)
            }
            Issue.record("Expected injected failure")
        } catch let error as PowerError {
            guard case .failed(_, let detail) = error else { Issue.record("Wrong error"); return }
            #expect(detail?.contains("injected") == true)
            #expect(detail?.contains("Rollback failed:") == false)
        }
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("b") == "B")
        #expect(try fixture.names() == ["a", "b"])
    }

    @Test func failedCycleCommitRestoresOriginals() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B", "c": "C"])
        var count = 0
        do {
            try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "c"), fixture.plan("c", "a")]) { source, destination in
                count += 1
                if count == 6 { throw RenameTestFailure.injected }
                try fixture.move(source, destination)
            }
            Issue.record("Expected injected failure")
        } catch let error as PowerError {
            guard case .failed(_, let detail) = error else { Issue.record("Wrong error"); return }
            #expect(detail?.contains("Rollback failed:") == false)
        }
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("b") == "B")
        #expect(try fixture.read("c") == "C")
        #expect(try fixture.names() == ["a", "b", "c"])
    }

    @Test func rollbackFailureReportsRecoverableLocation() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        var count = 0
        do {
            try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "a")]) { source, destination in
                count += 1
                if count == 2 || count == 3 { throw RenameTestFailure.injected }
                try fixture.move(source, destination)
            }
            Issue.record("Expected injected failure")
        } catch let error as PowerError {
            guard case .failed(let message, let detail) = error else { Issue.record("Wrong error"); return }
            let remaining = try fixture.names().filter { $0.hasPrefix("a.clicksmith-tmp-") }
            #expect(remaining.count == 1)
            let temporary = try #require(remaining.first)
            #expect(temporary.range(of: #"^a\.clicksmith-tmp-[0-9a-f]{8}$"#, options: .regularExpression) != nil)
            #expect(!temporary.hasPrefix("."))
            #expect(try fixture.read(temporary) == "A")
            #expect(message.contains("could not be restored"))
            #expect(detail?.contains("Rollback failed:") == true)
            #expect(detail?.contains(fixture.url(temporary).path) == true)
            #expect(detail?.contains(fixture.url("a").path) == true)
        }
        #expect(try fixture.read("b") == "B")
    }

    @Test func danglingSymlinkOccupiesDestination() throws {
        let fixture = try RenameFixture(["a": "A"])
        try FileManager.default.createSymbolicLink(at: fixture.url("xa"), withDestinationURL: fixture.url("missing"))
        let plans = RenameEngine.preview([fixture.item("a")], rules: [.prefix("x")])
        #expect(plans[0].conflict == .existsOnDisk)
        #expect(throws: PowerError.self) { try RenameEngine.apply(plans, using: fixture.move) }
    }

    @Test func renamingSymlinkDoesNotRenameItsTarget() throws {
        let fixture = try RenameFixture(["target": "A"])
        try FileManager.default.createSymbolicLink(at: fixture.url("link"), withDestinationURL: fixture.url("target"))
        try RenameEngine.apply([fixture.plan("link", "renamed")], using: fixture.move)
        #expect(try fixture.read("target") == "A")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url("renamed").path) == fixture.url("target").path)
        #expect(try fixture.names() == ["target", "renamed"])
    }

    @Test func journaledCycleCanBeUndone() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B", "c": "C"])
        let storage = try RenameFixture()
        let journal = UndoJournal(directory: storage.directory)
        let files = FileOps()
        try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "c"), fixture.plan("c", "a")]) {
            _ = try files.moveExact($0, to: $1)
        }
        #expect(files.recorded.count == 6)
        #expect(try fixture.read("a") == "C")
        let transaction = try #require(try files.commit(to: journal, actionID: "rename", title: "Rename"))
        #expect(journal.last?.entries.count == 3, "staging moves collapse to one logical rename per file (T-0012 review #1)")
        let report = journal.undo(transaction)
        #expect(report.reverted.count == 3)
        #expect(report.skipped.isEmpty)
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("b") == "B")
        #expect(try fixture.read("c") == "C")
        #expect(try fixture.names() == ["a", "b", "c"])
        #expect(journal.list().isEmpty)
    }

    @Test func journaledCaseOnlyRenameCanBeUndone() throws {
        let fixture = try RenameFixture(["photo.txt": "A"])
        let storage = try RenameFixture()
        let journal = UndoJournal(directory: storage.directory)
        let files = FileOps()
        try RenameEngine.apply([fixture.plan("photo.txt", "PHOTO.TXT")]) { _ = try files.moveExact($0, to: $1) }
        #expect(files.recorded.count == 2)
        #expect(try fixture.names() == ["PHOTO.TXT"])
        let transaction = try #require(try files.commit(to: journal, actionID: "rename", title: "Rename"))
        let report = journal.undo(transaction)
        #expect(report.skipped.isEmpty)
        #expect(report.reverted.count == 1)
        #expect(try fixture.names() == ["photo.txt"])
        #expect(try fixture.read("photo.txt") == "A")
    }

    @Test func journaledRollbackCanBeUndone() throws {
        let fixture = try RenameFixture(["a": "A", "b": "B"])
        let storage = try RenameFixture()
        let journal = UndoJournal(directory: storage.directory)
        let files = FileOps()
        var calls = 0
        #expect(throws: PowerError.self) {
            try RenameEngine.apply([fixture.plan("a", "b"), fixture.plan("b", "a")]) {
                calls += 1
                if calls == 4 { throw RenameTestFailure.injected }
                _ = try files.moveExact($0, to: $1)
            }
        }
        #expect(files.recorded.count == 6)
        // Fully rolled back: every chain collapses to "no change", so there is nothing to journal.
        #expect(try files.commit(to: journal, actionID: "rename", title: "Rename") == nil)
        #expect(try fixture.read("a") == "A")
        #expect(try fixture.read("b") == "B")
        #expect(try fixture.names() == ["a", "b"])
    }
}
