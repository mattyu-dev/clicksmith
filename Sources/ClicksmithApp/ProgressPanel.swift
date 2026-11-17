import AppKit
import SwiftUI
import ClicksmithCore

/// Small floating panel, top-right, shown only while a job runs longer than a moment.
/// Replaces the menu bar icon: progress, cancel, and errors.
@MainActor
final class ProgressPanel {
    static let shared = ProgressPanel()
    private var panel: NSPanel?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { ProgressPanel.shared.tick() }
        }
    }

    /// After a job: errors stay until closed; success shows briefly (fast actions get feedback too).
    func report(_ job: Job) {
        switch job.state {
        case .failed(let why):
            NSSound.beep()
            let lines = job.failures.prefix(6).map { f in (f.url?.lastPathComponent).map { "\($0): \(f.message)" } ?? f.message }
            let extra = job.failures.count > 6 ? ["…and \(job.failures.count - 6) more"] : []
            notice(Notice(title: "\(job.title) failed", message: ([why].filter { !$0.isEmpty } + lines + extra).joined(separator: "\n"), kind: .error))
        case .succeeded:
            if !job.failures.isEmpty {
                let lines = job.failures.prefix(6).map { f in (f.url?.lastPathComponent).map { "\($0): \(f.message)" } ?? f.message }
                notice(Notice(title: "\(job.title): some files failed", message: lines.joined(separator: "\n"), kind: .error))
            } else {
                let msg = job.message ?? (job.created.isEmpty ? nil : "Created \(job.created.count) file\(job.created.count == 1 ? "" : "s").")
                notice(Notice(title: job.title, message: msg, kind: .success, files: job.created))
            }
        case .cancelled: notice(Notice(title: "\(job.title) cancelled", message: nil, kind: .info))
        case .running: break
        }
    }

    func notice(_ n: Notice) {
        JobCenter.shared.notices.append(n)
        if n.kind != .error {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { JobCenter.shared.notices.removeAll { $0.id == n.id } }
        }
        tick()
    }

    var isShowing: Bool { panel?.isVisible == true }

    private func tick() {
        let slow = JobCenter.shared.running.filter { Date().timeIntervalSince($0.started) > 0.7 }
        if slow.isEmpty && JobCenter.shared.notices.isEmpty { panel?.orderOut(nil); return }
        show()
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
            p.title = "Clicksmith"
            p.titlebarAppearsTransparent = true
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: ProgressList().environment(JobCenter.shared))
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated { JobCenter.shared.notices.removeAll() }
            }
            panel = p
        }
        guard let p = panel else { return }
        if let size = p.contentView?.fittingSize { p.setContentSize(size) }
        if !p.isVisible, let screen = NSScreen.main?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - p.frame.width - 16, y: screen.maxY - 16))
        }
        p.orderFrontRegardless()
    }
}

struct ProgressList: View {
    @Environment(JobCenter.self) var jobs
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(jobs.running) { JobRow(job: $0) }
            ForEach(jobs.notices) { NoticeRow(notice: $0) }
        }
        .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 14)
        .frame(width: 320, alignment: .leading)
    }
}

struct Notice: Identifiable {
    enum Kind { case success, error, info }
    let id = UUID()
    let title: String
    let message: String?
    let kind: Kind
    var files: [URL] = []
}

struct NoticeRow: View {
    let notice: Notice
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.kind == .success ? .green : notice.kind == .error ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.callout.weight(.medium)).lineLimit(1)
                if let m = notice.message, !m.isEmpty {
                    Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(notice.kind == .error ? 8 : 3).textSelection(.enabled)
                }
            }
            Spacer(minLength: 4)
            if !notice.files.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(notice.files) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
            if notice.kind == .error {
                Button { JobCenter.shared.notices.removeAll { $0.id == notice.id } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Close")
            }
        }
    }
}
