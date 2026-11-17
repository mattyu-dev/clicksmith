import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import Testing
@testable import ClicksmithCore

extension DocumentEngineTests {
@Suite struct DocumentReviewTests {
    @Test func rasterScaleFillsRotatedCropAtEveryDPI() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for rotation in [0, 90, 180, 270] {
            let pdf = dir.appendingPathComponent("page-\(rotation).pdf")
            var media = CGRect(x: 0, y: 0, width: 240, height: 320)
            var crop = CGRect(x: 30, y: 40, width: 120, height: 200)
            let cropData = Data(bytes: &crop, count: MemoryLayout<CGRect>.size)
            let context = try #require(CGContext(pdf as CFURL, mediaBox: &media, nil))
            context.beginPDFPage([kCGPDFContextCropBox: cropData, "Rotate": rotation] as CFDictionary)
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(crop)
            context.endPDFPage(); context.closePDF()
            // CoreGraphics does not accept Rotate as a page option; set it through PDFKit.
            let source = try #require(PDFDocument(url: pdf))
            let page = try #require(source.page(at: 0))
            page.rotation = rotation
            #expect(source.write(to: pdf))
            for dpi in [72, 150, 300] {
                let out = dir.appendingPathComponent("\(rotation)-\(dpi)")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
                let urls = try PDFEngine.pagesToImages(pdf, format: .png, dpi: dpi, outputDirectory: out)
                let firstURL = try #require(urls.first)
                let imageSource = try #require(CGImageSourceCreateWithURL(firstURL as CFURL, nil))
                let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
                let landscape = rotation == 90 || rotation == 270
                #expect(image.width == Int(ceil(Double(landscape ? 200 : 120) * Double(dpi) / 72)))
                #expect(image.height == Int(ceil(Double(landscape ? 120 : 200) * Double(dpi) / 72)))
                let bitmap = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
                let dark = stride(from: 0, to: image.width * image.height * 4, by: 4).filter { bytes[$0] < 32 }.count
                #expect(Double(dark) / Double(image.width * image.height) > 0.99, "rotation \(rotation), dpi \(dpi)")
            }
        }
    }

    @Test func richTextAndDOCXProcessOneMegabyteUnderThreeSeconds() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let line = "<p>Words <b>bold</b> and <a href=\"https://example.com\">link</a>.</p>\n"
        let repetitions = 1_048_576 / line.utf8.count + 1
        let html = String(repeating: line, count: repetitions)
        let start = ContinuousClock.now
        let text = try HTMLAttributedReader.read(html, isCancelled: { false })
        try DOCXWriter.write(text, to: dir.appendingPathComponent("large.docx"), isCancelled: { false })
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(3), "1 MB HTML import plus DOCX export took \(elapsed)")
        #expect(text.length == repetitions * 21)
    }

    @Test func markdownAliasesAndLegacyTextEncodingsConvert() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for ext in ["md", "markdown", "mdown"] {
            #expect(DocumentEngine.supportedTargets(for: ext).contains(.html))
            for encoding: String.Encoding in [.utf8, .utf16, .isoLatin1] {
                let url = dir.appendingPathComponent("\(encoding.rawValue).\(ext)")
                try #require("# café\n".data(using: encoding)).write(to: url)
                let output = url.appendingPathExtension("html")
                try DocumentEngine.convert(url, to: .html, output: output)
                #expect(try String(contentsOf: output, encoding: .utf8).contains("<h1>café</h1>"))
            }
        }
        let binary = dir.appendingPathComponent("binary.md")
        try Data([0x00, 0xff, 0x01, 0x02, 0x00]).write(to: binary)
        #expect(throws: PowerError.badInput("File is not text")) {
            try DocumentEngine.convert(binary, to: .html, output: dir.appendingPathComponent("binary.html"))
        }
    }

    @Test func docxUsesSchemaOrderPublicFontsAndHeadingStyles() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let input = try touch(dir, "source.md", "# **Heading**\n\n- ~~*Mixed*~~ text\n\n## Second\n")
        let out = dir.appendingPathComponent("out.docx")
        try DocumentEngine.convert(input, to: .docx, output: out)
        let xml = try documentZIPPart(out, "word/document.xml")
        let document = try XMLDocument(xmlString: xml)
        for (path, order) in [("//*[local-name()='pPr']", ["pStyle", "keepNext", "numPr", "ind", "jc", "outlineLvl"]),
                              ("//*[local-name()='rPr']", ["rFonts", "b", "i", "strike", "sz", "u"])] {
            for node in try document.nodes(forXPath: path) {
                let indices = (node.children ?? []).compactMap { $0.localName.flatMap { order.firstIndex(of: $0) } }
                #expect(indices == indices.sorted())
            }
        }
        #expect(!xml.contains(".AppleSystemUIFont"))
        #expect(xml.contains("<w:pStyle w:val=\"Heading1\"/>"))
        let styles = try documentZIPPart(out, "word/styles.xml")
        for level in 1...6 { #expect(styles.contains("w:styleId=\"Heading\(level)\"")) }
        let rels = try documentZIPPart(out, "word/_rels/document.xml.rels")
        #expect(rels.contains("relationships/styles"))
    }

    @Test func thousandsOfListsShareAbstractDefinitionsAndKeepStarts() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let markdown = String(repeating: "- Bullet\n\nseparator\n\n7. Ordered\n\nseparator\n\n", count: 2000)
        let text = try HTMLAttributedReader.read(MarkdownRenderer.html(markdown, title: nil), isCancelled: { false })
        let out = dir.appendingPathComponent("lists.docx")
        try DOCXWriter.write(text, to: out, isCancelled: { false })
        let numbering = try documentZIPPart(out, "word/numbering.xml")
        let xml = try XMLDocument(xmlString: numbering)
        #expect(try xml.nodes(forXPath: "//*[local-name()='abstractNum']").count == 2)
        #expect(try xml.nodes(forXPath: "//*[local-name()='num']").count == 4000)
        #expect(numbering.utf8.count < 1_000_000)
        #expect(numbering.contains("<w:startOverride w:val=\"7\"/>"))
    }

    @Test func imageCSPAllowsReadmeBadgesAndLocalImages() {
        let html = MarkdownRenderer.html("![badge](https://example.com/badge.svg)\n\n![local](file:///tmp/image.png)", title: nil)
        #expect(html.contains("img-src data: file: https:"))
        #expect(html.contains("src=\"https://example.com/badge.svg\""))
        #expect(html.contains("default-src 'none'"))
    }

    @Test func swiftFallbackRendersRichMarkdownWithoutSystemLibrary() throws {
        let markdown = """
        # Heading

        > A **bold** and *italic* quote.

        3. Third
           - Nested
        4. Fourth

        - [x] Complete
        - [ ] Pending

        | Left | Right |
        | :--- | ---: |
        | one | `two` |

        ```swift
        print("<hello>")
        ```

        ~~gone~~ https://example.com [Reference][ref]

        ![badge](https://example.com/badge.svg "Badge")

        [ref]: https://example.org "Reference"
        """
        let html = MarkdownRenderer.html(markdown, title: "A <title>", useSystemRenderer: false)
        for fragment in ["<h1>Heading</h1>", "<blockquote>", "<strong>bold</strong>", "<em>italic</em>", "<ol start=\"3\">", "Nested", "type=\"checkbox\"", "checked", "<table>", "align=\"right\"", "<code>two</code>", "language-swift", "&lt;hello&gt;", "<del>gone</del>", "href=\"https://example.com\"", "href=\"https://example.org\"", "src=\"https://example.com/badge.svg\""] {
            #expect(html.contains(fragment), "Missing \(fragment)")
        }
        #expect(html.contains("<title>A &lt;title&gt;</title>"))
        let text = try HTMLAttributedReader.read(html, isCancelled: { false })
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("fallback.docx")
        try DOCXWriter.write(text, to: out, isCancelled: { false })
        let xml = try documentZIPPart(out, "word/document.xml")
        #expect(xml.contains("<w:tbl>"))
        #expect(xml.contains("<w:hyperlink"))
        #expect(text.string.contains("print(\"<hello>\")"))
    }

    @Test func swiftFallbackEscapesContentAndRejectsActiveHTML() {
        let html = MarkdownRenderer.html("<script>alert(1)</script>\n\n[x](javascript:alert(1))\n\n`<script>` &amp; **safe**\n\n---", title: nil, useSystemRenderer: false)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(html.contains("<code>&lt;script&gt;</code>"))
        #expect(html.contains("<strong>safe</strong>"))
        #expect(html.contains("<hr />"))
    }

    @Test func swiftFallbackPreservesReferenceSyntaxInsideFencedCode() {
        let html = MarkdownRenderer.html("```\n[ref]: https://example.com\n```\n\n\\*literal\\* and a_b_c\n\nTitle\n===", title: nil, useSystemRenderer: false)
        #expect(html.contains("<pre><code>[ref]: https://example.com\n</code></pre>"))
        #expect(html.contains("*literal* and a_b_c"))
        #expect(html.contains("<h1>Title</h1>"))
    }
}
}
