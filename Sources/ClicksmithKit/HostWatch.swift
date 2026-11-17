import Foundation

/// Makes the Finder extension leave together with Finder (T-0019).
///
/// Our extension runs in Finder's process coalition. When Finder quits but our process lingers,
/// loginwindow says "“Finder” is running in the background after it was closed."
/// The extension uses two signals and exits on the first one:
/// 1. `NSWorkspace.didTerminateApplicationNotification` for `com.apple.finder` (see `isHostTermination`);
/// 2. a kqueue exit watch on Finder's pid (`HostWatch`), in case (1) does not reach a sandboxed appex.
public final class HostWatch: @unchecked Sendable {   // state is only touched on `queue`
    public static let finderBundleID = "com.apple.finder"

    /// True when a terminated app is our host (Finder). A known host pid must match:
    /// an old Finder that ends after a new one started must not stop the new extension.
    public static func isHostTermination(bundleID: String?, pid: pid_t?, hostPID: pid_t?) -> Bool {
        guard bundleID == finderBundleID else { return false }
        guard let hostPID, let pid else { return true }
        return pid == hostPID
    }

    /// Who calls this extension instance (from the XPC connection of a host call).
    public struct Host: Equatable, Sendable {
        public var pid: pid_t
        public var bundleID: String?
        /// A real application (NSRunningApplication with an .app bundle), not a helper process.
        public var isApp: Bool
        public init(pid: pid_t, bundleID: String?, isApp: Bool) { self.pid = pid; self.bundleID = bundleID; self.isApp = isApp }

        /// For logs and the heartbeat.
        public var label: String { bundleID ?? "pid:\(pid)" }
    }

    /// Open/Save panels run out of process in these services.
    public static func isOpenSavePanelService(_ bundleID: String?) -> Bool {
        bundleID?.hasPrefix("com.apple.appkit.xpc.openAndSavePanelService") == true
    }

    /// Leave when Finder quits, unless this instance clearly serves someone else: an Open/Save panel
    /// service, or another application that still runs (Apple: Finder Sync extensions also serve file
    /// dialogs). Unknown host, Finder, a helper process (e.g. one of Finder's own) or a host that is gone:
    /// leave. A dialog copy that ends is started again by its host when needed (T-0019 round 2).
    public static func shouldLeaveWithFinder(host: Host?, hostAlive: Bool) -> Bool {
        guard let host, host.bundleID != finderBundleID else { return true }
        if isOpenSavePanelService(host.bundleID) { return false }
        if host.isApp && hostAlive { return false }
        return true
    }

    public enum HeartbeatStep: Equatable, Sendable { case write, wait, skip }

    /// When an instance writes the load heartbeat (round 3): Finder's copy at once; a dialog/app copy
    /// never; host still unknown → wait, and write "unknown" only after `waitedEnough` (in case the
    /// host can never be read), so a dialog copy normally learns its host before it could write.
    public static func heartbeatStep(host: Host?, waitedEnough: Bool) -> HeartbeatStep {
        guard let host else { return waitedEnough ? .write : .wait }
        return host.bundleID == finderBundleID ? .write : .skip
    }

    /// A copy that wrote an "unknown" heartbeat and then learns it serves a dialog puts the old one
    /// back, but only while the file still names this process: never over a newer Finder load.
    public static func mayRestoreHeartbeat(namedPID: pid_t?, ownPID: pid_t) -> Bool { namedPID == ownPID }

    /// Heartbeat "host" values that count as Finder's instance. Missing (older builds) and "unknown"
    /// (host not seen yet) count; a known other host (a dialog copy) does not.
    public static func heartbeatIsFinders(host: String?) -> Bool {
        host == nil || host == "unknown" || host == finderBundleID
    }

    public struct Candidate: Equatable, Sendable {
        public var pid: pid_t
        public var launched: Date?
        public init(pid: pid_t, launched: Date?) { self.pid = pid; self.launched = launched }
    }

    /// The Finder to watch: the newest launch (callers drop terminated ones first).
    public static func newest(_ c: [Candidate]) -> pid_t? {
        c.max { ($0.launched ?? .distantPast) < ($1.launched ?? .distantPast) }?.pid
    }

    /// True when no process with this pid exists any more.
    public static func isGone(_ pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == -1 && errno == ESRCH
    }

    public let pid: pid_t
    private let queue: DispatchQueue
    private var source: DispatchSourceProcess?
    private var fired = false
    private let onExit: @Sendable () -> Void

    /// Watches `pid` and calls `onExit` once (on `queue`) when it ends. If the process is already
    /// gone at start, `onExit` runs at once: a kqueue watch on a dead pid never fires.
    public init(pid: pid_t, queue: DispatchQueue = .main, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid; self.queue = queue; self.onExit = onExit
        queue.async { self.start() }
    }

    private func start() {
        guard pid > 0 else { return }
        let s = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        s.setEventHandler { [weak self] in self?.fire() }
        s.resume()
        source = s
        if Self.isGone(pid) { fire() }   // ended before the watch was armed
    }

    private func fire() {
        guard !fired else { return }
        fired = true
        source?.cancel(); source = nil
        onExit()
    }

    public func cancel() { queue.async { self.fired = true; self.source?.cancel(); self.source = nil } }
}
