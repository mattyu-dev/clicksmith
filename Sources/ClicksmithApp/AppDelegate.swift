import AppKit
import ClicksmithCore
import os

private let log = Logger(subsystem: "dev.clicksmith", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let paths = SharedPaths.standard
    lazy var inbox = RequestInbox(paths: paths)
    private var handledURL = false
    private var lastActivity = Date()
    private var idleTimer: Timer?
    /// Quit after this long with no job, no window, and no click.
    static let idleLimit: TimeInterval = 120

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try paths.ensureExists() } catch { log.error("setup: \(error.localizedDescription, privacy: .public)") }
        let recovery = AppModel.shared.journal.recoverPending()
        let interrupted = inbox.interrupted()
        if recovery.hasFindings || !interrupted.isEmpty {
            // Not a modal alert: the app is woken without activation (T-0019), so a modal would open
            // behind Finder and block the click. A notice stays until closed.
            let details = recovery.summary(interrupted: interrupted)
            ProgressPanel.shared.notice(Notice(title: "Clicksmith recovered after an interruption", message: details, kind: .error))
        }
        AppModel.shared.refreshUndo()
        AppModel.shared.persist()               // fresh menu.json for the extension
        for r in inbox.drain() { handledURL = true; AppModel.shared.perform(r) }   // clicks that arrived while we were down
        ProgressPanel.shared.start()
        NSApp.mainMenu = Self.mainMenu()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.quitIfIdle() }
        }
        // Opened by hand (Finder, Spotlight, Launchpad): show Settings. Opened by a menu click: stay quiet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            // First run / broken menu: open on Doctor, which explains how to turn the menu on.
            if self?.handledURL == false { AppModel.shared.openSettings(tab: AppModel.shared.doctor.isHealthy ? "general" : "doctor") }
        }
        log.info("Clicksmith up")
    }

    /// Plain AppKit start has no menu: without Edit/Window items, ⌘C ⌘V ⌘X ⌘A ⌘Z and ⌘W do nothing in our windows.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title); items.forEach(m.addItem); holder.submenu = m; main.addItem(holder)
        }
        func item(_ t: String, _ a: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        sub("Clicksmith", [item("Quit Clicksmith", #selector(NSApplication.terminate(_:)), "q")])
        sub("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        sub("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w"), item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppModel.shared.openSettings(); return false
    }

    func quitIfIdle() {
        // A request whose wake URL was lost (extension killed, open failed): run it now.
        for r in inbox.drain() { lastActivity = Date(); AppModel.shared.perform(r) }
        let busy = !JobCenter.shared.running.isEmpty
            || NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == "clicksmith.user" }   // settings, rename
            || !inbox.pending().isEmpty
            || ProgressPanel.shared.isShowing
        if busy { lastActivity = Date(); return }
        if Date().timeIntervalSince(lastActivity) > Self.idleLimit {
            log.info("idle: quitting")
            NSApp.terminate(nil)
        }
    }

    /// Last check before exit: a click that landed in the inbox during shutdown is run, not lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Never lose undo records: show a rename window whose undo is not saved yet.
        if let w = RenameWindowController.unsavedWindow {
            NSApp.activate(); w.makeKeyAndOrderFront(nil); NSSound.beep()
            return .terminateCancel
        }
        // Running jobs: cancel them, let them finish journaling, then quit.
        let running = JobCenter.shared.running
        if !running.isEmpty {
            running.forEach { $0.cancel() }
            Task { @MainActor in
                for j in running { await j.task?.value }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        let late = inbox.drain()
        guard late.isEmpty else {
            lastActivity = Date()
            late.forEach { AppModel.shared.perform($0) }
            return .terminateCancel
        }
        return .terminateNow
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        handledURL = true; lastActivity = Date()
        if let id = ActionRequest.requestID(from: url) {
            if let r = inbox.take(id) { AppModel.shared.perform(r) }
        } else if url.host == "settings" {
            AppModel.shared.openSettings()
        }
        // "clicksmith://refresh" (install script): only rewrite menu.json, done at launch.
    }
}
