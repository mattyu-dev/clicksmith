import AppKit
import UserNotifications
import ClicksmithCore
import os

private let log = Logger(subsystem: "dev.clicksmith", category: "dispatch")

/// Real side effects for actions, on the main actor.
struct AppEnvironment: ActionEnvironment {
    func setClipboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func readClipboard() async -> ClipboardSnapshot {
        await MainActor.run {
            let pb = NSPasteboard.general
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            var png = pb.data(forType: .png)
            if png == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) { png = rep.representation(using: .png, properties: [:]) }
            return ClipboardSnapshot(string: pb.string(forType: .string), png: png, rtf: pb.data(forType: .rtf),
                                     html: pb.string(forType: .html), fileURLs: urls)
        }
    }
    func reveal(_ urls: [URL]) async { await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) } }
    func open(_ urls: [URL], withApplicationAt app: URL?) async throws {
        let config = NSWorkspace.OpenConfiguration()
        if let app {
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config)
        } else {
            for u in urls { _ = await MainActor.run { NSWorkspace.shared.open(u) } }
        }
    }
    func chooseFolder(prompt: String) async -> URL? {
        await MainActor.run {
            NSApp.activate()
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false; panel.message = prompt; panel.prompt = "Choose"
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
    func notify(title: String, body: String) async {
        log.info("notify \(title, privacy: .public): \(body, privacy: .private)")   // body may hold QR payloads
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

