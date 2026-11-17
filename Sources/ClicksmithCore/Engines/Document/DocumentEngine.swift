import AppKit
import CoreText

public enum DocFormat: String, Codable, Sendable, CaseIterable {
    case txt, rtf, rtfd, docx, odt, html, pdf, md, webarchive

    var documentType: NSAttributedString.DocumentType? {
        switch self {
        case .txt: .plain
        case .rtf: .rtf
        case .rtfd: .rtfd
        case .docx: .officeOpenXML
        case .odt: .openDocument
        case .html: .html
        case .webarchive: .webArchive
        case .pdf, .md: nil
        }
    }

    static func inputFormat(_ ext: String) -> DocFormat? {
        let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch normalized {
        case "markdown", "mdown": return .md
        case "htm": return .html
        case "text": return .txt
        default: return DocFormat(rawValue: normalized)
        }
    }
}

public enum DocumentEngine {
    /// PDF input supports text extraction. Markdown is an input format, not a lossy rich-text export.
    public static func supportedTargets(for inputExtension: String) -> [DocFormat] {
        guard let format = DocFormat.inputFormat(inputExtension) else { return [] }
        if format == .pdf { return [.txt] }
        return DocFormat.allCases.filter { $0 != .md && $0 != format }
    }

    public static func convert(_ input: URL, to format: DocFormat, output: URL,
                               progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        try DocumentIO.checked {
            try DocumentIO.requireFileURL(input)
            try DocumentIO.checkCancellation(isCancelled)
            guard supportedTargets(for: input.pathExtension).contains(format),
                  let sourceFormat = DocFormat.inputFormat(input.pathExtension) else {
                throw PowerError.unsupported("This document conversion is not supported.")
            }
            progress(0)
            try DocumentIO.single(output, isCancelled: isCancelled) { scratch in
                let text: NSAttributedString
                switch sourceFormat {
                case .pdf:
                    text = NSAttributedString(string: try PDFEngine.text(input, isCancelled: isCancelled))
                case .md:
                    let markdown = try readMarkdown(input)
                    let html = MarkdownRenderer.html(markdown, title: input.deletingPathExtension().lastPathComponent)
                    if format == .html {
                        try Data(html.utf8).write(to: scratch)
                        progress(1)
                        return
                    }
                    text = try HTMLAttributedReader.read(html, isCancelled: isCancelled)
                case .html:
                    text = try HTMLAttributedReader.read(readText(input), isCancelled: isCancelled)
                case .webarchive:
                    let archive = try PropertyListSerialization.propertyList(from: Data(contentsOf: input), format: nil)
                    guard let dict = archive as? [String: Any], let resource = dict["WebMainResource"] as? [String: Any],
                          let data = resource["WebResourceData"] as? Data,
                          let html = String(data: data, encoding: .utf8) else {
                        throw PowerError.badInput("The WebArchive has no UTF-8 HTML main resource.")
                    }
                    text = try HTMLAttributedReader.read(html, isCancelled: isCancelled)
                case .txt:
                    text = NSAttributedString(string: try readText(input), attributes: [.font: NSFont.systemFont(ofSize: 12)])
                case .rtfd:
                    let wrapper = try readWrapper(input, depth: 0, isCancelled: isCancelled)
                    guard let attributed = NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: nil) else {
                        throw PowerError.badInput("Could not read the RTFD package.")
                    }
                    text = attributed
                default:
                    guard let type = sourceFormat.documentType else { throw PowerError.unsupported("Unsupported document type.") }
                    text = try NSAttributedString(url: input, options: [.documentType: type], documentAttributes: nil)
                }
                try DocumentIO.checkCancellation(isCancelled)
                progress(0.4)
                let range = NSRange(location: 0, length: text.length)
                switch format {
                case .txt: try Data(text.string.utf8).write(to: scratch)
                case .pdf: try writePDF(text, to: scratch, progress: { progress(0.4 + 0.6 * $0) }, isCancelled: isCancelled)
                case .docx where sourceFormat == .md || sourceFormat == .html || sourceFormat == .webarchive:
                    try DOCXWriter.write(text, to: scratch, isCancelled: isCancelled)
                case .rtfd:
                    let wrapper = try text.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                    try wrapper.write(to: scratch, options: .atomic, originalContentsURL: nil)
                default:
                    guard let type = format.documentType else { throw PowerError.unsupported("Unsupported export format.") }
                    let data = try text.data(from: range, documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue])
                    try data.write(to: scratch)
                }
                progress(1)
            }
        }
    }

    private static func readText(_ url: URL) throws -> String {
        var encoding: UInt = 0
        return try NSString(contentsOf: url, usedEncoding: &encoding) as String
    }

    private static func readMarkdown(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        func text(_ encoding: String.Encoding) -> String? {
            guard var decoded = String(data: data, encoding: encoding), !decoded.unicodeScalars.contains(where: {
                let n = $0.value
                return (n < 32 && n != 9 && n != 10 && n != 13) || (0x7f...0x9f).contains(n)
            }) else { return nil }
            if decoded.first == "\u{feff}" { decoded.removeFirst() }
            return decoded
        }
        if let utf8 = text(.utf8) { return utf8 }
        // A BOM or zero-byte pattern distinguishes UTF-16 from legacy 8-bit text.
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            if let utf16 = text(.utf16) { return utf16 }
        } else if data.contains(0), data.count.isMultiple(of: 2) {
            let bytes = [UInt8](data.prefix(1024))
            let oddZeros = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let evenZeros = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            if let utf16 = text(oddZeros > evenZeros ? .utf16LittleEndian : .utf16BigEndian) { return utf16 }
        }
        if !data.contains(0), let latin1 = text(.isoLatin1) { return latin1 }
        throw PowerError.badInput("File is not text")
    }

    // FileWrapper(url:) asks LaunchServices for package types, which is unavailable
    // in a headless sandbox. Construct the wrapper from local entries instead.
    private static func readWrapper(_ url: URL, depth: Int, isCancelled: () -> Bool) throws -> FileWrapper {
        try DocumentIO.checkCancellation(isCancelled)
        guard depth < 32 else { throw PowerError.badInput("The RTFD package is nested too deeply.") }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw PowerError.badInput("Symbolic links inside RTFD packages are not supported.") }
        if values.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            var wrappers: [String: FileWrapper] = [:]
            for child in children { wrappers[child.lastPathComponent] = try readWrapper(child, depth: depth + 1, isCancelled: isCancelled) }
            return FileWrapper(directoryWithFileWrappers: wrappers)
        }
        guard values.isRegularFile == true else { throw PowerError.badInput("The RTFD package contains an unsupported file.") }
        return FileWrapper(regularFileWithContents: try Data(contentsOf: url))
    }

    /// A4 pagination with 36 pt margins. CoreText needs neither a view nor a print run loop.
    private static func writePDF(_ text: NSAttributedString, to output: URL, progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw PowerError.failed("Could not create the PDF.")
        }
        defer { context.closePDF() }
        let printable = NSMutableAttributedString(attributedString: text)
        if printable.length == 0 { printable.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 12)])) }
        let framesetter = CTFramesetterCreateWithAttributedString(printable as CFAttributedString)
        let path = CGPath(rect: mediaBox.insetBy(dx: 36, dy: 36), transform: nil)
        var offset = 0
        while offset < printable.length {
            try DocumentIO.checkCancellation(isCancelled)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw PowerError.failed("The document content does not fit on a PDF page.") }
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.endPDFPage()
            offset += visible.length
            progress(Double(offset) / Double(printable.length))
        }
    }
}
