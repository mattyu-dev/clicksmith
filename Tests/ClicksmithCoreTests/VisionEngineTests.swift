import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import ClicksmithCore

@Suite(.serialized) struct VisionEngineTests {
    @Test(arguments: ["https://apple.com", "WIFI:T:WPA;S:Guest;P:secret;;", "BEGIN:VCARD\nVERSION:3.0\nFN:Jane Doe\nEND:VCARD", "Bonjour 世界 🌍"])
    func qrRoundTrip(_ text: String) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("qr.png")
        try CodeWriter.qrPNG(text, output: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1024 && image.height == 1024)
        let codes = try CodeReader.read(image: output)
        let code = try #require(codes.first)
        #expect(codes.count == 1)
        #expect(code.payloadString == text)
        #expect(code.symbology == .qr)
        #expect(code.bounds.width > 0 && code.bounds.height > 0)
        #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(code.bounds))
        #expect(try CodeReader.read(cgImage: image).map(\.payloadString) == [text])
    }

    @Test func allCorrectionLevelsAndNonModuleSizedCanvas() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for level in [CodeWriter.Correction.L, .M, .Q, .H] {
            let output = dir.appendingPathComponent("\(level.rawValue).png")
            try CodeWriter.qrPNG("correction \(level.rawValue)", size: 333, correction: level, output: output)
            #expect(try CodeReader.read(image: output).first?.payloadString == "correction \(level.rawValue)")
        }
    }

    @Test func readsMultipleCodesAndNonQRBarcode() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try CodeWriter.qrPNG("first", size: 300, output: a)
        try CodeWriter.qrPNG("second", size: 300, output: b)
        let canvas = try visionCanvas(width: 800, height: 400)
        for (x, url) in [(50, a), (450, b)] {
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            canvas.draw(try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)), in: CGRect(x: x, y: 50, width: 300, height: 300))
        }
        #expect(Set(try CodeReader.read(cgImage: #require(canvas.makeImage())).map(\.payloadString)) == ["first", "second"])
        let barcode = CIFilter.code128BarcodeGenerator()
        barcode.message = Data("CLICKSMITH123".utf8)
        barcode.quietSpace = 20
        let ci = try #require(barcode.outputImage).transformed(by: CGAffineTransform(scaleX: 3, y: 3))
        let image = try #require(CIContext().createCGImage(ci, from: ci.extent))
        let codes = try CodeReader.read(cgImage: image)
        #expect(codes.first?.symbology == .code128)
        #expect(codes.first?.payloadString == "CLICKSMITH123")
    }

    @Test func qrRejectsInvalidSizesExistingOutputsAndCancellation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try touch(dir, "keep.png", "ORIGINAL")
        #expect(throws: PowerError.self) { try CodeWriter.qrPNG("hello", output: output) }
        #expect(try String(contentsOf: output, encoding: .utf8) == "ORIGINAL")
        let fresh = dir.appendingPathComponent("fresh.png")
        for size in [0, -1, 10, Int.max] {
            #expect(throws: PowerError.self) { try CodeWriter.qrPNG("hello", size: size, output: fresh) }
        }
        #expect(throws: PowerError.cancelled) { try CodeWriter.qrPNG("hello", output: fresh, isCancelled: { true }) }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        #expect(names(dir) == ["keep.png"])
    }

    @Test func ocrRenderedTextImage() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("text.png")
        try visionSave(visionTextImage("CLICKSMITH 123"), to: output)
        let text = try TextRecognizer.text(image: output, languages: ["en-US"])
        #expect(text.contains("CLICKSMITH 123"))
        #expect(try TextRecognizer.text(image: output, languages: ["en-US"], accurate: false).contains("CLICKSMITH"))
        #expect(throws: PowerError.self) { _ = try TextRecognizer.text(image: output, languages: ["invalid-language"]) }
        #expect(throws: PowerError.cancelled) { _ = try TextRecognizer.text(image: output, isCancelled: { true }) }
    }

    @Test func pdfUsesEmbeddedTextAndOCRForScannedPages() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("mixed.pdf")
        try visionPDF(pdf) { ctx in
            ctx.beginPDFPage(nil)
            visionDrawText("EMBEDDED PAGE", in: ctx, at: CGPoint(x: 40, y: 600), size: 40)
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            ctx.draw(try visionTextImage("SCANNED PAGE"), in: CGRect(x: 20, y: 400, width: 570, height: 140))
            ctx.endPDFPage()
        }
        var progress: [Double] = []
        let text = try TextRecognizer.text(pdf: pdf, progress: { progress.append($0) })
        #expect(text.contains("EMBEDDED PAGE"))
        #expect(text.contains("SCANNED PAGE"))
        let embedded = try #require(text.range(of: "EMBEDDED"))
        let scanned = try #require(text.range(of: "SCANNED"))
        #expect(embedded.lowerBound < scanned.lowerBound)
        #expect(progress.first == 0 && progress.last == 1)
        #expect(progress == progress.sorted())
    }

    @Test func readsCodesFromPDFPages() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("qr.png"), pdf = dir.appendingPathComponent("codes.pdf")
        try CodeWriter.qrPNG("PDF CODE", size: 400, output: png)
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        try visionPDF(pdf) { ctx in
            for _ in 0..<2 {
                ctx.beginPDFPage(nil)
                ctx.draw(image, in: CGRect(x: 100, y: 200, width: 400, height: 400))
                ctx.endPDFPage()
            }
        }
        #expect(try CodeReader.read(pdf: pdf).map(\.payloadString) == ["PDF CODE", "PDF CODE"])
        #expect(throws: PowerError.self) { _ = try CodeReader.read(pdf: pdf, dpi: 0) }
        #expect(throws: PowerError.cancelled) { _ = try CodeReader.read(pdf: pdf, isCancelled: { true }) }
    }

    @Test(arguments: ["7", "DOCUMENT HEADER WITH EMBEDDED TEXT"])
    func embeddedCaptionDoesNotHideScannedContent(_ caption: String) throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("captioned-scan.pdf")
        try visionPDF(pdf) { ctx in
            ctx.beginPDFPage(nil)
            ctx.draw(try visionScannedPage(), in: CGRect(x: 40, y: 80, width: 530, height: 650))
            visionDrawText(caption, in: ctx, at: CGPoint(x: 30, y: 30), size: 18)
            ctx.endPDFPage()
        }
        let text = try TextRecognizer.text(pdf: pdf)
        #expect(text.contains("SCANNED CONTENT"))
        #expect(text.contains(caption))
    }

    @Test func backgroundRemovalMakesCornersTransparentAndKeepsSubjectOpaque() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("ball.png"), output = dir.appendingPathComponent("cutout.png")
        let ctx = try visionCanvas(width: 512, height: 512)
        ctx.addEllipse(in: CGRect(x: 120, y: 120, width: 272, height: 272)); ctx.clip()
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                              colors: [CGColor(red: 1, green: 0.35, blue: 0.2, alpha: 1),
                                                       CGColor(red: 0.55, green: 0, blue: 0, alpha: 1)] as CFArray, locations: [0, 1]))
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 205, y: 310), startRadius: 0,
                               endCenter: CGPoint(x: 256, y: 256), endRadius: 190, options: [.drawsAfterEndLocation])
        try visionSave(#require(ctx.makeImage()), to: input)
        let original = try Data(contentsOf: input)
        try BackgroundRemover.removeBackground(input, output: output)
        let result = try VisionIO.image(output)
        #expect(result.width == 512 && result.height == 512)
        let pixels = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 512 * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixels.draw(result, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 0)
        #expect(bytes[(256 * 512 + 256) * 4 + 3] == 255)
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func invalidInputsProduceTypedErrorsWithoutOutputs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let invalid = try touch(dir, "bad.png", "not an image")
        let output = dir.appendingPathComponent("cutout.png")
        #expect(throws: PowerError.self) { _ = try CodeReader.read(image: invalid) }
        #expect(throws: PowerError.self) { _ = try CodeReader.read(pdf: invalid) }
        #expect(throws: PowerError.self) { _ = try TextRecognizer.text(image: invalid) }
        #expect(throws: PowerError.self) { _ = try TextRecognizer.text(pdf: invalid) }
        #expect(throws: PowerError.self) { try BackgroundRemover.removeBackground(invalid, output: output) }
        #expect(throws: PowerError.cancelled) { try BackgroundRemover.removeBackground(invalid, output: output, isCancelled: { true }) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

func visionCanvas(width: Int, height: Int) throws -> CGContext {
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx
}

func visionDrawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                             NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]
    ctx.textPosition = point
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs)), ctx)
}

func visionTextImage(_ text: String) throws -> CGImage {
    let ctx = try visionCanvas(width: 1000, height: 240)
    visionDrawText(text, in: ctx, at: CGPoint(x: 40, y: 90), size: 70)
    return try #require(ctx.makeImage())
}

func visionScannedPage() throws -> CGImage {
    let ctx = try visionCanvas(width: 1000, height: 1400)
    visionDrawText("SCANNED CONTENT", in: ctx, at: CGPoint(x: 40, y: 1100), size: 65)
    visionDrawText("IMPORTANT DETAILS", in: ctx, at: CGPoint(x: 40, y: 800), size: 50)
    return try #require(ctx.makeImage())
}

func visionSave(_ image: CGImage, to url: URL) throws {
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

func visionPDF(_ url: URL, draw: (CGContext) throws -> Void) throws {
    var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = try #require(CGContext(url as CFURL, mediaBox: &rect, nil))
    defer { ctx.closePDF() }
    try draw(ctx)
}
