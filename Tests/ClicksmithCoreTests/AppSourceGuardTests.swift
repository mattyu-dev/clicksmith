import Foundation
import Testing

/// Guards for app-target code that has no unit tests (the app target is not testable with SwiftPM here).
@Suite struct AppSourceGuardTests {
    static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Sources/ClicksmithApp").standardizedFileURL

    func source(_ name: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("T-0019 round 2 #1: no modal alert at launch (the woken app is not active; it would hide behind Finder)")
    func noModalAtLaunch() throws {
        let s = try source("AppDelegate.swift")
        let launch = s.components(separatedBy: "func applicationDidFinishLaunching").dropFirst().first ?? ""
        let body = launch.components(separatedBy: "\n    }\n").first ?? ""
        #expect(!body.contains("runModal"), "launch path must not block on a modal")
        #expect(body.contains("ProgressPanel.shared.notice"), "recovery is a persistent notice")
    }

    @Test("T-0019 round 2 #3: Settings never says Finder restarts") func settingsText() throws {
        let s = try source("SettingsView.swift")
        #expect(!s.contains("restarts Finder") && !s.contains("relaunches Finder"))
    }
}
