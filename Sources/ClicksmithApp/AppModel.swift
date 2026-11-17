import AppKit
import SwiftUI
import Observation
import ClicksmithCore
import os

private let log = Logger(subsystem: "dev.clicksmith", category: "model")

/// App-wide state: settings, registry, journal. The only writer of settings.json and menu.json.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    let paths = SharedPaths.standard
    let registry = ActionRegistry.standard()
    @ObservationIgnored lazy var journal = UndoJournal(directory: paths.journal)

    var settings: ClicksmithSettings { didSet { persist() } }
    private(set) var lastUndoTitle: String?

    init() {
        settings = ClicksmithSettings.load(SharedPaths.standard)
        refreshUndo()
    }

    var doctor: Doctor { Doctor(paths: paths, appBundle: Bundle.main.bundleURL) }

    func writeMenuFile() throws { try registry.menuModel(settings: settings, paths: paths).write(to: paths.menuFile) }

    /// After a job: remember destinations, refresh state-dependent menu entries.
    func absorb(_ job: Job) {
        if let f = job.rememberFolder {
            var r = settings.recentFolders.filter { $0 != f.path }
            r.insert(f.path, at: 0)
            settings.recentFolders = Array(r.prefix(5))       // didSet → persist → menu rewritten
        } else if job.menuChanged {
            try? writeMenuFile()
        }
    }

    func persist() {
        do {
            try settings.save(paths)
            try writeMenuFile()
        } catch {
            log.error("persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshUndo() { lastUndoTitle = journal.last?.title }

    // MARK: Running

    func perform(_ request: ActionRequest) {
        switch request.actionID {
        case "app.open": performAppRequest(request) { openSettings() }; return
        case "app.undo": performAppRequest(request) { undoLast() }; return
        case "organize.batchRename" where request.options["rules"] == nil:
            performAppRequest(request) { RenameWindowController.open(request.urls, app: self) }; return
        default: break
        }
        guard let action = registry.action(request.actionID) else { performAppRequest(request) { NSSound.beep() }; return }
        let runner = ActionRunner(registry: registry, journal: journal, environment: AppEnvironment(), settings: settings, paths: paths)
        let reveal = settings.revealOutputs
        let job = JobCenter.shared.start(title: action.descriptor.title, actionID: request.actionID) { job, cancelled in
            await runner.run(request, progress: JobProgress(job: job), isCancelled: cancelled)
        }
        Task { @MainActor in
            await job.task?.value
            refreshUndo()
            absorb(job)
            ProgressPanel.shared.report(job)
            if !reveal, job.revealCreated, !job.created.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.created) }
            if reveal, !job.created.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.created) }
        }
    }

    /// These requests bypass ActionRunner, so they complete their own claim lifecycle.
    private func performAppRequest(_ request: ActionRequest, _ operation: () -> Void) {
        let inbox = RequestInbox(paths: paths)
        do {
            try inbox.markStarted(request)
            operation()
            if inbox.isClaimed(request.id) { try inbox.acknowledge(request.id) }
        } catch { log.error("request: \(error.localizedDescription, privacy: .public)") }
    }

    func undoLast() {
        guard let tx = journal.last else {
            ProgressPanel.shared.notice(Notice(title: "Nothing to undo", message: nil, kind: .info)); return
        }
        let r = journal.undo(tx)
        log.info("undo \(tx.title, privacy: .public): \(r.summary, privacy: .public)")
        let skipped = r.skipped.prefix(5).map { "\(URL(fileURLWithPath: $0.0).lastPathComponent): \($0.1)" }
        ProgressPanel.shared.notice(Notice(title: "Undo “\(tx.title)”",
                                           message: ([r.summary] + skipped).joined(separator: "\n"),
                                           kind: r.skipped.isEmpty ? .success : .error))
        refreshUndo()
    }

    @ObservationIgnored private var settingsWindow: NSWindow?
    var settingsTab = "general"

    /// Own window instead of the SwiftUI Settings scene: the legacy selector is gone on macOS 14+
    /// and openSettings needs a view in hierarchy (review #5). Works from Finder, URL and menu bar.
    func openSettings(tab: String? = nil) {
        if let tab { settingsTab = tab }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(self).environment(JobCenter.shared))
            let w = NSWindow(contentViewController: host)
            w.identifier = NSUserInterfaceItemIdentifier("clicksmith.user")   // keeps the app alive (AppDelegate.quitIfIdle)
            w.title = "Clicksmith Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
