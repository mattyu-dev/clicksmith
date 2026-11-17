import Foundation

// MARK: - New File from template

public enum UserTemplates {
    /// Drop any file here; it shows up under New File. `~/Library/Application Support/Clicksmith/Templates`.
    public static func folder(_ p: SharedPaths) -> URL { p.root.appendingPathComponent("Templates", isDirectory: true) }

    public static func list(_ p: SharedPaths) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder(p), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

struct NewFileAction: PowerAction {
    let descriptor = ActionDescriptor(id: "create.newFile", title: "New File", symbol: "doc.badge.plus", group: .create,
                                      summary: "Create a file from a template in this folder.", contexts: [.container], minCount: 0)

    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu {
        let user = UserTemplates.list(env.paths).map { ActionVariant($0.lastPathComponent, symbol: "person.crop.square", options: ["user": $0.lastPathComponent]) }
        let built = TemplateLibrary.builtIn.filter { TemplateLibrary.inMenu.contains($0.id) }.map { ActionVariant($0.name, symbol: $0.symbol, options: ["template": $0.id]) }
        return .variants(user + built)
    }

    static func folder(_ c: ActionContext) -> URL {
        // Right-click on a folder → inside it. On a file → next to it. Background → that folder.
        if c.inputs.count == 1, let u = c.inputs.first, (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return u }
        return c.inputs.first?.deletingLastPathComponent() ?? c.targetDirectory
    }

    func run(_ c: ActionContext) async throws -> ActionResult {
        let dir = Self.folder(c)
        let out: URL
        if let name = c.options["user"] {
            // Only an entry that is really listed in the Templates folder (no "..", ".", "", hidden, paths).
            guard let src = UserTemplates.list(c.paths).first(where: { $0.lastPathComponent == name }),
                  !name.isEmpty, !name.hasPrefix("."), !name.contains("/"),
                  src.deletingLastPathComponent().standardizedFileURL == UserTemplates.folder(c.paths).standardizedFileURL else {
                throw PowerError.badInput("Template “\(name)” is not in the Templates folder.")
            }
            out = try c.files.copy(src, into: dir)
        } else {
            let id = c.option("template", default: "text")
            guard let t = TemplateLibrary.builtIn.first(where: { $0.id == id }) else { throw PowerError.badInput("Unknown template “\(id)”.") }
            let base = (t.ext.isEmpty || t.id == "readme") ? t.name : "Untitled"
            out = try c.files.produce(base: base, ext: t.ext, in: dir) { url in
                try t.contents.write(to: url)
                if t.isExecutable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
        }
        var r = ActionResult(created: [out], message: "Created \(out.lastPathComponent).")
        r.revealCreated = true
        return r
    }
}

// MARK: - New File from Clipboard

struct NewFileFromClipboardAction: PowerAction {
    let descriptor = ActionDescriptor(id: "create.fromClipboard", title: "New File from Clipboard", symbol: "doc.on.clipboard.fill", group: .create,
                                      summary: "Saves what you copied as the right file type: JSON, CSV, link, Markdown, code, image…",
                                      contexts: [.container], minCount: 0)

    static func content(_ s: ClipboardSnapshot) -> ClipboardContent? {
        if let png = s.png { return .image(png) }
        if !s.fileURLs.isEmpty { return .fileURLs(s.fileURLs) }
        if let t = s.string, !t.isEmpty { return .text(t) }
        if let h = s.html, !h.isEmpty { return .html(h) }
        if let r = s.rtf { return .rtf(r) }
        return nil
    }

    func run(_ c: ActionContext) async throws -> ActionResult {
        guard let content = Self.content(await c.environment.readClipboard()) else {
            throw PowerError.badInput("The clipboard is empty.")
        }
        let f = ClipboardDetector.detect(content)
        let out = try c.files.write(f.data, base: f.suggestedName, ext: f.ext, in: NewFileAction.folder(c))
        var r = ActionResult(created: [out], message: "Saved \(f.kind) as \(out.lastPathComponent).")
        r.revealCreated = true
        return r
    }
}
