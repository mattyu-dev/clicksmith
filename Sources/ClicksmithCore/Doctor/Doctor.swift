import Foundation
import ClicksmithKit

/// Runs a system tool and returns stdout. Injected so tests can fake pluginkit/pgrep.
public protocol CommandRunner: Sendable {
    func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String)
}

public struct SystemCommandRunner: CommandRunner {
    /// A hung tool (pluginkit can hang) must not freeze Doctor's Fix button.
    public var timeout: TimeInterval
    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    public func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        // Read on another thread (no pipe deadlock), wait for the exit with a time limit.
        let box = OutputBox()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { box.data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 1) }
            _ = read.wait(timeout: .now() + 1)
            return (-2, "\(URL(fileURLWithPath: tool).lastPathComponent) timed out after \(Int(timeout)) s")
        }
        let complete = read.wait(timeout: .now() + 2) == .success   // a child that keeps the pipe open
        return (p.terminationStatus, complete ? String(data: box.data, encoding: .utf8) ?? "" : "")
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }   // written once, read after the signal
}

/// One line of `pluginkit -m -v -i <id>`.
public struct PluginRegistration: Equatable, Sendable {
    public enum Election: Character, Sendable { case enabled = "+", disabled = "-", unset = " ", superseded = "=", ignored = "!" }
    public var election: Election
    public var version: String
    public var path: String

    /// Parses lines like "+    dev.clicksmith.app.finder(0.1.0)\tUUID\tDATE\t/path/X.appex".
    public static func parse(_ output: String, id: String) -> [PluginRegistration] {
        output.split(separator: "\n").compactMap { raw in
            let line = String(raw)
            guard let idRange = line.range(of: id + "(") else { return nil }
            let prefix = line[..<idRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let election = prefix.first.flatMap(Election.init(rawValue:)) ?? .unset
            let afterID = line[idRange.upperBound...]
            let version = String(afterID.prefix { $0 != ")" })
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let path = fields.last, path.hasPrefix("/") else { return nil }
            return PluginRegistration(election: election, version: version, path: path)
        }
    }
}

public struct DoctorCheck: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case ok, warning, problem }
    public enum Fix: String, Sendable, CaseIterable {
        case enableExtension, removeStaleRegistrations, registerExtension, restartFinder, rewriteMenu, clearStuckRequests
        /// "Reload Finder menu": toggles the pluginkit election. Finder keeps running (T-0019).
        case reloadExtension

        public var title: String {
            switch self {
            case .enableExtension: "Turn on Finder extension"
            case .removeStaleRegistrations: "Remove old copies"
            case .registerExtension: "Register Finder extension"
            case .restartFinder: "Restart Finder"
            case .rewriteMenu: "Rewrite menu"
            case .clearStuckRequests: "Clear old clicks"
            case .reloadExtension: "Reload Finder menu"
            }
        }
    }
    public var id: String
    public var title: String
    public var status: Status
    public var detail: String
    public var fix: Fix?
}

/// Finds and fixes why the Finder menu does not show (competitor's #1 complaint).
public struct Doctor: Sendable {
    public let paths: SharedPaths
    public let appBundle: URL
    public let runner: CommandRunner
    public let extensionID: String
    /// Waits between reload steps. Tests pass a no-op.
    public let pause: @Sendable (TimeInterval) -> Void

    public init(paths: SharedPaths = .standard, appBundle: URL, runner: CommandRunner = SystemCommandRunner(),
                extensionID: String = SharedPaths.extensionBundleID,
                pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.paths = paths; self.appBundle = appBundle; self.runner = runner; self.extensionID = extensionID
        self.pause = pause
    }

    /// Process path pattern of our extension (pgrep/pkill -f).
    static let extensionProcessPattern = "ClicksmithFinder.appex/Contents/MacOS/ClicksmithFinder"

    var appexPath: String { appBundle.appendingPathComponent("Contents/PlugIns/ClicksmithFinder.appex").path }

    public func diagnose(now: Date = Date()) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let p = appBundle.path

        // 1. Location
        if p.contains("/AppTranslocation/") {
            checks.append(.init(id: "location", title: "App location", status: .problem,
                                detail: "macOS is running a temporary copy. Move Clicksmith to Applications and open it again.", fix: nil))
        } else if !(p.hasPrefix("/Applications/") || p.contains("/Applications/")) {
            checks.append(.init(id: "location", title: "App location", status: .warning,
                                detail: "Running from \(p). Put it in Applications so Finder keeps the extension.", fix: nil))
        } else {
            checks.append(.init(id: "location", title: "App location", status: .ok, detail: p, fix: nil))
        }

        // 2. Registration
        let regs = PluginRegistration.parse(runner.run("/usr/bin/pluginkit", ["-m", "-v", "-A", "-D", "-i", extensionID]).output, id: extensionID)
        let ours = regs.filter { $0.path == appexPath }
        let others = regs.filter { $0.path != appexPath }
        if ours.isEmpty {
            checks.append(.init(id: "registered", title: "Finder extension registered", status: .problem,
                                detail: "macOS does not know this copy's extension.", fix: .registerExtension))
        } else {
            checks.append(.init(id: "registered", title: "Finder extension registered", status: .ok, detail: "version \(ours[0].version)", fix: nil))
        }
        if !others.isEmpty {
            checks.append(.init(id: "duplicates", title: "Other Clicksmith copies", status: .problem,
                                detail: "Finder may load an old copy: \(others.map(\.path).joined(separator: ", "))", fix: .removeStaleRegistrations))
        }

        // 3. Enabled
        if let r = ours.first {
            if r.election == .enabled {
                checks.append(.init(id: "enabled", title: "Finder extension enabled", status: .ok, detail: "On in System Settings.", fix: nil))
            } else {
                checks.append(.init(id: "enabled", title: "Finder extension enabled", status: .problem,
                                    detail: "Turned off. Fix turns it on (System Settings › General › Login Items & Extensions › Finder).", fix: .enableExtension))
            }
        }

        // 4. Loaded by Finder
        let loaded = extensionLoaded()
        checks.append(.init(id: "loaded", title: "Finder loaded the menu", status: loaded ? .ok : .problem,
                            detail: loaded ? "Running in Finder." : "Finder has not loaded it. Fix reloads the Finder menu.",
                            fix: loaded ? nil : .reloadExtension))

        // 5. Menu file
        if let m = try? MenuModel.load(from: paths.menuFile) {
            checks.append(.init(id: "menu", title: "Menu file", status: .ok, detail: "\(Self.count(m.items)) entries.", fix: nil))
        } else {
            checks.append(.init(id: "menu", title: "Menu file", status: .problem, detail: "menu.json missing or unreadable.", fix: .rewriteMenu))
        }

        // 6. Stuck requests (clicks the app never picked up)
        let stuck = stuckRequests(now: now)
        if !stuck.isEmpty {
            checks.append(.init(id: "inbox", title: "Pending clicks", status: .warning,
                                detail: "\(stuck.count) old request(s) never ran.", fix: .clearStuckRequests))
        }
        return checks
    }

    public var isHealthy: Bool { !diagnose().contains { $0.status == .problem } }

    /// Apply one fix. `menu` writes menu.json (the app passes its own registry/settings).
    @discardableResult
    public func apply(_ fix: DoctorCheck.Fix, writeMenu: () throws -> Void = {}) -> Bool {
        switch fix {
        case .registerExtension:
            return runner.run("/usr/bin/pluginkit", ["-a", appexPath]).status == 0
                && runner.run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID]).status == 0
        case .enableExtension:
            return runner.run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID]).status == 0
        case .removeStaleRegistrations:
            // Never unregister anything until our own copy exists and is registered (review #1).
            guard FileManager.default.fileExists(atPath: appexPath + "/Contents/Info.plist") else { return false }
            let regs = PluginRegistration.parse(runner.run("/usr/bin/pluginkit", ["-m", "-v", "-A", "-D", "-i", extensionID]).output, id: extensionID)
            let mine = Self.canonical(appexPath)
            guard regs.contains(where: { Self.canonical($0.path) == mine }) else { return false }
            for r in regs where Self.canonical(r.path) != mine { _ = runner.run("/usr/bin/pluginkit", ["-r", r.path]) }
            return true
        case .reloadExtension:
            // Finder drops the extension, then loads a fresh copy. No Finder restart, so no
            // "Finder is running in the background" message (T-0019).
            let off = runner.run("/usr/bin/pluginkit", ["-e", "ignore", "-i", extensionID]).status == 0
            pause(1)
            let on = runner.run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID]).status == 0
            return off && on
        case .restartFinder:
            // Last resort only. Our extension must be gone before Finder goes: if it outlives Finder
            // in Finder's coalition, loginwindow shows "“Finder” is running in the background" (T-0019).
            // Disable it so Finder cannot start it again meanwhile; always turn it back on.
            _ = runner.run("/usr/bin/pluginkit", ["-e", "ignore", "-i", extensionID])
            defer { _ = runner.run("/usr/bin/pluginkit", ["-e", "use", "-i", extensionID]) }
            guard stopExtension() else { return false }   // never kill Finder while it still runs
            return runner.run("/usr/bin/killall", ["Finder"]).status == 0
        case .rewriteMenu:
            return (try? writeMenu()) != nil
        case .clearStuckRequests:
            // Only requests that are still old now; fresh clicks stay (review #2).
            for f in stuckRequests(now: Date()) { try? FileManager.default.removeItem(at: f) }
            return true
        }
    }

    /// Fix everything fixable, in a safe order. A registration change ends with a menu reload.
    /// Finder restarts only as the very last step, when the reload did not load the extension.
    public func fixAll(writeMenu: () throws -> Void = {}) -> [DoctorCheck] {
        let order: [DoctorCheck.Fix] = [.registerExtension, .removeStaleRegistrations, .enableExtension, .rewriteMenu, .clearStuckRequests]
        var needed = Set(diagnose().compactMap(\.fix))
        for f in order where needed.contains(f) { apply(f, writeMenu: writeMenu) }
        if needed.contains(.registerExtension) || needed.contains(.enableExtension) || needed.contains(.removeStaleRegistrations) {
            needed.insert(.reloadExtension)   // Finder may hold the old or no copy: reload it in place
        }
        if needed.contains(.reloadExtension) || needed.contains(.restartFinder) {
            // Success = a NEW extension process wrote its heartbeat. The old process lingers
            // 10–20 s after a reload, so "some extension runs" proves nothing (Codex T-0019 #1).
            var before = readHeartbeat()
            var fresh = false
            if needed.contains(.reloadExtension) {
                apply(.reloadExtension)
                fresh = waitForFreshExtension(since: before, seconds: 15)   // "unknown" heartbeat lands 3 s after a slow load
            }
            if !fresh {
                before = readHeartbeat()
                if apply(.restartFinder) { _ = waitForFreshExtension(since: before, seconds: 10) }
            }
        }
        return diagnose()
    }

    func extensionPIDs() -> Set<Int32> {
        let pg = runner.run("/usr/bin/pgrep", ["-f", Self.extensionProcessPattern])
        guard pg.status == 0 else { return [] }
        return Set(pg.output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
    }

    func extensionLoaded() -> Bool { !extensionPIDs().isEmpty }

    /// What the extension writes when it starts (`extension-heartbeat.json`).
    struct Heartbeat: Equatable { var pid: Int32; var loaded: String; var host: String? = nil }

    func readHeartbeat() -> Heartbeat? {
        guard let data = try? Data(contentsOf: paths.heartbeat),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? String).flatMap(Int32.init) ?? (obj["pid"] as? Int).map(Int32.init) else { return nil }
        return Heartbeat(pid: pid, loaded: obj["loaded"] as? String ?? "", host: obj["host"] as? String)
    }

    /// A new extension started after `before`: the heartbeat names another pid, and that pid runs now.
    func freshExtension(since before: Heartbeat?) -> Bool {
        guard let now = readHeartbeat(), now.pid != before?.pid,
              HostWatch.heartbeatIsFinders(host: now.host) else { return false }   // a dialog copy is not a reload
        return extensionPIDs().contains(now.pid)
    }

    func waitForFreshExtension(since before: Heartbeat?, seconds: Int) -> Bool {
        for i in 0...(seconds * 2) {
            if freshExtension(since: before) { return true }
            if i < seconds * 2 { pause(0.5) }
        }
        return false
    }

    /// Ends every extension process and waits until they are gone (≤5 s, then SIGKILL, ≤2 s more).
    func stopExtension() -> Bool {
        guard extensionLoaded() else { return true }
        _ = runner.run("/usr/bin/pkill", ["-f", Self.extensionProcessPattern])
        for _ in 0..<10 { if !extensionLoaded() { return true }; pause(0.5) }
        _ = runner.run("/usr/bin/pkill", ["-9", "-f", Self.extensionProcessPattern])
        for _ in 0..<4 { if !extensionLoaded() { return true }; pause(0.5) }
        return !extensionLoaded()
    }

    func stuckRequests(now: Date) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate).map { now.timeIntervalSince($0) > 60 } ?? false }
    }

    static func canonical(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }

    static func count(_ nodes: [MenuNode]) -> Int {
        nodes.reduce(0) { n, node in
            switch node { case .action: n + 1; case .submenu(_, _, let c): n + count(c); case .separator: n }
        }
    }
}
