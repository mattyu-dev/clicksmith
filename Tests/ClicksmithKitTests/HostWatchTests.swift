import Foundation
import Testing
@testable import ClicksmithKit

/// T-0019: the Finder extension must exit when Finder quits. The live check needs a Finder quit;
/// these tests prove the decision and the pid watch that the extension uses.
@Suite struct HostWatchTests {
    @Test func onlyFinderTerminationCounts() {
        #expect(HostWatch.isHostTermination(bundleID: "com.apple.finder", pid: 10, hostPID: 10))
        #expect(HostWatch.isHostTermination(bundleID: "com.apple.finder", pid: 10, hostPID: nil))
        #expect(HostWatch.isHostTermination(bundleID: "com.apple.finder", pid: nil, hostPID: 10))
        #expect(!HostWatch.isHostTermination(bundleID: "com.apple.Safari", pid: 10, hostPID: 10))
        #expect(!HostWatch.isHostTermination(bundleID: nil, pid: 10, hostPID: 10))
        // An older Finder that ends after a new one started must not stop the new extension.
        #expect(!HostWatch.isHostTermination(bundleID: "com.apple.finder", pid: 9, hostPID: 10))
    }

    @Test("Codex #4 + round 2: leave with Finder unless clearly serving a dialog or another live app") func hostPolicy() {
        typealias H = HostWatch.Host
        func leaves(_ h: H?, alive: Bool = true) -> Bool { HostWatch.shouldLeaveWithFinder(host: h, hostAlive: alive) }
        #expect(leaves(nil))                                                                   // unknown host
        #expect(leaves(H(pid: 1, bundleID: "com.apple.finder", isApp: true)))
        #expect(!leaves(H(pid: 2, bundleID: "com.apple.appkit.xpc.openAndSavePanelService", isApp: false)))
        #expect(!leaves(H(pid: 2, bundleID: "com.apple.appkit.xpc.openAndSavePanelService.legacy", isApp: false)))
        #expect(!leaves(H(pid: 3, bundleID: "com.apple.TextEdit", isApp: true)))               // another live app
        #expect(leaves(H(pid: 3, bundleID: "com.apple.TextEdit", isApp: true), alive: false))  // its host is gone
        // A helper (e.g. one of Finder's own XPC services, or a pid without a bundle): Finder's copy, leave.
        #expect(leaves(H(pid: 4, bundleID: "com.apple.CMExtensionBroker", isApp: false)))
        #expect(leaves(H(pid: 5, bundleID: nil, isApp: false)))
    }

    @Test("round 3 #2: heartbeat only from Finder's copy; unknown only after waiting") func heartbeatTiming() {
        let finder = HostWatch.Host(pid: 1, bundleID: "com.apple.finder", isApp: true)
        let dialog = HostWatch.Host(pid: 2, bundleID: "com.apple.appkit.xpc.openAndSavePanelService", isApp: false)
        #expect(HostWatch.heartbeatStep(host: finder, waitedEnough: false) == .write)
        #expect(HostWatch.heartbeatStep(host: dialog, waitedEnough: true) == .skip)
        #expect(HostWatch.heartbeatStep(host: nil, waitedEnough: false) == .wait)
        #expect(HostWatch.heartbeatStep(host: nil, waitedEnough: true) == .write)
    }

    @Test("round 3 #2: a dialog copy restores the old heartbeat only over its own") func restoreOnlyOwn() {
        #expect(HostWatch.mayRestoreHeartbeat(namedPID: 500, ownPID: 500))
        #expect(!HostWatch.mayRestoreHeartbeat(namedPID: 501, ownPID: 500))   // Finder's newer load: keep it
        #expect(!HostWatch.mayRestoreHeartbeat(namedPID: nil, ownPID: 500))
    }

    @Test("round 2 #4: only Finder-hosted heartbeats prove a reload") func heartbeatHost() {
        #expect(HostWatch.heartbeatIsFinders(host: nil))          // older builds wrote no host
        #expect(HostWatch.heartbeatIsFinders(host: "unknown"))
        #expect(HostWatch.heartbeatIsFinders(host: "com.apple.finder"))
        #expect(!HostWatch.heartbeatIsFinders(host: "com.apple.appkit.xpc.openAndSavePanelService"))
        #expect(!HostWatch.heartbeatIsFinders(host: "com.apple.TextEdit"))
    }

    @Test("watch the newest Finder") func newestFinder() {
        let old = HostWatch.Candidate(pid: 10, launched: Date(timeIntervalSince1970: 100))
        let new = HostWatch.Candidate(pid: 20, launched: Date(timeIntervalSince1970: 200))
        #expect(HostWatch.newest([new, old]) == 20 && HostWatch.newest([old, new]) == 20)
        #expect(HostWatch.newest([HostWatch.Candidate(pid: 5, launched: nil), old]) == 10)
        #expect(HostWatch.newest([]) == nil)
    }

    @Test("actions that open a window activate the app") func focusOnlyForWindows() {
        for id in ["app.open", "organize.batchRename", "organize.copyTo", "organize.moveTo"] {
            #expect(ActionRequest(actionID: id, paths: [], source: .finder).needsFocus, "\(id)")
        }
        // Round 2: only the picker / rename window needs focus; a favourite folder opens nothing.
        for id in ["organize.copyTo", "organize.moveTo"] {
            #expect(ActionRequest(actionID: id, paths: [], options: ["dest": "?choose"], source: .finder).needsFocus)
            #expect(!ActionRequest(actionID: id, paths: [], options: ["dest": "/Users/x/Desktop"], source: .finder).needsFocus)
        }
        #expect(!ActionRequest(actionID: "organize.batchRename", paths: [], options: ["rules": "[]"], source: .finder).needsFocus)
        for id in ["image.convert", "copy.path", "media.compress", "create.newFile"] {
            #expect(!ActionRequest(actionID: id, paths: [], source: .finder).needsFocus, "\(id)")
        }
    }

    @Test func isGone() throws {
        #expect(!HostWatch.isGone(getpid()))
        let p = try spawn("/usr/bin/true", [])
        p.waitUntilExit()
        #expect(HostWatch.isGone(p.processIdentifier))
        #expect(!HostWatch.isGone(0))   // never treat "no pid" as gone
    }

    @Test func firesOnceWithinTwoSecondsWhenWatchedProcessExits() async throws {
        let p = try spawn("/bin/sleep", ["0.3"])
        let hits = Counter()
        let start = Date()
        let w = HostWatch(pid: p.processIdentifier, queue: DispatchQueue(label: "hw")) { hits.bump() }
        try await waitFor { hits.value > 0 }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "took \(elapsed) s")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(hits.value == 1)
        _ = w
    }

    @Test func firesAtOnceWhenProcessIsAlreadyGone() async throws {
        let p = try spawn("/usr/bin/true", [])
        p.waitUntilExit()
        let hits = Counter()
        let w = HostWatch(pid: p.processIdentifier, queue: DispatchQueue(label: "hw")) { hits.bump() }
        try await waitFor { hits.value > 0 }
        #expect(hits.value == 1)
        _ = w
    }

    @Test func doesNotFireWhileProcessRuns() async throws {
        let hits = Counter()
        let w = HostWatch(pid: getpid(), queue: DispatchQueue(label: "hw")) { hits.bump() }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(hits.value == 0)
        w.cancel()
    }

    @Test func cancelStopsTheWatch() async throws {
        let p = try spawn("/bin/sleep", ["0.3"])
        let hits = Counter()
        let w = HostWatch(pid: p.processIdentifier, queue: DispatchQueue(label: "hw")) { hits.bump() }
        w.cancel()
        p.waitUntilExit()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(hits.value == 0)
    }

    private func spawn(_ tool: String, _ args: [String]) throws -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try p.run()
        return p
    }

    private func waitFor(_ ok: @Sendable () -> Bool) async throws {
        for _ in 0..<50 where !ok() { try await Task.sleep(nanoseconds: 50_000_000) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}
