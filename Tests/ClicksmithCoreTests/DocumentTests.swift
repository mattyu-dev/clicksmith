import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import Testing
@testable import ClicksmithCore

// Native text/PDF backends share process resources. Keep these tests and the
// large review benchmarks in one serialized group, including across files.
@Suite(.serialized) struct DocumentEngineTests {}

extension DocumentEngineTests {
@Suite struct DocumentTests {
    @Test func advertisedTargetsExcludeUnknownAndLossyMarkdownExport() {
        #expect(DocumentEngine.supportedTargets(for: "exe").isEmpty)
        #expect(DocumentEngine.supportedTargets(for: ".TXT").contains(.docx))
        #expect(!DocumentEngine.supportedTargets(for: "rtf").contains(.md))
        #expect(!DocumentEngine.supportedTargets(for: "md").contains(.md))
        #expect(DocumentEngine.supportedTargets(for: "pdf") == [.txt])
    }

    @Test func textRoundTripsThroughNativeFormats() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try touch(dir, "source.txt", "Hello café 世界\nSecond line\n")
        let original = try Data(contentsOf: input)
        for format: DocFormat in [.rtf, .rtfd, .docx, .odt, .html, .webarchive] {
            let output = dir.appendingPathComponent("converted.\(format.rawValue)")
            try DocumentEngine.convert(input, to: format, output: output)
            let back = dir.appendingPathComponent("\(format.rawValue).txt")
            try DocumentEngine.convert(output, to: .txt, output: back)
            let text = try String(contentsOf: back, encoding: .utf8)
            #expect(text.contains("Hello café 世界"), "\(format)")
            #expect(text.contains("Second line"), "\(format)")
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func markdownProducesRichDOCXAndPaginatedPDF() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try touch(dir, "source.md", """
        # Heading

        - First item
        - Second item

        | Name | Value |
        | --- | --- |
        | Table cell | 42 |

        ```swift
        let answer = 42
        ```

        [Example](https://example.com)
        """)
        let docx = dir.appendingPathComponent("out.docx")
        try DocumentEngine.convert(input, to: .docx, output: docx)
        let attributed = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        for text in ["Heading", "First item", "Table cell", "let answer = 42", "Example"] {
            #expect(attributed.string.contains(text))
        }
        let heading = (attributed.string as NSString).range(of: "Heading")
        let font = try #require(attributed.attribute(.font, at: heading.location, effectiveRange: nil) as? NSFont)
        #expect(font.pointSize > 16)
        // AppKit's DOCX importer drops hyperlink attributes, so inspect the actual package.
        let documentXML = try documentZIPPart(docx, "word/document.xml")
        let relationships = try documentZIPPart(docx, "word/_rels/document.xml.rels")
        #expect(documentXML.contains("<w:hyperlink r:id="))
        #expect(relationships.contains("Target=\"https://example.com\""))
        let code = (attributed.string as NSString).range(of: "let answer")
        let codeFont = try #require(attributed.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        let cell = (attributed.string as NSString).range(of: "Table cell")
        let paragraph = try #require(attributed.attribute(.paragraphStyle, at: cell.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(!paragraph.textBlocks.isEmpty)

        let html = dir.appendingPathComponent("out.html")
        try DocumentEngine.convert(input, to: .html, output: html)
        #expect(try String(contentsOf: html, encoding: .utf8).contains("<table>"))
        let pdf = dir.appendingPathComponent("out.pdf")
        try DocumentEngine.convert(input, to: .pdf, output: pdf)
        #expect(try PDFEngine.info(pdf).pages >= 1)
        #expect(try PDFEngine.text(pdf).contains("Heading"))

        let long = try touch(dir, "long.txt", (1...180).map { "Line \($0) with readable text" }.joined(separator: "\n"))
        let longPDF = dir.appendingPathComponent("long.pdf")
        try DocumentEngine.convert(long, to: .pdf, output: longPDF)
        #expect(try PDFEngine.info(longPDF).pages > 1)
        #expect(try PDFEngine.text(longPDF).contains("Line 180"))
    }

    @Test func conversionRejectsOverwriteUnsupportedAndCancellation() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try touch(dir, "source.txt", "Keep me")
        #expect(throws: PowerError.self) { try DocumentEngine.convert(input, to: .rtf, output: input) }
        #expect(try String(contentsOf: input, encoding: .utf8) == "Keep me")
        let output = dir.appendingPathComponent("out.rtf")
        #expect(throws: PowerError.cancelled) {
            try DocumentEngine.convert(input, to: .rtf, output: output, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: PowerError.self) { try DocumentEngine.convert(input, to: .md, output: output) }
        let bad = try touch(dir, "bad.docx", "not a zip")
        #expect(throws: PowerError.self) { try DocumentEngine.convert(bad, to: .txt, output: output) }
    }

    @Test func conversionFitsFileOpsJournalAndRejectsDanglingSymlink() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try touch(dir, "source.md", "# Journaled document")
        let ops = FileOps()
        let output = try ops.produce(from: input, ext: "pdf") { scratch in
            try DocumentEngine.convert(input, to: .pdf, output: scratch)
        }
        #expect(output.lastPathComponent == "source.pdf")
        #expect(ops.recorded.count == 1)
        #expect(ops.recorded.first?.kind == .created)
        #expect(ops.recorded.first?.to == output.path)
        #expect(try PDFEngine.text(output).contains("Journaled document"))
        let link = dir.appendingPathComponent("occupied.pdf")
        let target = dir.appendingPathComponent("must-not-exist.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: PowerError.self) { try DocumentEngine.convert(input, to: .pdf, output: link) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    }

    @Test func markdownDOCXRetainsEditableLists() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try touch(dir, "lists.md", "3. Third item\n4. Fourth item\n\n- Outer\n  - Inner\n\n- Last\n\n  Continuation paragraph\n")
        let output = dir.appendingPathComponent("lists.docx")
        try DocumentEngine.convert(input, to: .docx, output: output)
        let xml = try documentZIPPart(output, "word/document.xml")
        let numbering = try documentZIPPart(output, "word/numbering.xml")
        #expect(xml.contains("<w:numPr>"))
        #expect(xml.contains("<w:ilvl w:val=\"1\"/>"))
        #expect(numbering.contains("<w:numFmt w:val=\"decimal\"/>"))
        #expect(numbering.contains("<w:startOverride w:val=\"3\"/>"))
        let back = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(back.string.contains("Third item"))
        #expect(back.string.contains("Inner"))
        #expect(back.string.contains("Continuation paragraph"))
        let offset = (back.string as NSString).range(of: "Third item").location
        let paragraph = try #require(back.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
        #expect(!paragraph.textLists.isEmpty)
    }
}

@Suite struct DocumentMarkdownTests {
    @Test func commonMarkAndGFMProduceStandaloneHTML() {
        let html = MarkdownRenderer.html("""
        # Title

        > Quote with **bold** and *italic*.

        - [x] finished
        - [ ] pending

        | A | B |
        | :- | -: |
        | one | two |

        ```swift
        print("<hello>")
        ```

        ~~deleted~~ https://example.com

        [named][ref]

        [ref]: https://example.org "Reference"
        """, title: "A <title>")
        for tag in ["<h1>Title</h1>", "<blockquote>", "<strong>bold</strong>", "<em>italic</em>", "type=\"checkbox\"", "checked", "<table>", "language-swift", "&lt;hello&gt;", "<del>deleted</del>", "href=\"https://example.com\"", "href=\"https://example.org\""] {
            #expect(html.contains(tag), "Missing \(tag)")
        }
        #expect(html.contains("<title>A &lt;title&gt;</title>"))
        #expect(html.contains("prefers-color-scheme: dark"))
    }

    @Test func rendererDoesNotExecuteRawHTMLOrUnsafeLinks() {
        let html = MarkdownRenderer.html("<script>alert(1)</script>\n\n[x](javascript:alert)\n\n`<script>`", title: nil)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(html.contains("<code>&lt;script&gt;</code>"))
    }
}

@Suite struct DocumentPDFTests {
    @Test func extractsTextAndInfoFromGeneratedPDF() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try documentFixture(dir, "source.pdf", pages: 2)
        let info = try PDFEngine.info(pdf)
        #expect(info.pages == 2)
        #expect(info.title == "Fixture title")
        #expect(!info.encrypted)
        #expect(try PDFEngine.text(pdf).contains("Page 2"))
        let txt = dir.appendingPathComponent("extract.txt")
        try DocumentEngine.convert(pdf, to: .txt, output: txt)
        #expect(try String(contentsOf: txt, encoding: .utf8).contains("Page 1"))
    }

    @Test func rasterizesEveryPageAtRequestedDPI() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try documentFixture(dir, "source.pdf", pages: 2)
        for format: ImageKind in [.png, .jpeg] {
            let out = dir.appendingPathComponent(format.rawValue)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
            var progress: [Double] = []
            let urls = try PDFEngine.pagesToImages(pdf, format: format, dpi: 144, outputDirectory: out, progress: { progress.append($0) })
            #expect(urls.map(\.lastPathComponent) == ["page-001.\(format.rawValue)", "page-002.\(format.rawValue)"])
            let source = try #require(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 400)
            #expect(image.height == 600)
            #expect(progress.last == 1)
        }
    }

    @Test func splitAndMergePreserveOrderAndNestedOutlines() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = try documentFixture(dir, "first.pdf", pages: 2, bookmark: true)
        let second = try documentFixture(dir, "second.pdf", pages: 1)
        let merged = dir.appendingPathComponent("merged.pdf")
        try PDFEngine.merge([first, second], output: merged)
        let document = try #require(PDFDocument(url: merged))
        #expect(document.pageCount == 3)
        let root = try #require(document.outlineRoot)
        #expect(root.numberOfChildren == 2)
        let source = try #require(root.child(at: 0))
        #expect(source.label == "first")
        let child = try #require(source.child(at: 0))
        #expect(child.label == "Chapter two")
        let page = try #require(child.destination?.page)
        #expect(document.index(for: page) == 1)
        let out = dir.appendingPathComponent("split")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        let split = try PDFEngine.split(merged, outputDirectory: out)
        #expect(split.map(\.lastPathComponent) == ["page-001.pdf", "page-002.pdf", "page-003.pdf"])
        #expect(try PDFEngine.text(split[1]).contains("Page 2"))
        #expect(try PDFEngine.info(split[2]).pages == 1)
    }

    @Test func imagePDFUsesRequestedPaperAndKeepsAspectRatio() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = try documentImageFixture(dir)
        for size: PDFPageSize in [.fit, .a4, .letter] {
            let out = dir.appendingPathComponent("\(size.rawValue).pdf")
            try PDFEngine.imagesToPDF([image, image], output: out, pageSize: size)
            let doc = try #require(PDFDocument(url: out))
            #expect(doc.pageCount == 2)
            let page = try #require(doc.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            switch size {
            case .fit: #expect(bounds.width == 80 && bounds.height == 40)
            case .a4: #expect(abs(bounds.width - 595.28) < 0.1 && abs(bounds.height - 841.89) < 0.1)
            case .letter: #expect(bounds.width == 612 && bounds.height == 792)
            }
        }
    }

    @Test func compressionNeverGrowsAndPreservesText() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try documentFixture(dir, "input.pdf", pages: 2)
        let original = try Data(contentsOf: input)
        for quality in PDFCompressionQuality.allCases {
            let out = dir.appendingPathComponent("\(quality.rawValue).pdf")
            let sizes = try PDFEngine.compress(input, quality: quality, output: out)
            #expect(sizes.before == Int64(original.count))
            #expect(sizes.after <= sizes.before)
            #expect(try PDFEngine.text(out).contains("Page 2"))
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func cancellationDuringBatchRemovesAllOutputs() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try documentFixture(dir, "input.pdf", pages: 3)
        let out = dir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        var stop = false
        #expect(throws: PowerError.cancelled) {
            try PDFEngine.pagesToImages(input, format: .png, outputDirectory: out, progress: { if $0 > 0 { stop = true } }, isCancelled: { stop })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        let merged = dir.appendingPathComponent("merged.pdf")
        #expect(throws: PowerError.cancelled) {
            try PDFEngine.merge([input], output: merged, isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: merged.path))
    }

    @Test func cancellationAtProgressBoundariesDoesNotPublish() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try documentFixture(dir, "source.pdf", pages: 3)
        let image = try documentImageFixture(dir)
        let text = try touch(dir, "source.txt", "Some text")
        let pages = dir.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: false)
        var cancelled = false
        let progress: (Double) -> Void = { if $0 > 0 { cancelled = true } }
        let cancel = { cancelled }
        let output = dir.appendingPathComponent("out.pdf")
        #expect(throws: PowerError.cancelled) { try PDFEngine.split(pdf, outputDirectory: pages, progress: progress, isCancelled: cancel) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: pages.path).isEmpty)
        cancelled = false
        #expect(throws: PowerError.cancelled) { try PDFEngine.merge([pdf], output: output, progress: progress, isCancelled: cancel) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        cancelled = false
        #expect(throws: PowerError.cancelled) { try PDFEngine.imagesToPDF([image, image], output: output, progress: progress, isCancelled: cancel) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        cancelled = false
        #expect(throws: PowerError.cancelled) { try PDFEngine.compress(pdf, quality: .low, output: output, progress: progress, isCancelled: cancel) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        cancelled = false
        #expect(throws: PowerError.cancelled) { try DocumentEngine.convert(text, to: .pdf, output: output, progress: progress, isCancelled: cancel) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        cancelled = false
        #expect(throws: PowerError.cancelled) { try PDFEngine.text(pdf, progress: progress, isCancelled: cancel) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".clicksmith-document-") })
    }

    @Test func compressionDownsamplesImageContent() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("image-heavy.pdf")
        let width = 1200, height = 1200
        var state: UInt32 = 7
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for index in bytes.indices { state = state &* 1_664_525 &+ 1_013_904_223; bytes[index] = UInt8(truncatingIfNeeded: state >> 24) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try #require(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.draw(image, in: box); context.endPDFPage(); context.closePDF()
        let out = dir.appendingPathComponent("compressed.pdf")
        let sizes = try PDFEngine.compress(pdf, quality: .low, output: out)
        #expect(sizes.after < sizes.before / 2)
        #expect(try PDFEngine.info(out).pages == 1)
        // CGPDF reads the output image dictionary independently of the compressor.
        let document = try #require(CGPDFDocument(out as CFURL))
        let page = try #require(document.page(at: 1))
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        let pageDictionary = try #require(page.dictionary)
        #expect(CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources))
        let resourceDictionary = try #require(resources)
        #expect(CGPDFDictionaryGetDictionary(resourceDictionary, "XObject", &objects))
        let objectDictionary = try #require(objects)
        var dimensions: [Int] = []
        withUnsafeMutablePointer(to: &dimensions) { values in
            CGPDFDictionaryApplyFunction(objectDictionary, { _, object, info in
                guard let info else { return }
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) {
                    var width = 0
                    if CGPDFDictionaryGetInteger(dictionary, "Width", &width) {
                        info.assumingMemoryBound(to: [Int].self).pointee.append(width)
                    }
                }
            }, values)
        }
        #expect(!dimensions.isEmpty)
        #expect(dimensions.allSatisfy { $0 < 1200 })
    }

    @Test func rejectsInvalidInputsAndOccupiedDestinations() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try documentFixture(dir, "input.pdf", pages: 1)
        let bad = try touch(dir, "bad.pdf", "broken")
        #expect(throws: PowerError.self) { try PDFEngine.info(bad) }
        #expect(throws: PowerError.self) { try PDFEngine.merge([], output: bad) }
        #expect(throws: PowerError.self) { try PDFEngine.merge([input], output: input) }
        #expect(throws: PowerError.self) { try PDFEngine.imagesToPDF([], output: bad) }
        #expect(throws: PowerError.self) { try PDFEngine.pagesToImages(input, format: .png, dpi: 0, outputDirectory: dir) }
        #expect(throws: PowerError.self) { try PDFEngine.split(input, outputDirectory: dir) }
        #expect(try String(contentsOf: bad, encoding: .utf8) == "broken")
    }

    @Test func lockedPDFReportsEncryptionAndRejectsExtraction() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("locked.pdf")
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box,
                                             [kCGPDFContextOwnerPassword: "owner", kCGPDFContextUserPassword: "reader"] as CFDictionary))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        #expect(try PDFEngine.info(url).encrypted)
        #expect(throws: PowerError.self) { try PDFEngine.text(url) }
    }
}

}

func documentFixture(_ dir: URL, _ name: String, pages: Int, bookmark: Bool = false) throws -> URL {
    let url = dir.appendingPathComponent(name)
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Fixture title"] as CFDictionary))
    for n in 1...pages {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(n)", attributes: [.font: NSFont.systemFont(ofSize: 16)]) as CFAttributedString)
        context.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
    if bookmark {
        // Rebuild rather than editing the loaded PDF in place: PDFKit may reuse
        // its original byte stream when only an outline was changed.
        let loaded = try #require(PDFDocument(url: url))
        let doc = PDFDocument()
        for index in 0..<loaded.pageCount {
            let page = try #require(loaded.page(at: index)?.copy() as? PDFPage)
            doc.insert(page, at: doc.pageCount)
        }
        let root = PDFOutline(), chapter = PDFOutline()
        root.insertChild(chapter, at: 0)
        chapter.label = "Chapter two"
        chapter.destination = PDFDestination(page: try #require(doc.page(at: 1)), at: .zero)
        doc.outlineRoot = root
        #expect(doc.write(to: url))
    }
    return url
}

func documentImageFixture(_ dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("image.png")
    let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

func documentZIPPart(_ url: URL, _ part: String) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", url.path, part]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return String(decoding: data, as: UTF8.self)
}
