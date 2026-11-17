import Darwin
import Foundation
import Testing
@testable import ClicksmithCore

private struct DurabilityProbeAction: PowerAction {
    let crash: Bool
    let descriptor = ActionDescriptor(id: "test.durable", title: "Durable", symbol: "doc", group: .tools)

    func run(_ context: ActionContext) async throws -> ActionResult {
        let input = try #require(context.inputs.first)
        let target = input.deletingLastPathComponent().appendingPathComponent("visible.clicksmith-tmp-interrupted")
        try context.files.moveExact(input, to: target)
        let journal = UndoJournal(directory: context.paths.journal)
        let records = try FileManager.default.contentsOfDirectory(at: journal.pendingDirectory, includingPropertiesForKeys: nil)
            .filter { ["json", "jsonl"].contains($0.pathExtension) }
        let record = try journal.readPending(#require(records.first))
        #expect(record.transaction.entries.last?.to == target.path, "The receipt is durable while the action is still running")
        if crash {
            try Data().write(to: context.paths.root.appendingPathComponent("ready"))
            try await Task.sleep(for: .seconds(15))
            kill(getpid(), SIGKILL)
        }
        throw PowerError.failed("Intentional failure after moving an input")
    }
}

@Suite struct RunnerSafetyTests {
    @Test func finishedFinderRequestCannotRunAgainFromAnOldValue() async throws {
        let directory = try tempDir(), paths = SharedPaths(root: try tempDir("root"))
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: paths.root) }
        let inbox = RequestInbox(paths: paths), journal = UndoJournal(directory: paths.journal)
        let request = ActionRequest(actionID: "create.newFile", paths: [], targetDirectory: directory.path, source: .finder)
        try inbox.submit(request)
        let claimed = try #require(inbox.take(request.id))
        let runner = ActionRunner(registry: ActionRegistry([NewFileAction()]), journal: journal,
                                  environment: FakeEnvironment(), settings: .init(), paths: paths)
        #expect(await runner.run(claimed).succeeded)
        #expect(!(await runner.run(claimed).succeeded))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test func failedActionStillCommitsAndAcknowledgesClaim() async throws {
        let directory = try tempDir(), paths = SharedPaths(root: try tempDir("root"))
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: paths.root) }
        let input = try touch(directory, "original", "precious"), inbox = RequestInbox(paths: paths)
        let request = ActionRequest(actionID: "test.durable", paths: [input.path], source: .finder)
        let journal = UndoJournal(directory: paths.journal)
        try inbox.submit(request)
        let claimed = try #require(inbox.take(request.id))
        let runner = ActionRunner(registry: ActionRegistry([DurabilityProbeAction(crash: false)]), journal: journal,
                                  environment: FakeEnvironment(), settings: .init(), paths: paths)
        let outcome = await runner.run(claimed)
        #expect(outcome.error != nil)
        #expect(outcome.journalError == nil)
        #expect(outcome.transaction?.entries.count == 1)
        #expect(!inbox.isClaimed(request.id))
        #expect(inbox.drain().isEmpty)
        #expect(!journal.recoverPending().hasFindings)
        #expect(journal.undo(try #require(outcome.transaction)).skipped.isEmpty)
        #expect(try String(contentsOf: input, encoding: .utf8) == "precious")
    }

    @Test func processKillDuringActionKeepsTemporaryMoveRecoverable() throws {
        let directory = try tempDir(), paths = SharedPaths(root: try tempDir("root"))
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: paths.root) }
        let input = try touch(directory, "original", "precious")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            process.arguments = ["--test-bundle-path", CommandLine.arguments[index + 1], "--filter", "journalCrashWorker", "--testing-library", "swift-testing"]
        } else { process.arguments = ["--filter", "journalCrashWorker", "--testing-library", "swift-testing"] }
        var environment = ProcessInfo.processInfo.environment
        environment["CLICKSMITH_JOURNAL_CRASH_ROOT"] = paths.root.path
        environment["CLICKSMITH_JOURNAL_CRASH_INPUT"] = input.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let ready = paths.root.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(FileManager.default.fileExists(atPath: ready.path), "The worker persisted its move before the crash")
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        #expect(process.terminationStatus == SIGKILL)
        let journal = UndoJournal(directory: paths.journal)
        let report = journal.recoverPending()
        #expect(report.problems.isEmpty)
        #expect(report.recovered.count == 1)
        #expect(report.summary.contains("visible.clicksmith-tmp-interrupted"))
        #expect(journal.undo(try #require(journal.last)).skipped.isEmpty)
        #expect(try String(contentsOf: input, encoding: .utf8) == "precious")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CLICKSMITH_JOURNAL_CRASH_ROOT"] != nil, "Subprocess crash fixture"))
func journalCrashWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    let paths = SharedPaths(root: URL(fileURLWithPath: try #require(environment["CLICKSMITH_JOURNAL_CRASH_ROOT"])))
    let input = try #require(environment["CLICKSMITH_JOURNAL_CRASH_INPUT"])
    let runner = ActionRunner(registry: ActionRegistry([DurabilityProbeAction(crash: true)]), journal: UndoJournal(directory: paths.journal),
                              environment: FakeEnvironment(), settings: .init(), paths: paths)
    _ = await runner.run(ActionRequest(actionID: "test.durable", paths: [input], source: .cli))
}
