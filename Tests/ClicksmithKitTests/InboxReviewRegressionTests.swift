import Darwin
import Foundation
import Testing
@testable import ClicksmithKit

@Suite struct InboxReviewRegressionTests {
    private func fixture() throws -> (SharedPaths, RequestInbox) {
        let paths = SharedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("inbox-review-\(UUID().uuidString)"))
        try paths.ensureExists()
        return (paths, RequestInbox(paths: paths))
    }

    private func file(_ paths: SharedPaths, _ directory: String, _ id: UUID, _ suffix: String) -> URL {
        paths.inbox.appendingPathComponent(directory).appendingPathComponent("\(id.uuidString).\(suffix)")
    }

    private func orphan(_ request: ActionRequest, paths: SharedPaths, started: Bool = false) throws {
        let claim = file(paths, "claimed", request.id, "json")
        try FileManager.default.createDirectory(at: claim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.clicksmith.encode(request).write(to: claim)
        try Data().write(to: file(paths, "claimed", request.id, "lock"))
        if started { try Data("start evidence".utf8).write(to: file(paths, "claimed", request.id, "started")) }
    }

    @Test func completedRequestsAndFailedAcquisitionsLeaveNoLockFiles() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: [], source: .finder)
        try inbox.submit(request)
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path), "Submit has no continuing lease")
        #expect(throws: (any Error).self) { try inbox.submit(request) }
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path))
        #expect(inbox.take(request.id) == request)
        try inbox.markStarted(request)
        try inbox.acknowledge(request.id)
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path), "Acknowledgement retires the per-click lock")
        let missing = UUID()
        #expect(inbox.take(missing) == nil)
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", missing, "lock").path), "A missing wake does not leave a lock")
    }

    @Test func invalidClaimDoesNotLeakItsLease() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        try Data("invalid request".utf8).write(to: paths.requestFile(id))
        #expect(inbox.take(id) == nil)
        #expect(inbox.drain().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", id, "lock").path))
        #expect(try String(contentsOf: file(paths, "claimed", id, "json"), encoding: .utf8) == "invalid request", "The invalid evidence survives")
    }

    @Test func inspectionCleansLocksWhoseClaimsAreMissing() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let lease = file(paths, "claimed", id, "lock")
        try FileManager.default.createDirectory(at: lease.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lease)
        #expect(inbox.interrupted().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: lease.path))
    }

    @Test func inspectionArchivesStartedMarkerWhoseClaimIsMissing() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = UUID()
        let marker = file(paths, "claimed", id, "started")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial archive".utf8).write(to: marker)
        #expect(inbox.interrupted() == [id])
        #expect(inbox.interrupted().isEmpty)
        #expect(inbox.drain().isEmpty)
        #expect(try String(contentsOf: file(paths, "inspected", id, "started"), encoding: .utf8) == "partial archive")
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", id, "lock").path))
    }

    @Test func interruptedRequestsAreReportedOnceAndRetainTheirEvidence() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: ["/tmp/original"], source: .finder)
        try orphan(request, paths: paths, started: true)
        let originalBytes = try Data(contentsOf: file(paths, "claimed", request.id, "json"))
        #expect(inbox.interrupted() == [request.id])
        #expect(inbox.interrupted().isEmpty, "The next launch does not report the same interruption")
        #expect(inbox.drain().isEmpty, "Inspected operations never replay")
        #expect(try Data(contentsOf: file(paths, "inspected", request.id, "json")) == originalBytes)
        #expect(try String(contentsOf: file(paths, "inspected", request.id, "started"), encoding: .utf8) == "start evidence")
        #expect(!inbox.isClaimed(request.id))
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path))
        #expect(throws: (any Error).self) { try inbox.submit(request) }
        #expect(inbox.take(request.id) == nil)
    }

    @Test func partialArchiveCannotReplayAndCanFinishAfterTheMarkerMoveRetries() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: ["/tmp/original"], source: .finder)
        try orphan(request, paths: paths, started: true)
        let originalBytes = try Data(contentsOf: file(paths, "claimed", request.id, "json"))
        let markerDestination = file(paths, "inspected", request.id, "started")
        try FileManager.default.createDirectory(at: markerDestination, withIntermediateDirectories: true)

        #expect(inbox.interrupted().isEmpty, "Do not report an archive that could not finish")
        #expect(!inbox.isClaimed(request.id), "The request moved before the blocked marker")
        #expect(try Data(contentsOf: file(paths, "inspected", request.id, "json")) == originalBytes)
        #expect(try String(contentsOf: file(paths, "claimed", request.id, "started"), encoding: .utf8) == "start evidence")
        #expect(inbox.drain().isEmpty, "A partial archive cannot become runnable")
        #expect(inbox.take(request.id) == nil)
        #expect(throws: (any Error).self) { try inbox.submit(request) }
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path))

        try FileManager.default.removeItem(at: markerDestination)
        #expect(inbox.interrupted() == [request.id], "The marker-only remainder completes on retry")
        #expect(inbox.interrupted().isEmpty)
        #expect(inbox.drain().isEmpty)
        #expect(try Data(contentsOf: file(paths, "inspected", request.id, "json")) == originalBytes)
        #expect(try String(contentsOf: markerDestination, encoding: .utf8) == "start evidence")
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path))
    }

    @Test func acknowledgementRetiresItsLockedInodeAndPreservesOtherLiveClaims() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let first = ActionRequest(actionID: "first", paths: [], source: .finder)
        let second = ActionRequest(actionID: "second", paths: [], source: .finder)
        for request in [first, second] {
            try inbox.submit(request)
            #expect(inbox.take(request.id) == request)
            try inbox.markStarted(request)
        }
        let firstLease = file(paths, "claimed", first.id, "lock")
        let firstFD = open(firstLease.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(firstFD >= 0)
        defer { close(firstFD) }
        let secondFD = open(file(paths, "claimed", second.id, "lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        try #require(secondFD >= 0)
        defer { close(secondFD) }
        #expect(flock(firstFD, LOCK_EX | LOCK_NB) != 0, "The first executor holds the real kernel lock before acknowledgement")
        #expect(flock(secondFD, LOCK_EX | LOCK_NB) != 0)
        #expect(throws: (any Error).self) { try inbox.submit(first) }

        try inbox.acknowledge(first.id)
        #expect(!FileManager.default.fileExists(atPath: firstLease.path))
        var retired = stat()
        #expect(fstat(firstFD, &retired) == 0)
        #expect(retired.st_nlink == 0, "Acknowledgement removed the inode opened by a contender")
        #expect(flock(firstFD, LOCK_EX | LOCK_NB) == 0, "The acknowledged executor released its flock")
        #expect(inbox.take(first.id) == nil, "A retained descriptor for the old inode cannot block a later acquisition")
        #expect(!FileManager.default.fileExists(atPath: firstLease.path))
        #expect(flock(secondFD, LOCK_EX | LOCK_NB) != 0, "Acknowledging one request preserves another executor's flock")
        #expect(inbox.interrupted().isEmpty)
        try inbox.acknowledge(second.id)
        #expect(flock(secondFD, LOCK_EX | LOCK_NB) == 0)
    }

    @Test func interruptionInspectionSkipsActiveClaims() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: [], created: Date().addingTimeInterval(-3600), source: .finder)
        try inbox.submit(request)
        #expect(inbox.take(request.id) == request)
        #expect(inbox.interrupted().isEmpty, "Age does not override a live lease")
        #expect(inbox.drain().isEmpty)
        try inbox.markStarted(request)
        #expect(inbox.interrupted().isEmpty)
        try inbox.acknowledge(request.id)
    }

    @Test func startupReportsExpiredUnstartedOrphansBeforeDrain() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "expired", paths: [], created: Date().addingTimeInterval(-3600), source: .finder)
        try orphan(request, paths: paths)
        #expect(inbox.interrupted() == [request.id], "Launch inspects before drain")
        #expect(inbox.drain().isEmpty)
        #expect(inbox.interrupted().isEmpty)
        #expect(try JSONDecoder.clicksmith.decode(ActionRequest.self, from: Data(contentsOf: file(paths, "inspected", request.id, "json"))) == request)
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path))
    }

    @Test func recoveredClaimsObeyTheSameAgeBoundaryAsQueuedRequests() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = ActionRequest(actionID: "expired", paths: [], created: now.addingTimeInterval(-601), source: .finder)
        let boundary = ActionRequest(actionID: "boundary", paths: [], created: now.addingTimeInterval(-600), source: .finder)
        let fresh = ActionRequest(actionID: "fresh", paths: [], created: now.addingTimeInterval(-599), source: .finder)
        for request in [expired, boundary, fresh] { try orphan(request, paths: paths) }
        #expect(inbox.drain(maxAge: 600, now: now) == [boundary, fresh])
        #expect(inbox.drain(maxAge: 600, now: now).isEmpty, "Recovered requests have live leases and run once")
        for request in [boundary, fresh] { try inbox.markStarted(request); try inbox.acknowledge(request.id) }
        #expect(inbox.interrupted() == [expired.id])
        #expect(inbox.interrupted().isEmpty)
        #expect(!inbox.isClaimed(expired.id))
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", expired.id, "lock").path))
    }

    @Test func expiredQueuedRequestsAreReportedOnceWithoutExecution() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let now = Date()
        let request = ActionRequest(actionID: "expired", paths: [], created: now.addingTimeInterval(-601), source: .finder)
        try inbox.submit(request)
        #expect(inbox.drain(now: now).isEmpty)
        #expect(inbox.pending().isEmpty)
        #expect(inbox.interrupted() == [request.id])
        #expect(inbox.interrupted().isEmpty)
        #expect(inbox.drain().isEmpty)
        #expect(try JSONDecoder.clicksmith.decode(ActionRequest.self, from: Data(contentsOf: file(paths, "inspected", request.id, "json"))) == request)
        #expect(!FileManager.default.fileExists(atPath: file(paths, "claimed", request.id, "lock").path))
    }

    @Test func failedFirstStartReleasesTheLeaseForRecovery() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "original", paths: [], source: .finder)
        try inbox.submit(request)
        #expect(inbox.take(request.id) == request)
        var wrongRequest = request; wrongRequest.actionID = "wrong"
        #expect(throws: RequestInboxError.self) { try inbox.markStarted(wrongRequest) }
        #expect(inbox.drain() == [request], "Another acquisition can recover after start validation fails")
        try inbox.markStarted(request)
        try inbox.acknowledge(request.id)
    }

    @Test func missingClaimOnFirstStartReleasesTheKernelLock() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: [], source: .finder)
        try inbox.submit(request)
        #expect(inbox.take(request.id) == request)
        try FileManager.default.removeItem(at: file(paths, "claimed", request.id, "json"))
        #expect(throws: RequestInboxError.self) { try inbox.markStarted(request) }
        let fd = open(file(paths, "claimed", request.id, "lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        #expect(fd >= 0)
        if fd >= 0 {
            defer { close(fd) }
            #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "A failed start releases its real flock")
        }
    }

    @Test func preexistingStartedMarkerSurvivesAFailedStart() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: [], source: .finder)
        try inbox.submit(request)
        #expect(inbox.take(request.id) == request)
        try Data("existing evidence".utf8).write(to: file(paths, "claimed", request.id, "started"))
        #expect(throws: RequestInboxError.self) { try inbox.markStarted(request) }
        #expect(inbox.interrupted() == [request.id], "A failed first start releases the lease even when a marker already exists")
        #expect(try String(contentsOf: file(paths, "inspected", request.id, "started"), encoding: .utf8) == "existing evidence")
        #expect(inbox.drain().isEmpty)
    }

    @Test func duplicateStartCannotReleaseTheActiveStartedLease() throws {
        let (paths, inbox) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let request = ActionRequest(actionID: "test", paths: [], source: .finder)
        try inbox.submit(request)
        #expect(inbox.take(request.id) == request)
        try inbox.markStarted(request)
        let otherInbox = RequestInbox(paths: paths)
        #expect(throws: RequestInboxError.self) { try otherInbox.markStarted(request) }
        #expect(otherInbox.interrupted().isEmpty, "A duplicate attempt cannot inspect another live execution")
        #expect(otherInbox.drain().isEmpty)
        try inbox.acknowledge(request.id)
    }

    @Test func interruptionSummaryCapsRequestDetailsAndCountsTheRemainder() {
        let ids = (0..<15).map { _ in UUID() }
        let summary = RequestInbox.interruptionSummary(ids)
        let lines = summary.split(separator: "\n")
        #expect(lines.count == 11)
        #expect(lines.filter { $0.hasPrefix("Request ") }.count == 10)
        #expect(lines.last == "+5 more")
        for id in ids.prefix(10) { #expect(summary.contains(id.uuidString)) }
        #expect(!summary.contains(ids[10].uuidString))
        #expect(RequestInbox.interruptionSummary(ids, limit: 100) == summary, "Callers cannot enlarge the alert beyond ten detail lines")
    }

    @Test func interruptionSummaryHandlesSmallerAndEmptyLimits() {
        let ids = (0..<5).map { _ in UUID() }
        let limited = RequestInbox.interruptionSummary(ids, limit: 2)
        #expect(limited.split(separator: "\n").count == 3)
        #expect(limited.hasSuffix("+3 more"))
        #expect(!limited.contains(ids[2].uuidString))
        #expect(RequestInbox.interruptionSummary(ids, limit: 0) == "+5 more")
        #expect(RequestInbox.interruptionSummary(ids, limit: -1) == "+5 more")
        #expect(RequestInbox.interruptionSummary([]).isEmpty)
        #expect(RequestInbox.interruptionSummary(ids).split(separator: "\n").count == 5)
    }
}
