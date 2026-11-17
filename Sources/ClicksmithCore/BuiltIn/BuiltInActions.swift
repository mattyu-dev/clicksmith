import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Every built-in action. Engines from other tasks register here when they land.
public enum BuiltInActions {
    public static func all() -> [any PowerAction] {
        [
            CopyPathAction(), CopyNameAction(), CopyShellPathAction(), CopyInfoAction(),
            ChecksumAction(), ZipAction(), UnzipAction(),
            NewFileAction(), NewFileFromClipboardAction(), BatchRenameAction(),
            ConvertVideoAction(), ConvertAudioAction(), CompressMediaAction(), MakeGIFAction(),
            ConvertImageAction(), ResizeImageAction(), MakeIconAction(), StripMetadataAction(),
            ConvertDocumentAction(), CompressPDFAction(), MergePDFsAction(), SplitPDFAction(), PDFToImagesAction(), ImagesToPDFAction(),
            ReadCodesAction(), MakeQRFromClipboardAction(), CopyTextFromImageAction(), RemoveBackgroundAction(),
            CopyToAction(), MoveToAction(), CutAction(), MoveHereAction(),
            OpenInEditorAction(), OpenTerminalAction(),
            UndoAction(), OpenAppAction(),
        ]
    }
}

// MARK: - Copy

struct CopyPathAction: PowerAction {
    let descriptor = ActionDescriptor(id: "copy.path", title: "Copy Path", symbol: "doc.on.clipboard", group: .copy,
                                      summary: "Full path of each item, one per line.", contexts: [.items, .container], minCount: 0)
    func run(_ c: ActionContext) async throws -> ActionResult {
        let items = c.inputs.isEmpty ? [c.targetDirectory] : c.inputs
        await c.environment.setClipboard(items.map(\.path).joined(separator: "\n"))
        return ActionResult(message: "Copied \(items.count) path\(items.count == 1 ? "" : "s").")
    }
}

struct CopyNameAction: PowerAction {
    let descriptor = ActionDescriptor(id: "copy.name", title: "Copy Name", symbol: "textformat", group: .copy)
    func run(_ c: ActionContext) async throws -> ActionResult {
        await c.environment.setClipboard(c.inputs.map(\.lastPathComponent).joined(separator: "\n"))
        return ActionResult(message: "Copied \(c.inputs.count) name\(c.inputs.count == 1 ? "" : "s").")
    }
}

struct CopyShellPathAction: PowerAction {
    let descriptor = ActionDescriptor(id: "copy.shellPath", title: "Copy Path for Terminal", symbol: "terminal", group: .copy,
                                      summary: "Paths quoted for the shell, space-separated.", contexts: [.items, .container], minCount: 0)
    func run(_ c: ActionContext) async throws -> ActionResult {
        let items = c.inputs.isEmpty ? [c.targetDirectory] : c.inputs
        await c.environment.setClipboard(items.map { ShellQuote.quote($0.path) }.joined(separator: " "))
        return ActionResult(message: "Copied for Terminal.")
    }
}

enum ShellQuote {
    static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./+,:@%")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct CopyInfoAction: PowerAction {
    let descriptor = ActionDescriptor(id: "copy.info", title: "Copy Info", symbol: "info.circle", group: .copy,
                                      summary: "Name, path, kind, size, dates, plus pixel size, duration or page count.")
    func run(_ c: ActionContext) async throws -> ActionResult {
        var blocks: [String] = []
        for url in c.inputs {
            try c.checkCancelled()
            blocks.append(await FileInfo.describe(url))
        }
        let text = blocks.joined(separator: "\n\n")
        await c.environment.setClipboard(text)
        return ActionResult(message: "Copied info for \(c.inputs.count) item\(c.inputs.count == 1 ? "" : "s").")
    }
}

enum FileInfo {
    static func describe(_ url: URL) async -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isDirectoryKey]
        let v = try? url.resourceValues(forKeys: keys)
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        var lines = ["Name: \(url.lastPathComponent)", "Path: \(url.path)"]
        if let k = v?.localizedTypeDescription { lines.append("Kind: \(k)") }
        if v?.isDirectory == true {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(directorySize(url)), countStyle: .file))")
        } else if let s = v?.fileSize {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)) (\(s) bytes)")
        }
        if let d = v?.creationDate { lines.append("Created: \(df.string(from: d))") }
        if let d = v?.contentModificationDate { lines.append("Modified: \(df.string(from: d))") }
        if v?.isDirectory != true { lines += await details(url) }
        return lines.joined(separator: "\n")
    }

    /// Type-specific lines: pixel size for images, page count for PDF, duration for audio and video.
    static func details(_ url: URL) async -> [String] {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return [] }
        if type.conforms(to: .pdf) {
            guard let doc = CGPDFDocument(url as CFURL) else { return [] }
            return ["Pages: \(doc.numberOfPages)"]
        }
        if type.conforms(to: .image) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return [] }
            return ["Dimensions: \(w) × \(h)"]
        }
        if type.conforms(to: .audiovisualContent) {
            let asset = AVURLAsset(url: url)
            var out: [String] = []
            if let tracks = try? await asset.loadTracks(withMediaType: .video), let t = tracks.first,
               let (size, transform) = try? await t.load(.naturalSize, .preferredTransform) {
                let r = size.applying(transform)
                out.append("Dimensions: \(Int(abs(r.width).rounded())) × \(Int(abs(r.height).rounded()))")
            }
            if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 {
                out.append("Duration: \(formatDuration(d.seconds))")
            }
            return out
        }
        return []
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let (h, m, sec) = (s / 3600, s % 3600 / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func directorySize(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0 }
        return total
    }
}

// MARK: - App

struct UndoAction: PowerAction {
    let descriptor = ActionDescriptor(id: "app.undo", title: "Undo Last Clicksmith Action", symbol: "arrow.uturn.backward", group: .app,
                                      contexts: [.container], minCount: 0)
    func run(_ c: ActionContext) async throws -> ActionResult {
        // The app owns the journal; it intercepts this id (see AppRuntime). CLI: `csx undo`.
        throw PowerError.unsupported("Undo runs in the Clicksmith app.")
    }
}

struct OpenAppAction: PowerAction {
    let descriptor = ActionDescriptor(id: "app.open", title: "Clicksmith Settings…", symbol: "gearshape", group: .app,
                                      contexts: [.items, .container], minCount: 0)
    func run(_ c: ActionContext) async throws -> ActionResult { .none }  // handled by the app
}
