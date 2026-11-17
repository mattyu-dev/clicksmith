import Foundation
import Testing
@testable import ClicksmithKit

@Suite struct MenuModelTests {
    let jpg = URL(fileURLWithPath: "/tmp/a.JPG")
    let png = URL(fileURLWithPath: "/tmp/b.png")
    let dir = URL(fileURLWithPath: "/tmp/folder/", isDirectory: true)

    @Test func extensionFilterIsCaseInsensitive() {
        let a = MenuAction(actionID: "x", title: "X", extensions: ["jpg", "png"])
        #expect(a.matches(context: .items, selection: [jpg, png]))
        #expect(!a.matches(context: .items, selection: [jpg, dir]))
    }

    @Test func folderMarker() {
        let a = MenuAction(actionID: "x", title: "X", extensions: ["/"])
        #expect(a.matches(context: .items, selection: [dir]))
        #expect(!a.matches(context: .items, selection: [jpg]))
    }

    @Test func countLimitsAndContexts() {
        let a = MenuAction(actionID: "x", title: "X", minCount: 2, maxCount: 3)
        #expect(!a.matches(context: .items, selection: [jpg]))
        #expect(a.matches(context: .items, selection: [jpg, png]))
        #expect(!a.matches(context: .items, selection: [jpg, png, dir, jpg]))
        #expect(!a.matches(context: .container, selection: []))
        let bg = MenuAction(actionID: "y", title: "Y", contexts: [.container], minCount: 0)
        #expect(bg.matches(context: .container, selection: []))
    }

    @Test func roundTripsThroughJSON() throws {
        let m = MenuModel(items: [.submenu(title: "Convert", symbol: "arrow.triangle.2.circlepath", children: [
            .action(MenuAction(actionID: "image.convert", title: "To JPEG", options: ["format": "jpeg"])), .separator]),
        ])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("menu.json")
        try m.write(to: f)
        let back = try MenuModel.load(from: f)
        #expect(back.items == m.items)
    }
}

@Suite struct InboxTests {
    func tempPaths() throws -> SharedPaths {
        let p = SharedPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)"))
        try p.ensureExists(); return p
    }

    @Test func submitTakeRoundTrip() throws {
        let inbox = RequestInbox(paths: try tempPaths())
        let r = ActionRequest(actionID: "copy.path", paths: ["/tmp/a b.txt"], source: .finder)
        try inbox.submit(r)
        #expect(ActionRequest.requestID(from: r.wakeURL()) == r.id)
        #expect(inbox.take(r.id) == r)
        #expect(inbox.take(r.id) == nil, "a request runs once")
    }

    @Test func drainSkipsStaleAndGarbage() throws {
        let p = try tempPaths(); let inbox = RequestInbox(paths: p)
        let now = Date()
        let expired = ActionRequest(actionID: "old", paths: [], created: now.addingTimeInterval(-3600), source: .finder)
        try inbox.submit(expired)
        try inbox.submit(ActionRequest(actionID: "b", paths: [], created: now.addingTimeInterval(-5), source: .finder))
        try inbox.submit(ActionRequest(actionID: "a", paths: [], created: now.addingTimeInterval(-10), source: .finder))
        try Data("junk".utf8).write(to: p.inbox.appendingPathComponent("junk.json"))
        let got = inbox.drain(now: now)
        #expect(got.map(\.actionID) == ["a", "b"])
        #expect(inbox.pending().isEmpty)
        for request in got { try inbox.markStarted(request); try inbox.acknowledge(request.id) }
        #expect(inbox.interrupted() == [expired.id])
        #expect(inbox.interrupted().isEmpty)
    }

    @Test func wrongSchemeIsIgnored() {
        #expect(ActionRequest.requestID(from: URL(string: "http://run/\(UUID().uuidString)")!) == nil)
    }
}

@Test func inboxPendingListsWithoutRemoving() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID().uuidString)")
    let inbox = RequestInbox(paths: SharedPaths(root: root))
    let r = ActionRequest(actionID: "x", paths: [], targetDirectory: nil, options: [:], source: .finder)
    _ = try inbox.submit(r)
    #expect(inbox.pending() == [r.id])
    #expect(inbox.pending() == [r.id], "pending does not consume")
    #expect(inbox.take(r.id) != nil && inbox.pending().isEmpty)
}
