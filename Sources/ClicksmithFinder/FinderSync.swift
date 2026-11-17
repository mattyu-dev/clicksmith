import Cocoa
import FinderSync
import ClicksmithKit
import os

private let log = Logger(subsystem: "dev.clicksmith", category: "finder")

/// Thin Finder extension: show menu.json, forward clicks to the app. No logic here (see Overview).
@objc(ClicksmithFinderSync)
final class ClicksmithFinderSync: FIFinderSync, @unchecked Sendable {  // Finder calls us on the main thread
    private let paths = SharedPaths.standard
    private var cachedModel: MenuModel?
    private var cachedStamp: Date?
    /// tag → entry. Finder copies items, so tags are the only id. Tags are never reused:
    /// a click on an older menu must not resolve to an entry of a newer menu.
    private var table: [Int: MenuAction] = [:]
    private var nextTag = 1
    private var hostWatch: HostWatch?
    /// Bundle id of the app this instance serves (Finder, or e.g. an Open/Save panel service).
    /// Learned from the XPC connection of the host's calls. Nil until known.
    private var host: HostWatch.Host?
    /// Heartbeat content before this instance wrote its own: a dialog copy puts it back (T-0019 round 2).
    private var previousHeartbeat: Data?
    private var wroteHeartbeat = false

    override init() {
        super.init()
        noteHost("init")
        observeVolumes()
        observeHost()
        refreshDirectories()
        heartbeatIfFinder(waitedEnough: false)
        // Host not known yet: write an "unknown" heartbeat only if it is still unknown after 3 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.heartbeatIfFinder(waitedEnough: true) }
        log.info("Clicksmith Finder extension loaded pid=\(getpid(), privacy: .public)")
    }

    // MARK: Leave with Finder (T-0019)

    /// We run in Finder's coalition. If we outlive Finder, loginwindow says
    /// "“Finder” is running in the background after it was closed." So exit as soon as Finder ends.
    private func observeHost() {
        // The live Finder: skip one that is terminating, take the newest.
        let finders = NSRunningApplication.runningApplications(withBundleIdentifier: HostWatch.finderBundleID)
            .filter { !$0.isTerminated }
            .map { HostWatch.Candidate(pid: $0.processIdentifier, launched: $0.launchDate) }
        let hostPID = HostWatch.newest(finders)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard HostWatch.isHostTermination(bundleID: app?.bundleIdentifier, pid: app?.processIdentifier, hostPID: hostPID) else { return }
            self?.leave(reason: "workspace notification")
        }
        if let hostPID {
            hostWatch = HostWatch(pid: hostPID) { [weak self] in self?.leave(reason: "process exit watch") }
            log.info("watching Finder pid=\(hostPID, privacy: .public)")
        } else {
            log.error("Finder pid not found: only the workspace notification can end this extension")
        }
    }

    /// Records which app calls us. Open/Save panels run their own instance of this extension;
    /// that instance must survive a Finder restart (Codex T-0019 #4).
    private func noteHost(_ from: String) {
        guard host == nil, let c = NSXPCConnection.current() else { return }
        let pid = c.processIdentifier
        let app = NSRunningApplication(processIdentifier: pid)
        let h = HostWatch.Host(pid: pid, bundleID: app?.bundleIdentifier, isApp: app?.bundleURL?.pathExtension == "app")
        host = h
        log.info("host (\(from, privacy: .public)): pid=\(pid, privacy: .public) bundle=\(h.label, privacy: .public) isApp=\(h.isApp, privacy: .public) path=\(app?.bundleURL?.path ?? "-", privacy: .public)")
        if h.bundleID == HostWatch.finderBundleID {
            heartbeatIfFinder(waitedEnough: true)   // now known as Finder's instance
        } else if wroteHeartbeat, HostWatch.mayRestoreHeartbeat(namedPID: heartbeatPID(), ownPID: getpid()) {
            // A dialog copy wrote "unknown" before it knew its host: put the old heartbeat back,
            // unless a newer load (Finder's) has replaced ours meanwhile (round 3).
            // Nothing to restore (first load): remove ours so it never counts as Finder's (round 4).
            if let old = previousHeartbeat { try? old.write(to: paths.heartbeat, options: .atomic) }
            else { try? FileManager.default.removeItem(at: paths.heartbeat) }
        }
    }

    private func heartbeatIfFinder(waitedEnough: Bool) {
        if HostWatch.heartbeatStep(host: host, waitedEnough: waitedEnough) == .write { writeHeartbeat() }
    }

    private func heartbeatPID() -> pid_t? {
        guard let d = try? Data(contentsOf: paths.heartbeat),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["pid"] as? String).flatMap { pid_t($0) }
    }

    private func leave(reason: String) {
        let alive = host.map { !HostWatch.isGone($0.pid) } ?? false
        guard HostWatch.shouldLeaveWithFinder(host: host, hostAlive: alive) else {
            log.info("Finder quit (\(reason, privacy: .public)): host \(self.host?.label ?? "?", privacy: .public) alive=\(alive, privacy: .public), extension stays")
            return
        }
        log.info("Finder quit (\(reason, privacy: .public)): host \(self.host?.label ?? "unknown", privacy: .public) alive=\(alive, privacy: .public), extension pid=\(getpid(), privacy: .public) exits")
        exit(0)
    }

    override func beginObservingDirectory(at url: URL) { noteHost("observe") }

    // MARK: Watched directories

    private func refreshDirectories() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            urls.insert(v)
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    private func observeVolumes() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshDirectories() }
        }
    }

    /// Proof of load for Doctor and scripts/reload-finder-menu.sh. "host": who loaded us (only Finder's counts).
    private func writeHeartbeat() {
        if previousHeartbeat == nil { previousHeartbeat = try? Data(contentsOf: paths.heartbeat) }
        if let h = host, h.bundleID != HostWatch.finderBundleID { return }   // a dialog copy: not a Finder load
        let info: [String: String] = ["pid": "\(getpid())", "loaded": ISO8601DateFormatter().string(from: Date()),
                                      "host": host?.label ?? "unknown"]
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: info) { try? data.write(to: paths.heartbeat, options: .atomic) }
        wroteHeartbeat = true
    }

    // MARK: Menu

    private func model() -> MenuModel {
        let stamp = (try? paths.menuFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cachedModel, stamp == cachedStamp { return cachedModel }
        let m = (try? MenuModel.load(from: paths.menuFile)) ?? MenuModel.fallback
        cachedModel = m; cachedStamp = stamp
        return m
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        noteHost("menu")
        let context: MenuContext
        switch menuKind {
        case .contextualMenuForItems: context = .items
        case .contextualMenuForContainer: context = .container
        case .contextualMenuForSidebar: context = .sidebar
        case .toolbarItemMenu: context = .toolbar
        @unknown default: return nil
        }
        let sync = FIFinderSyncController.default()
        let selection = context == .items || context == .sidebar ? (sync.selectedItemURLs() ?? []) : []
        let m = model()
        if table.count > 4000 { table = table.filter { $0.key > nextTag - 2000 } }   // keep recent menus only
        let built = build(m.items, context: context, selection: selection)
        guard !built.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        if m.flatten {
            built.forEach(menu.addItem)
        } else {
            let root = NSMenuItem(title: m.rootTitle, action: nil, keyEquivalent: "")
            root.image = MenuIcon.image("bolt.circle")
            let sub = NSMenu(title: m.rootTitle)
            built.forEach(sub.addItem)
            root.submenu = sub
            menu.addItem(root)
        }
        return menu
    }

    private func build(_ nodes: [MenuNode], context: MenuContext, selection: [URL]) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        for node in nodes {
            switch node {
            case .separator:
                if let last = out.last, !last.isSeparatorItem { out.append(.separator()) }
            case let .action(a):
                guard a.matches(context: context, selection: selection) else { continue }
                let item = NSMenuItem(title: a.title, action: #selector(run(_:)), keyEquivalent: "")
                item.target = self
                let tag = nextTag
                nextTag += 1
                item.tag = tag
                table[tag] = a
                item.image = a.symbol.flatMap(MenuIcon.image)
                out.append(item)
            case let .submenu(title, symbol, children):
                let kids = build(children, context: context, selection: selection)
                guard kids.contains(where: { !$0.isSeparatorItem }) else { continue }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = symbol.flatMap(MenuIcon.image)
                let sub = NSMenu(title: title)
                kids.forEach(sub.addItem)
                item.submenu = sub
                out.append(item)
            }
        }
        while out.last?.isSeparatorItem == true { out.removeLast() }
        return out
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let entry = table[sender.tag] else { log.error("unknown tag \(sender.tag)"); return }
        let sync = FIFinderSyncController.default()
        let selected = sync.selectedItemURLs() ?? []
        let target = sync.targetedURL()
        let request = ActionRequest(
            actionID: entry.actionID,
            paths: selected.map(\.path),
            targetDirectory: target?.path ?? selected.first?.deletingLastPathComponent().path,
            options: entry.options,
            source: .finder
        )
        do {
            let file = try RequestInbox(paths: paths).submit(request)
            Self.wake(request.wakeURL(), activate: request.needsFocus)
            // If the app was quitting at this moment, the wake was lost: retry while the file still waits.
            for delay in [2.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if FileManager.default.fileExists(atPath: file.path) { Self.wake(request.wakeURL(), activate: request.needsFocus) }
                }
            }
        } catch {
            log.error("submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Wake the app without taking focus from Finder (the selection stays blue, T-0019).
    private static func wake(_ url: URL, activate: Bool) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        NSWorkspace.shared.open(url, configuration: config) { _, error in
            if let error { log.error("wake failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

/// Finder copies our menu items into its own process. The copy loses the "template" flag of
/// SF Symbols, so Finder draws them plain black (invisible in Dark Mode). A pre-drawn bitmap keeps
/// the colour but has a fixed size, smaller than Finder's own icons. Fix: keep a real symbol (Finder
/// sizes it like its own icons) and bake the colour into it with a palette (not a template flag).
enum MenuIcon {
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]   // main thread only

    static func image(_ symbol: String) -> NSImage? {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            || UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        let key = symbol + (dark ? "|d" : "|l")
        if let hit = cache[key] { return hit }
        // Same colour as menu text (labelColor): near-white in Dark Mode, near-black in Light Mode.
        let tint = dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.85)
        guard let out = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint])) else { return nil }
        out.isTemplate = false
        cache[key] = out
        return out
    }
}

extension MenuModel {
    /// Shown when menu.json is missing: one entry that opens the app so it can write the real menu.
    static var fallback: MenuModel {
        MenuModel(items: [.action(MenuAction(actionID: "app.open", title: "Open Clicksmith…", symbol: "bolt.circle",
                                             contexts: Set(MenuContext.allCases), minCount: 0))])
    }
}
