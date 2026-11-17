import Testing
import Foundation
@testable import ClicksmithCore
import ClicksmithKit

/// The menu shows only what fits the clicked item.
@Suite struct ContextMenuTests {
    func titles(_ ctx: MenuContext, _ ext: String?, count: Int) throws -> [String] {
        let d = try tempDir("sel")
        let p = SharedPaths(root: try tempDir("root"))
        var sel: [URL] = []
        if ext == "/" { let f = d.appendingPathComponent("Folder", isDirectory: true); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true); sel = [f] }
        else if let ext { sel = (0..<count).map { d.appendingPathComponent("f\($0).\(ext)") }; sel.forEach { FileManager.default.createFile(atPath: $0.path, contents: Data()) } }
        let menu = ActionRegistry(BuiltInActions.all()).menuModel(settings: .init(), paths: p)
        func walk(_ items: [MenuNode]) -> [String] {
            items.flatMap { node -> [String] in
                switch node {
                case .action(let a): return a.matches(context: ctx, selection: sel) ? [a.title] : []
                case .submenu(let t, _, let ch): let c = walk(ch); return c.isEmpty ? [] : [t + " ▸"] + c.map { "  " + $0 }
                default: return []
                }
            }
        }
        return walk(menu.items)
    }

    @Test func photoShowsOnlyImageItems() throws {
        let t = try titles(.items, "jpg", count: 1)
        #expect(t.contains("Convert Image ▸") && t.contains("Remove Background") && t.contains("Copy Path"))
        for no in ["New File ▸", "Open in Terminal", "Open in Editor", "Zip (No Junk Files)", "Undo Last Clicksmith Action", "Copy To…", "Clicksmith Settings…"] {
            #expect(!t.contains(no), "\(no)")
        }
        #expect(!t.contains { $0.hasSuffix("▸") && ["Image ▸", "Copy ▸", "Organize ▸"].contains($0) }, "flat, no group submenus")
    }

    @Test func backgroundIsShort() throws {
        let t = try titles(.container, nil, count: 0)
        #expect(t.contains("New File ▸") && t.contains("Undo Last Clicksmith Action"))
        #expect(t.filter { $0.hasPrefix("  ") }.count <= 4)   // 4 templates (no own templates in a fresh root)
    }

    @Test func folderGetsTerminalAndEditor() throws {
        let t = try titles(.items, "/", count: 1)
        #expect(t.contains("Open in Terminal") && !t.contains("New File ▸"))
    }

    @Test func oldSavedGroupingIsIgnored() throws {
        let old = #"{"groupSubmenus": true}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(ClicksmithSettings.self, from: old).groupSubmenus == false)
    }

    @Test func editorForFilesWithoutExtension() throws {
        for n in ["Makefile", "Dockerfile", ".env", ".gitignore"] {
            #expect(URL(fileURLWithPath: "/x/\(n)").pathExtension == "")
        }
        #expect(OpenInEditorAction.codeExtensions.contains(""))
        let d = try tempDir("mix"); let a = d.appendingPathComponent("Makefile"), b = d.appendingPathComponent("main.swift")
        for u in [a, b] { FileManager.default.createFile(atPath: u.path, contents: Data()) }
        let m = ActionRegistry(BuiltInActions.all()).menuModel(settings: .init(), paths: SharedPaths(root: try tempDir("r")))
        #expect("\(m.items)".contains("open.editor"))
        func find(_ n: [MenuNode]) -> MenuAction? { for x in n { switch x { case .action(let a) where a.actionID == "open.editor": return a; case .submenu(_, _, let c): if let f = find(c) { return f }; default: break } }; return nil }
        #expect(find(m.items)?.matches(context: .items, selection: [a, b]) == true)
    }
}
