import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import Vision
@testable import ClicksmithCore

@Suite struct VisionIOTests {
    @Test func exclusivePublicationPreservesFilesAndSymlinks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try touch(dir, "original.png", "ORIGINAL")
        let link = dir.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        for target in [original, link] {
            #expect(throws: (any Error).self) { try VisionIO.write(Data("new".utf8), to: target, isCancelled: { false }) }
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "ORIGINAL")
        let fresh = dir.appendingPathComponent("fresh.png")
        try VisionIO.write(Data("complete".utf8), to: fresh, isCancelled: { false })
        #expect(try Data(contentsOf: fresh) == Data("complete".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["fresh.png", "link.png", "original.png"])
    }

    @Test func publishedOutputUsesNormalUmaskPermissions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = dir.appendingPathComponent("reference")
        let fd = open(reference.path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
        let output = dir.appendingPathComponent("output.png")
        try VisionIO.write(Data("PNG".utf8), to: output, isCancelled: { false })
        let expected = try #require(try FileManager.default.attributesOfItem(atPath: reference.path)[.posixPermissions] as? NSNumber)
        let actual = try #require(try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)
        #expect(actual == expected)
        #expect(actual.intValue & 0o111 == 0)
    }

    @Test func largePhonePhotoIsDownscaledBeforeDecoding() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let width = 8064, height = 6048
        let pixels = Data(repeating: 255, count: width * height)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let original = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = dir.appendingPathComponent("phone.png")
        try visionSave(original, to: input)
        let inputBytes = try Data(contentsOf: input)
        let image = try VisionIO.image(input)
        #expect(image.width < width && image.height < height)
        #expect(image.width * image.height <= 40_000_000)
        #expect(abs(Double(image.width) / Double(image.height) - 4.0 / 3) < 0.002)
        #expect(try Data(contentsOf: input) == inputBytes)
    }

    @Test func cancellationRemovesStagingAndLeavesNoPartialOutput() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("result.png")
        var checks = 0
        #expect(throws: PowerError.cancelled) {
            try VisionIO.write(Data(repeating: 65, count: 500_000), to: output, isCancelled: {
                checks += 1
                return checks >= 4
            })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func failedOutputPublicationCleansOwnedStaging() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("missing/result.png")
        #expect(throws: (any Error).self) { try VisionIO.write(Data("content".utf8), to: output, isCancelled: { false }) }
        #expect(throws: PowerError.self) { try VisionIO.write(Data(), to: URL(string: "https://example.org/output")!, isCancelled: { false }) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func pngRetainsAlphaAndImageLoadingAppliesOrientation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = try #require(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 20, y: 10, width: 30, height: 30))
        let image = try #require(ctx.makeImage())
        let png = dir.appendingPathComponent("alpha.png")
        try VisionIO.write(VisionIO.png(image), to: png, isCancelled: { false })
        let decoded = try VisionIO.image(png)
        #expect(decoded.width == 120 && decoded.height == 60)
        #expect(decoded.alphaInfo != .none && decoded.alphaInfo != .noneSkipFirst && decoded.alphaInfo != .noneSkipLast)
        let pixelCtx = try #require(CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixelCtx.draw(decoded, in: CGRect(x: 0, y: 0, width: 120, height: 60))
        let bytes = try #require(pixelCtx.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == 0)
        #expect(bytes[(20 * 120 + 30) * 4 + 3] == 255)
        let rotated = dir.appendingPathComponent("rotated.tiff")
        let dest = try #require(CGImageDestinationCreateWithURL(rotated as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        let oriented = try VisionIO.image(rotated)
        #expect(oriented.width == 60 && oriented.height == 120)
    }

    @Test func embeddedPDFTextAvoidsOCR() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("embedded.pdf")
        try visionPDF(pdf) { ctx in
            ctx.beginPDFPage(nil)
            visionDrawText("EXACT EMBEDDED TEXT STAYS INTACT", in: ctx, at: CGPoint(x: 30, y: 400), size: 26)
            ctx.endPDFPage()
        }
        #expect(try TextRecognizer.text(pdf: pdf).trimmingCharacters(in: .whitespacesAndNewlines) == "EXACT EMBEDDED TEXT STAYS INTACT")
    }

    @Test func pdfRenderingHandlesRotatedCropAndDimensionLimits() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("rotated.pdf")
        try visionPDF(pdf) { ctx in ctx.beginPDFPage(nil); ctx.endPDFPage() }
        let document = try VisionIO.pdf(pdf)
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 200, height: 100), for: .cropBox)
        page.rotation = 90
        let image = try VisionIO.render(page, dpi: 144)
        #expect(image.width == 200 && image.height == 400)
        #expect(throws: PowerError.self) { try VisionIO.validateDimensions(width: Int.max, height: 2) }
        #expect(throws: PowerError.self) { try VisionIO.validateDimensions(width: 10_000, height: 10_000) }
    }

    @Test func pdfCancellationStopsBetweenPages() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("embedded.pdf")
        try visionPDF(pdf) { ctx in
            for _ in 0..<3 {
                ctx.beginPDFPage(nil)
                visionDrawText("THIS PAGE HAS ENOUGH EMBEDDED TEXT", in: ctx, at: CGPoint(x: 20, y: 400), size: 22)
                ctx.endPDFPage()
            }
        }
        let flag = VisionCancellationFlag()
        var progress: [Double] = []
        #expect(throws: PowerError.cancelled) {
            _ = try TextRecognizer.text(pdf: pdf, progress: {
                progress.append($0)
                if $0 > 0 { flag.cancel() }
            }, isCancelled: { flag.isCancelled })
        }
        #expect(progress == [0, 1.0 / 3])
    }

    @Test func ocrSelectionIncludesSparseTextAndRasterPages() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("selection.pdf")
        let caption = "DOCUMENT HEADER WITH EMBEDDED TEXT"
        try visionPDF(pdf) { ctx in
            ctx.beginPDFPage(nil)
            visionDrawText("7", in: ctx, at: CGPoint(x: 30, y: 30), size: 18)
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            visionDrawText(caption, in: ctx, at: CGPoint(x: 30, y: 30), size: 18)
            ctx.draw(try visionScannedPage(), in: CGRect(x: 40, y: 80, width: 530, height: 650))
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            visionDrawText(caption, in: ctx, at: CGPoint(x: 30, y: 30), size: 18)
            ctx.endPDFPage()
        }
        let document = try VisionIO.pdf(pdf)
        let pages = try (0..<3).map { try #require(document.page(at: $0)) }
        #expect(TextRecognizer.needsOCR(pages[0], embedded: "7"))
        #expect(TextRecognizer.needsOCR(pages[1], embedded: caption))
        #expect(!TextRecognizer.needsOCR(pages[2], embedded: caption))
    }

    @Test(arguments: [false, true]) func cancellationCallsVisionCancelDuringPerform(cancelTask: Bool) async throws {
        let started = DispatchSemaphore(value: 0)
        let flag = VisionCancellationFlag()
        // Real Vision cannot perform in this sandbox. This handler holds that native
        // boundary open until the engine calls VNRequest.cancel(), or two seconds pass.
        let task = Task.detached { () throws -> Bool in
            let request = VisionRecordingRequest(started: started)
            let handler = VisionWaitingHandler(cgImage: try visionTextImage("CANCEL"))
            do { try VisionIO.perform(request, handler: handler, isCancelled: { cancelTask ? Task.isCancelled : flag.isCancelled }) }
            catch PowerError.cancelled { }
            return request.didCancel.isCancelled
        }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 5) == .success)
            }
        }
        #expect(didStart)
        let clock = ContinuousClock()
        let cancelStart = clock.now
        if cancelTask { task.cancel() } else { flag.cancel() }
        let didCancel = try await task.value
        #expect(didCancel)
        #expect(cancelStart.duration(to: clock.now) < .seconds(1))
    }
}

final class VisionCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private final class VisionRecordingRequest: VNRequest {
    let started: DispatchSemaphore
    let cancelled = DispatchSemaphore(value: 0)
    let didCancel = VisionCancellationFlag()
    init(started: DispatchSemaphore) { self.started = started; super.init(completionHandler: nil) }
    override func cancel() { didCancel.cancel(); cancelled.signal(); super.cancel() }
}

private final class VisionWaitingHandler: VNImageRequestHandler {
    override func perform(_ requests: [VNRequest]) throws {
        guard let request = requests.first as? VisionRecordingRequest else { throw PowerError.badInput("Missing test request.") }
        request.started.signal()
        _ = request.cancelled.wait(timeout: .now() + 2)
    }
}
