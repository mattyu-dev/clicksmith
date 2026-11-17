import Foundation
import Testing
@testable import ClicksmithCore

final class FakeCommands: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    var pluginkit = ""
    /// Running extension pids (what pgrep finds).
    var extPIDs: [Int32] = [123]
    var finderLoaded: Bool {
        get { lock.withLock { !extPIDs.isEmpty } }
        set { lock.withLock { extPIDs = newValue ? [123] : [] } }
    }
    /// Simulates Finder starting a NEW extension after `pluginkit -e use` (a working reload):
    /// a new pid runs and writes the heartbeat (if `heartbeat` is set). Old pids linger.
    var loadsOnUse = false
    var heartbeat: URL?
    /// pgrep calls after a plain pkill before the extension is gone (nil = SIGTERM is ignored).
    var pkillDelay: Int? = 0
    /// Set when Finder was killed while our extension still ran (the bug of Codex T-0019 #3).
    private(set) var killedFinderWithExtensionAlive = false
    private var dying: Int?
    private(set) var calls: [[String]] = []

    func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        lock.withLock {
            calls.append([tool] + args)
            switch tool {
            case "/usr/bin/pluginkit" where args.first == "-m": return (0, pluginkit)
            case "/usr/bin/pluginkit" where args.prefix(2) == ["-e", "use"] && loadsOnUse:
                let pid = (extPIDs.max() ?? 199) + 1
                extPIDs.append(pid)
                if let heartbeat {
                    try? JSONSerialization.data(withJSONObject: ["pid": "\(pid)", "loaded": "2026-11-17T10:00:00Z"]).write(to: heartbeat)
                }
                return (0, "")
            case "/usr/bin/pkill":
                if args.first == "-9" { extPIDs = [] } else if let d = pkillDelay { dying = d }
                return (0, "")
            case "/usr/bin/killall":
                if !extPIDs.isEmpty { killedFinderWithExtensionAlive = true }
                return (0, "")
            case "/usr/bin/pgrep":
                if let d = dying { if d <= 0 { extPIDs = []; dying = nil } else { dying = d - 1 } }
                return extPIDs.isEmpty ? (1, "") : (0, extPIDs.map { "\($0)\n" }.joined())
            default: return (0, "")
            }
        }
    }
}

@Suite struct DoctorTests {
    let app = URL(fileURLWithPath: "/Users/x/Applications/Clicksmith.app")
    var appex: String { app.path + "/Contents/PlugIns/ClicksmithFinder.appex" }
    let id = "dev.clicksmith.app.finder"

    func paths() throws -> SharedPaths { let p = SharedPaths(root: try tempDir("doc")); try p.ensureExists(); return p }

    @Test func parsesPluginkitLines() {
        let out = "+    \(id)(0.1.0)\tF745F61A\t2026-11-16 15:06:38 +0000\t\(appex)\n-    \(id)(0.0.9)\tAAAA\t2026-11-01\t/Applications/Old.app/Contents/PlugIns/ClicksmithFinder.appex\n (2 plug-ins)\n"
        let r = PluginRegistration.parse(out, id: id)
        #expect(r.count == 2)
        #expect(r[0].election == .enabled && r[0].version == "0.1.0" && r[0].path == appex)
        #expect(r[1].election == .disabled)
    }

    @Test func healthyWhenAllGood() throws {
        let p = try paths()
        try MenuModel(items: [.action(MenuAction(actionID: "a", title: "A"))]).write(to: p.menuFile)
        let cmd = FakeCommands(); cmd.pluginkit = "+    \(id)(0.1.0)\tU\tD\t\(appex)\n"
        let checks = Doctor(paths: p, appBundle: app, runner: cmd).diagnose()
        #expect(checks.allSatisfy { $0.status == .ok }, "\(checks)")
    }

    @Test func detectsDisabledDuplicateUnloadedAndMissingMenu() throws {
        let p = try paths()
        let cmd = FakeCommands(); cmd.finderLoaded = false
        cmd.pluginkit = "-    \(id)(0.1.0)\tU\tD\t\(appex)\n+    \(id)(0.0.1)\tU\tD\t/tmp/Other.app/Contents/PlugIns/ClicksmithFinder.appex\n"
        let fixes = Set(Doctor(paths: p, appBundle: app, runner: cmd).diagnose().compactMap(\.fix))
        #expect(fixes == [.enableExtension, .removeStaleRegistrations, .reloadExtension, .rewriteMenu])
    }

    @Test func fixAllRunsFixesInSafeOrder() throws {
        let p = try paths()
        // A real bundle on disk: stale copies are only removed when ours exists.
        let realApp = try tempDir("bundle").appendingPathComponent("Clicksmith.app")
        let realAppex = realApp.appendingPathComponent("Contents/PlugIns/ClicksmithFinder.appex")
        try FileManager.default.createDirectory(at: realAppex.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try touch(realAppex.appendingPathComponent("Contents"), "Info.plist")
        let cmd = FakeCommands(); cmd.finderLoaded = false
        cmd.pluginkit = "-    \(id)(0.1.0)\tU\tD\t\(realAppex.path)\n+    \(id)(0.0.1)\tU\tD\t/tmp/Other.app/Contents/PlugIns/ClicksmithFinder.appex\n"
        var wrote = false
        _ = Doctor(paths: p, appBundle: realApp, runner: cmd, pause: { _ in }).fixAll { wrote = true }
        let mutating = cmd.calls.filter { ["/usr/bin/killall", "/usr/bin/pkill"].contains($0[0]) || ($0[0] == "/usr/bin/pluginkit" && $0[1] != "-m") }
        #expect(mutating.contains(["/usr/bin/pluginkit", "-r", "/tmp/Other.app/Contents/PlugIns/ClicksmithFinder.appex"]))
        #expect(!mutating.contains { $0.count > 2 && $0[1] == "-r" && $0[2] == realAppex.path })
        #expect(mutating.contains(["/usr/bin/pluginkit", "-e", "use", "-i", id]))
        // The extension never loads here: reload first, Finder restart only as the very last step
        // (no extension runs, so nothing to stop), election restored at the end (T-0019).
        #expect(Array(mutating.suffix(5)) == [
            ["/usr/bin/pluginkit", "-e", "ignore", "-i", id],
            ["/usr/bin/pluginkit", "-e", "use", "-i", id],
            ["/usr/bin/pluginkit", "-e", "ignore", "-i", id],
            ["/usr/bin/killall", "Finder"],
            ["/usr/bin/pluginkit", "-e", "use", "-i", id],
        ], "\(mutating)")
        #expect(mutating.filter { $0[0] == "/usr/bin/killall" }.count == 1)
        #expect(wrote)
    }

    @Test("T-0019: a working reload never restarts Finder") func reloadInsteadOfFinderRestart() throws {
        let p = try paths()
        try MenuModel(items: [.action(MenuAction(actionID: "a", title: "A"))]).write(to: p.menuFile)
        let cmd = FakeCommands(); cmd.finderLoaded = false; cmd.loadsOnUse = true; cmd.heartbeat = p.heartbeat
        cmd.pluginkit = "+    \(id)(0.1.0)\tU\tD\t\(appex)\n"
        let after = Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).fixAll()
        let mutating = cmd.calls.filter { ["/usr/bin/killall", "/usr/bin/pkill"].contains($0[0]) || ($0[0] == "/usr/bin/pluginkit" && $0[1] != "-m") }
        #expect(mutating == [["/usr/bin/pluginkit", "-e", "ignore", "-i", id], ["/usr/bin/pluginkit", "-e", "use", "-i", id]])
        #expect(after.first { $0.id == "loaded" }?.status == .ok)
    }

    @Test("T-0019: no Doctor check ever proposes a Finder restart") func diagnoseNeverRestartsFinder() throws {
        let cmd = FakeCommands(); cmd.finderLoaded = false
        cmd.pluginkit = "+    \(id)(0.1.0)\tU\tD\t\(appex)\n"
        let checks = Doctor(paths: try paths(), appBundle: app, runner: cmd).diagnose()
        #expect(!checks.contains { $0.fix == .restartFinder })
        #expect(checks.first { $0.id == "loaded" }?.fix == .reloadExtension)
        #expect(DoctorCheck.Fix.reloadExtension.title == "Reload Finder menu")
    }

    @Test("T-0019: reload toggles the election with a pause in between") func reloadSequence() throws {
        let cmd = FakeCommands()
        let pauses = PauseLog()
        let d = Doctor(paths: try paths(), appBundle: app, runner: cmd, pause: { pauses.add($0) })
        #expect(d.apply(.reloadExtension))
        #expect(cmd.calls == [["/usr/bin/pluginkit", "-e", "ignore", "-i", id], ["/usr/bin/pluginkit", "-e", "use", "-i", id]])
        #expect(pauses.values == [1])
    }

    @Test("T-0019: healthy extension → fixAll touches nothing") func healthyFixAllNoRestart() throws {
        let p = try paths()
        try MenuModel(items: [.action(MenuAction(actionID: "a", title: "A"))]).write(to: p.menuFile)
        let cmd = FakeCommands(); cmd.pluginkit = "+    \(id)(0.1.0)\tU\tD\t\(appex)\n"
        _ = Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).fixAll()
        #expect(!cmd.calls.contains { ["/usr/bin/killall", "/usr/bin/pkill"].contains($0[0]) || ($0[0] == "/usr/bin/pluginkit" && $0[1] != "-m") })
    }

    @Test func translocatedAppIsAProblem() throws {
        let cmd = FakeCommands()
        let d = Doctor(paths: try paths(), appBundle: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Clicksmith.app"), runner: cmd)
        #expect(d.diagnose().first { $0.id == "location" }?.status == .problem)
    }
}

@Suite struct DoctorReviewTests {
    let id = "dev.clicksmith.app.finder"

    @Test("review #1: missing app → stale copies are not removed") func neverUnregistersBeforeOursWorks() throws {
        let p = SharedPaths(root: try tempDir("d")); try p.ensureExists()
        let cmd = FakeCommands()
        cmd.pluginkit = "+    \(id)(0.1.0)\tU\tD\t/Users/x/Applications/Clicksmith.app/Contents/PlugIns/ClicksmithFinder.appex\n"
        let d = Doctor(paths: p, appBundle: URL(fileURLWithPath: "/tmp/Missing-\(UUID()).app"), runner: cmd, pause: { _ in })
        _ = d.fixAll()
        #expect(!cmd.calls.contains { $0.count > 1 && $0[1] == "-r" })
    }

    @Test("review #2: only old requests are cleared") func freshRequestsSurvive() throws {
        let p = SharedPaths(root: try tempDir("d")); try p.ensureExists()
        let old = try touch(p.inbox, "old.json"), fresh = try touch(p.inbox, "fresh.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: old.path)
        Doctor(paths: p, appBundle: URL(fileURLWithPath: "/Applications/Clicksmith.app"), runner: FakeCommands()).apply(.clearStuckRequests)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test("review #3: unreadable settings are kept aside") func brokenSettingsPreserved() throws {
        let p = SharedPaths(root: try tempDir("d")); try p.ensureExists()
        try Data("{ not json".utf8).write(to: p.settingsFile)
        #expect(ClicksmithSettings.load(p) == ClicksmithSettings())
        #expect(names(p.root).contains { $0.hasPrefix("settings.broken-") })
    }
}

final class PauseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var v: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { v } }
    func add(_ t: TimeInterval) { lock.withLock { v.append(t) } }
}

@Suite struct CommandRunnerTimeoutTests {
    @Test("a hung tool times out") func hungToolTimesOut() {
        let start = Date()
        let r = SystemCommandRunner(timeout: 0.5).run("/bin/sleep", ["10"])
        #expect(r.status == -2 && r.output.contains("timed out"), "\(r)")
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test func normalToolStillWorks() {
        let r = SystemCommandRunner().run("/bin/echo", ["hi"])
        #expect(r.status == 0 && r.output == "hi\n")
    }
}

@Suite struct DoctorReloadReviewTests {
    let app = URL(fileURLWithPath: "/Users/x/Applications/Clicksmith.app")
    var appex: String { app.path + "/Contents/PlugIns/ClicksmithFinder.appex" }
    let id = "dev.clicksmith.app.finder"
    let pattern = "ClicksmithFinder.appex/Contents/MacOS/ClicksmithFinder"

    /// Disabled extension (needs enable + reload); old process 100 runs and wrote the heartbeat.
    func setup() throws -> (SharedPaths, FakeCommands) {
        let p = SharedPaths(root: try tempDir("dr")); try p.ensureExists()
        try MenuModel(items: [.action(MenuAction(actionID: "a", title: "A"))]).write(to: p.menuFile)
        try JSONSerialization.data(withJSONObject: ["pid": "100", "loaded": "2026-11-17T10:00:00Z"]).write(to: p.heartbeat)
        let cmd = FakeCommands(); cmd.extPIDs = [100]; cmd.heartbeat = p.heartbeat
        cmd.pluginkit = "-    \(id)(0.1.0)\tU\tD\t\(appex)\n"
        return (p, cmd)
    }

    func mutating(_ cmd: FakeCommands) -> [[String]] {
        cmd.calls.filter { ["/usr/bin/killall", "/usr/bin/pkill"].contains($0[0]) || ($0[0] == "/usr/bin/pluginkit" && $0[1] != "-m") }
    }

    @Test("Codex T-0019 #1: an old extension that lingers is not a successful reload") func lingeringOldIsNotSuccess() throws {
        let (p, cmd) = try setup()   // no replacement starts: loadsOnUse = false
        _ = Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).fixAll()
        let m = mutating(cmd)
        #expect(m.contains(["/usr/bin/killall", "Finder"]), "escalates to the last resort: \(m)")
        #expect(!cmd.killedFinderWithExtensionAlive)
    }

    @Test("Codex T-0019 #1: same pid in the heartbeat again is not fresh") func samePidNotFresh() throws {
        let (p, cmd) = try setup()
        let d = Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in })
        let before = d.readHeartbeat()
        #expect(before == .init(pid: 100, loaded: "2026-11-17T10:00:00Z"))
        try JSONSerialization.data(withJSONObject: ["pid": "100", "loaded": "2026-11-17T10:00:09Z"]).write(to: p.heartbeat)
        #expect(!d.freshExtension(since: before))
        try JSONSerialization.data(withJSONObject: ["pid": "101", "loaded": "2026-11-17T10:00:09Z"]).write(to: p.heartbeat)
        #expect(!d.freshExtension(since: before), "pid 101 does not run")
        cmd.extPIDs = [100, 101]
        #expect(d.freshExtension(since: before))
    }

    @Test("round 2 #4: a heartbeat from an Open/Save dialog copy is not a reload") func dialogHeartbeatNotFresh() throws {
        let (p, cmd) = try setup()
        let d = Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in })
        let before = d.readHeartbeat()
        cmd.extPIDs = [100, 101]
        try JSONSerialization.data(withJSONObject: ["pid": "101", "loaded": "2026-11-17T10:00:09Z",
                                                     "host": "com.apple.appkit.xpc.openAndSavePanelService"]).write(to: p.heartbeat)
        #expect(!d.freshExtension(since: before))
        try JSONSerialization.data(withJSONObject: ["pid": "101", "loaded": "2026-11-17T10:00:09Z", "host": "com.apple.finder"]).write(to: p.heartbeat)
        #expect(d.freshExtension(since: before))
    }

    @Test("Codex T-0019 #1: a new process with a new heartbeat is success, no Finder restart") func newProcessIsSuccess() throws {
        let (p, cmd) = try setup(); cmd.loadsOnUse = true   // old 100 lingers, 101 starts
        _ = Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).fixAll()
        #expect(!mutating(cmd).contains { $0[0] == "/usr/bin/killall" || $0[0] == "/usr/bin/pkill" }, "\(mutating(cmd))")
    }

    @Test("Codex T-0019 #3: Finder is killed only after our extension has exited") func delayedTermination() throws {
        let (p, cmd) = try setup(); cmd.pkillDelay = 3
        #expect(Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).apply(.restartFinder))
        #expect(!cmd.killedFinderWithExtensionAlive)
        let m = mutating(cmd)
        #expect(m == [["/usr/bin/pluginkit", "-e", "ignore", "-i", id], ["/usr/bin/pkill", "-f", pattern],
                      ["/usr/bin/killall", "Finder"], ["/usr/bin/pluginkit", "-e", "use", "-i", id]], "\(m)")
    }

    @Test("Codex T-0019 #3: SIGTERM ignored → SIGKILL, still before Finder") func sigkillFallback() throws {
        let (p, cmd) = try setup(); cmd.pkillDelay = nil
        #expect(Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).apply(.restartFinder))
        #expect(!cmd.killedFinderWithExtensionAlive)
        #expect(mutating(cmd).contains(["/usr/bin/pkill", "-9", "-f", pattern]))
    }

    @Test("Codex T-0019 #3: an extension that cannot be stopped → Finder is not killed, election restored") func unkillableExtension() throws {
        final class Stubborn: CommandRunner, @unchecked Sendable {
            let lock = NSLock(); var calls: [[String]] = []
            func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
                lock.withLock { calls.append([tool] + args) }
                return tool == "/usr/bin/pgrep" ? (0, "100\n") : (0, "")
            }
        }
        let (p, _) = try setup()
        let cmd = Stubborn()
        #expect(!Doctor(paths: p, appBundle: app, runner: cmd, pause: { _ in }).apply(.restartFinder))
        #expect(!cmd.calls.contains { $0[0] == "/usr/bin/killall" })
        #expect(cmd.calls.last == ["/usr/bin/pluginkit", "-e", "use", "-i", id])
    }
}
