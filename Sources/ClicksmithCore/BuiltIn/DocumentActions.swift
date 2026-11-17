import Foundation

/// Finder menu entries for the document + PDF engines (T-0009). All work is local.
enum DocExts {
    static let docInputs: Set<String> = ["txt", "text", "rtf", "docx", "odt", "html", "htm", "md", "markdown", "mdown", "webarchive"]
    static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif"]
    static let targets: [(DocFormat, String)] = [
        (.pdf, "PDF"), (.docx, "Word (.docx)"), (.rtf, "Rich Text (.rtf)"), (.txt, "Plain Text (.txt)"),
        (.html, "Web Page (.html)"), (.odt, "OpenDocument (.odt)"),
    ]
    /// Files that can become `target` (not the same format; PDF only to text).
    static func inputs(for target: DocFormat) -> Set<String> {
        var s = docInputs.filter { DocumentEngine.supportedTargets(for: $0).contains(target) }
        if target == .txt { s.insert("pdf") }
        return s
    }
}

/// Run an engine that writes into a folder; the finished folder is placed next to the input (journaled, undoable).
private func folderOutput(_ c: ActionContext, base: String, in dir: URL, _ work: (URL) throws -> Void) throws -> URL {
    try c.files.produce(base: base, ext: "", in: dir) { scratch in
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        try work(scratch)
    }
}

private func sizeText(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

struct ConvertDocumentAction: PerFileAction {
    let descriptor = ActionDescriptor(
        id: "doc.convert", title: "Convert Document", symbol: "doc.text", group: .document,
        summary: "Word, PDF, Rich Text, Markdown, HTML, OpenDocument and plain text, on this Mac.",
        extensions: DocExts.docInputs.union(["pdf"]),
        variants: DocExts.targets.map { ActionVariant($0.1, options: ["to": $0.0.rawValue], extensions: DocExts.inputs(for: $0.0)) },
        isLongRunning: true)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let to = DocFormat(rawValue: c.options["to"] ?? "") else { throw PowerError.badInput("Choose a document format.") }
        try c.checkCancelled()
        return [try c.files.produce(from: url, ext: to.rawValue) { try DocumentEngine.convert(url, to: to, output: $0, isCancelled: c.isCancelled) }]
    }
}

struct PDFToImagesAction: PerFileAction {
    let descriptor = ActionDescriptor(
        id: "pdf.toImages", title: "PDF to Images", symbol: "photo.on.rectangle", group: .document,
        summary: "One image per page (150 dpi), in a new folder.", extensions: ["pdf"],
        variants: [ActionVariant("PNG", options: ["format": "png"]), ActionVariant("JPEG", options: ["format": "jpeg"])],
        isLongRunning: true)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        let kind = ImageKind(rawValue: c.options["format"] ?? "png") ?? .png
        return [try folderOutput(c, base: OutputNamer.base(for: url, suffix: "pages"), in: url.deletingLastPathComponent()) {
            _ = try PDFEngine.pagesToImages(url, format: kind, outputDirectory: $0, isCancelled: c.isCancelled)
        }]
    }
}

struct SplitPDFAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "pdf.split", title: "Split PDF into Pages", symbol: "doc.on.doc", group: .document,
                                      summary: "One PDF per page, in a new folder.", extensions: ["pdf"], isLongRunning: true)
    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        [try folderOutput(c, base: OutputNamer.base(for: url, suffix: "split"), in: url.deletingLastPathComponent()) {
            _ = try PDFEngine.split(url, outputDirectory: $0, isCancelled: c.isCancelled)
        }]
    }
}

struct CompressPDFAction: PowerAction {
    let descriptor = ActionDescriptor(
        id: "pdf.compress", title: "Compress PDF", symbol: "arrow.down.right.and.arrow.up.left", group: .document,
        summary: "Smaller PDF for email. Pictures get smaller; text stays sharp.", extensions: ["pdf"],
        variants: [ActionVariant("Smallest", options: ["quality": "low"]), ActionVariant("Balanced", options: ["quality": "medium"]),
                   ActionVariant("Best Quality", options: ["quality": "high"])],
        isLongRunning: true)

    func run(_ c: ActionContext) async throws -> ActionResult {
        guard let q = PDFCompressionQuality(rawValue: c.options["quality"] ?? "") else { throw PowerError.badInput("Choose a quality.") }
        var created: [URL] = [], lines: [String] = [], failures: [ActionResult.Failure] = []
        var cancelled = false
        for (i, url) in c.inputs.enumerated() {
            if c.isCancelled() || Task.isCancelled { cancelled = true; break }
            await c.progress.update(done: i, total: c.inputs.count, current: url.lastPathComponent)
            do {
                var sizes: (before: Int64, after: Int64) = (0, 0)
                let out = try c.files.produce(from: url, ext: "pdf", suffix: "compressed") {
                    sizes = try PDFEngine.compress(url, quality: q, output: $0, isCancelled: c.isCancelled)
                }
                created.append(out)
                lines.append("\(url.lastPathComponent): \(sizeText(sizes.before)) → \(sizeText(sizes.after))")
            } catch PowerError.cancelled { cancelled = true; break }
            catch { failures.append(.init(url: url, message: error.localizedDescription)) }
        }
        // Keep what was already made (it is journaled) even when cancelled.
        var r = ActionResult(created: created, message: lines.joined(separator: "\n"), failures: failures)
        r.cancelled = cancelled
        return r
    }
}

struct MergePDFsAction: PowerAction {
    let descriptor = ActionDescriptor(id: "pdf.merge", title: "Merge PDFs", symbol: "rectangle.stack.badge.plus", group: .document,
                                      summary: "Joins the selected PDFs into one, in name order.", extensions: ["pdf"], minCount: 2, isLongRunning: true)
    func run(_ c: ActionContext) async throws -> ActionResult {
        let files = c.inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let dir = files[0].deletingLastPathComponent()
        let out = try c.files.produce(base: "Merged", ext: "pdf", in: dir) { try PDFEngine.merge(files, output: $0, isCancelled: c.isCancelled) }
        return ActionResult(created: [out], message: "Merged \(files.count) PDFs.")
    }
}

struct ImagesToPDFAction: PowerAction {
    let descriptor = ActionDescriptor(id: "pdf.fromImages", title: "Make PDF from Images", symbol: "doc.richtext", group: .document,
                                      summary: "One page per image, in name order.", extensions: DocExts.images,
                                      variants: [ActionVariant("Fit to Image", options: ["page": "fit"]), ActionVariant("A4", options: ["page": "a4"]),
                                                 ActionVariant("US Letter", options: ["page": "letter"])],
                                      isLongRunning: true)
    func run(_ c: ActionContext) async throws -> ActionResult {
        let files = c.inputs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let size = PDFPageSize(rawValue: c.options["page"] ?? "fit") ?? .fit
        let base = files.count == 1 ? OutputNamer.base(for: files[0]) : "Images"
        let out = try c.files.produce(base: base, ext: "pdf", in: files[0].deletingLastPathComponent()) {
            try PDFEngine.imagesToPDF(files, output: $0, pageSize: size, isCancelled: c.isCancelled)
        }
        return ActionResult(created: [out], message: "Made a PDF with \(files.count) pages.")
    }
}
