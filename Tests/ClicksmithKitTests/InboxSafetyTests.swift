import Darwin
import Foundation
import Testing
@testable import ClicksmithKit

@Suite struct InboxSafetyTests {
    private func paths() throws -> SharedPaths {
        let paths = SharedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("inbox-safety-\(UUID().uuidString)"))
        try paths.ensureExists()
        return paths
    }

    @Test func exclusiveClaimHasOnlyOneConcurrentConsumer() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let inbox = RequestInbox(paths: paths)
        let request = ActionRequest(actionID: "test", paths: [], source: .finder)
        let original = try inbox.submit(request)
        let winners = await withTaskGroup(of: ActionRequest?.self, returning: [ActionRequest].self) { group in
            for _ in 0..<32 { group.addTask { inbox.take(request.id) } }
            var result: [ActionRequest] = []
            for await request in group { if let request { result.append(request) } }
            return result
        }
        #expect(winners == [request])
        #expect(!FileManager.default.fileExists(atPath: original.path), "Claiming clears the path checked by Finder wake retry")
        #expect(inbox.isClaimed(request.id), "Claim bytes survive until acknowledgement")
        #expect(inbox.drain().isEmpty, "A running process still owns its unstarted claim")
        try inbox.markStarted(request)
        #expect(throws: RequestInboxError.self) { try inbox.markStarted(request) }
        try inbox.acknowledge(request.id)
        #expect(!inbox.isClaimed(request.id))
    }

    @Test func duplicateSubmissionCannotOverwriteWaitingOrClaimedRequest() throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let inbox = RequestInbox(paths: paths)
        let request = ActionRequest(actionID: "original", paths: [], source: .finder)
        try inbox.submit(request)
        var replacement = request; replacement.actionID = "replacement"
        #expect(throws: (any Error).self) { try inbox.submit(replacement) }
        #expect(inbox.take(request.id) == request)
        #expect(throws: (any Error).self) { try inbox.submit(replacement) }
        try inbox.markStarted(request)
        try inbox.acknowledge(request.id)
    }

    @Test(arguments: ["claimed", "started", "finished"])
    func processExitRecoversOnlyUnstartedClaims(phase: String) throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let inbox = RequestInbox(paths: paths)
        let request = ActionRequest(actionID: "test", paths: [], source: .finder)
        try inbox.submit(request)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            process.arguments = ["--test-bundle-path", CommandLine.arguments[index + 1], "--filter", "inboxCrashWorker", "--testing-library", "swift-testing"]
        } else { process.arguments = ["--filter", "inboxCrashWorker", "--testing-library", "swift-testing"] }
        var environment = ProcessInfo.processInfo.environment
        environment["CLICKSMITH_INBOX_CRASH_PHASE"] = phase
        environment["CLICKSMITH_INBOX_CRASH_ROOT"] = paths.root.path
        environment["CLICKSMITH_INBOX_CRASH_ID"] = request.id.uuidString
        process.environment = environment
        let log = paths.root.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: log)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle; process.standardError = outputHandle
        try process.run()
        let ready = paths.root.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(FileManager.default.fileExists(atPath: ready.path), "The worker reached the requested crash boundary")
        #expect(inbox.take(request.id) == nil, "A separate live process holds the claim lease")
        #expect(inbox.drain().isEmpty)
        #expect(inbox.interrupted().isEmpty, "Live requests are never inspected as interrupted")
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let transcript = try String(contentsOf: log, encoding: .utf8)
        #expect(process.terminationStatus == SIGKILL, "phase=\(phase), status=\(process.terminationStatus), reason=\(process.terminationReason): \(transcript)")
        #expect(inbox.pending().isEmpty)
        #expect(inbox.isClaimed(request.id))
        if phase == "claimed" {
            #expect(inbox.drain() == [request])
            try inbox.markStarted(request)
            try inbox.acknowledge(request.id)
        } else {
            #expect(inbox.drain().isEmpty)
            #expect(inbox.drain().isEmpty, "Never blindly replay a started or finished operation")
            #expect(inbox.interrupted() == [request.id])
        }
        let output = paths.root.appendingPathComponent("operation-count")
        #expect(FileManager.default.fileExists(atPath: output.path) == (phase == "finished"))
        if phase == "finished" { #expect(try String(contentsOf: output, encoding: .utf8) == "once") }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CLICKSMITH_INBOX_CRASH_PHASE"] != nil, "Subprocess crash fixture"))
func inboxCrashWorker() throws {
    let environment = ProcessInfo.processInfo.environment
    let phase = try #require(environment["CLICKSMITH_INBOX_CRASH_PHASE"])
    let root = try #require(environment["CLICKSMITH_INBOX_CRASH_ROOT"])
    let idText = try #require(environment["CLICKSMITH_INBOX_CRASH_ID"])
    let id = try #require(UUID(uuidString: idText))
    let paths = SharedPaths(root: URL(fileURLWithPath: root))
    let inbox = RequestInbox(paths: paths)
    let request = try #require(inbox.take(id))
    if phase != "claimed" { try inbox.markStarted(request) }
    if phase == "finished" { try Data("once".utf8).write(to: paths.root.appendingPathComponent("operation-count")) }
    try Data().write(to: paths.root.appendingPathComponent("ready"))
    // Let the parent kill a registered, live Process after observing the boundary.
    // This avoids a Foundation status race when a child kills itself immediately.
    Thread.sleep(forTimeInterval: 15)
    kill(getpid(), SIGKILL)
}
