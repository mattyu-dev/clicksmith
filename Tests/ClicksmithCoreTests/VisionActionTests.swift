import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct VisionActionTests {
    @Test func makeQRThenReadItBack() async throws {
        let d = try tempDir()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: "https://www.apple.com/mac/")
        var c = context([], env: env); c.targetDirectory = d
        let made = try await MakeQRFromClipboardAction().run(c)
        let png = try #require(made.created.first)
        #expect(png.lastPathComponent == "QR www.apple.com.png")
        let readEnv = FakeEnvironment()
        let r = try await ReadCodesAction().run(context([png], env: readEnv))
        #expect(readEnv.clipboard == "https://www.apple.com/mac/")
        #expect(r.message?.hasPrefix("Link") == true)
    }

    @Test func dangerousLinksAreFlagged() {
        let (_, s) = ReadCodesAction.describe(.url(URL(string: "http://192.168.0.1@evil.com/login")!))
        #expect(s.contains("⛔️"))
        let (copy, w) = ReadCodesAction.describe(.wifi(ssid: "Home", password: "secret", security: "WPA", hidden: false))
        #expect(copy == "secret" && w.contains("Home"))
    }

    @Test func noCodeIsAClearError() async throws {
        let d = try tempDir()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: "x")
        let blank = d.appendingPathComponent("blank.png")
        try CodeWriter.qrPNG("x", size: 64, output: blank)   // tiny real PNG…
        try Data(count: 0).write(to: d.appendingPathComponent("empty.txt"))
        // …then a PNG with no code: draw nothing by reusing ImageIO on a solid image is overkill; a 1-px PNG works.
        let onePixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let p = d.appendingPathComponent("pixel.png"); try onePixel.write(to: p)
        await #expect(throws: PowerError.self) { _ = try await ReadCodesAction().run(context([p])) }
    }
}

/// Codex review of T-0012 part 2a + menu design (2026-11-16).
@Suite struct VisionReviewTests {
    func roundTrip(_ text: String) async throws -> String {
        let d = try tempDir()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: text)
        var c = context([], env: env); c.targetDirectory = d
        let png = try #require(try await MakeQRFromClipboardAction().run(c).created.first)
        let readEnv = FakeEnvironment()
        _ = try await ReadCodesAction().run(context([png], env: readEnv))
        return try #require(readEnv.clipboard)
    }

    @Test("#2 mailto and SMS keep their full content") func fullPayload() async throws {
        #expect(try await roundTrip("mailto:a@example.com?subject=Hello&body=World") == "mailto:a@example.com?subject=Hello&body=World")
        #expect(try await roundTrip("SMSTO:123:Hello") == "SMSTO:123:Hello")
    }

    @Test("#3 QR keeps leading spaces and new lines") func whitespace() async throws {
        #expect(try await roundTrip("  indented\nline two\n") == "  indented\nline two\n")
    }

    @Test("#5 cancelled QR creation writes nothing") func cancelled() async throws {
        let d = try tempDir(); let ops = FileOps()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: "x")
        var c = context([], env: env, ops: ops, cancel: { true }); c.targetDirectory = d
        await #expect(throws: PowerError.self) { _ = try await MakeQRFromClipboardAction().run(c) }
        #expect(names(d).isEmpty && ops.recorded.isEmpty)
    }

    @Test("#4 without group submenus, New File stays one submenu") func ungrouped() throws {
        let p = SharedPaths(root: try tempDir("root"))
        var s = ClicksmithSettings(); s.groupSubmenus = false
        let items = ActionRegistry(BuiltInActions.all()).menuModel(settings: s, paths: p).items
        guard case let .submenu(title, _, kids)? = items.first else { Issue.record("first is not a submenu"); return }
        #expect(title == "New File" && "\(kids)".contains("Text File"))
        #expect(!items.contains { if case let .action(a) = $0 { a.title == "Text File" } else { false } })
    }

    @Test("one-choice variants become a direct item") func copyToDirect() throws {
        let p = SharedPaths(root: try tempDir("root"))
        var on = ClicksmithSettings(); on.shownActions = ["organize.copyTo", "organize.moveTo"]
        let menu = "\(ActionRegistry(BuiltInActions.all()).menuModel(settings: on, paths: p).items)"
        #expect(menu.contains("\"Copy To…\"") && menu.contains("\"Move To…\""))
    }
}
