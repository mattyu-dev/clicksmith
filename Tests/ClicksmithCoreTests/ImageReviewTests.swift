import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Testing
@testable import ClicksmithCore

@Test func imageWritableFormatsParallelCallsUseOnlyNativeIdentifiers() async {
    let identifiers = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
    let expected = ImageFormat.allCases.filter {
        $0 == .ico || $0 == .icns || identifiers.contains($0.typeIdentifier)
    }
    await withTaskGroup(of: [ImageFormat].self) { group in
        for _ in 0..<32 { group.addTask { ImageEngine.writableFormats() } }
        for await result in group { #expect(result == expected) }
    }
}

extension ImageTestFiles {
    func pdf(pages: Int, width: Double = 72, height: Double = 36) throws -> URL {
        let output = url("pages.pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try #require(CGContext(output as CFURL, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 0 ? 0 : 1, alpha: 1)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return output
    }
}

@Test func imagePDFInfoUses200DPIWithoutRenderingEveryPage() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let pdf = try files.pdf(pages: 200, width: 612, height: 792)
    let info = try ImageEngine.info(pdf)
    #expect(info.pixelWidth == 1700)
    #expect(info.pixelHeight == 2200)
    #expect(info.dpiWidth == 200)
    #expect(info.frameCount == 200)
    var usage = rusage()
    #expect(getrusage(RUSAGE_SELF, &usage) == 0)
    print("PDF info peak RSS, bytes: \(usage.ru_maxrss)")
}

@Test(arguments: [ImageFormat.png, .gif, .tiff, .pdf])
func imagePDFOnlyKeepsPagesForDocumentTargets(format: ImageFormat) throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let pdf = try files.pdf(pages: 3)
    let output = files.url("output.\(format.rawValue)")
    try ImageEngine.convert(pdf, to: format, options: ImageConvertOptions(maxPixelSize: 40), output: output)
    if format == .pdf {
        #expect(try #require(CGPDFDocument(output as CFURL)).numberOfPages == 3)
    } else {
        let source = try files.source(output)
        #expect(CGImageSourceGetCount(source) == (format == .tiff ? 3 : 1))
        #expect(try ImageEngine.info(output).pixelWidth == 40)
        #expect(try ImageEngine.info(output).pixelHeight == 20)
        #expect(try files.pixel(output)[0] > 240)
        if format == .tiff { #expect(try files.pixel(output, index: 1)[2] > 240) }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path).allSatisfy { !$0.hasPrefix(".clicksmith-image-") })
}

@Test func imageHEIFCollectionUsesPrimaryImageForEveryTarget() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
    guard FileManager.default.fileExists(atPath: input.path) else {
        print("SKIP imageHEIFCollectionUsesPrimaryImageForEveryTarget: Sonoma.heic is absent")
        return
    }
    let source = try files.source(input)
    #expect(CGImageSourceGetCount(source) >= 2)
    let inspected = try ImageInput(input)
    #expect(!inspected.isAnimation)
    #expect(inspected.primaryIndex == CGImageSourceGetPrimaryImageIndex(source))
    for target in [ImageFormat.png, .gif, .heic, .tiff, .pdf] {
        #expect(inspected.indices(for: target) == [CGImageSourceGetPrimaryImageIndex(source)])
    }
    for format in [ImageFormat.png, .gif, .tiff, .pdf] {
        let output = files.url("primary.\(format.rawValue)")
        try ImageEngine.convert(input, to: format, options: ImageConvertOptions(maxPixelSize: 40), output: output)
        if format == .pdf {
            #expect(try #require(CGPDFDocument(output as CFURL)).numberOfPages == 1)
        } else {
            #expect(CGImageSourceGetCount(try files.source(output)) == 1)
        }
    }
}

@Test(arguments: [ImageFormat.bmp, .gif, .jp2])
func imageProfilelessFormatsConvertP3GreenToSRGB(format: ImageFormat) throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.7, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let input = try files.write("p3.png", image: #require(context.makeImage()))
    let expected = try files.pixel(input)
    let output = files.url("green.\(format.rawValue)")
    try ImageEngine.convert(input, to: format, options: ImageConvertOptions(quality: 1), output: output)
    let actual = try files.pixel(output)
    for component in 0..<3 { #expect(abs(Int(actual[component]) - Int(expected[component])) <= 10) }
}

@Test func imageOpaqueInputDoesNotAcquireAlpha() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let context = try #require(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let input = try files.write("opaque.png", image: #require(context.makeImage()))
    #expect(try !ImageEngine.info(input).hasAlpha)
    let output = files.url("converted.png")
    try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(maxPixelSize: 20, keepColorProfile: false), output: output)
    #expect(try !ImageEngine.info(output).hasAlpha)
}

@Test func imageAPNGInputRemainsAnimatedWhenConvertedToGIF() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let gif = try files.animation()
    let apng = files.url("animated.png")
    try ImageEngine.convert(gif, to: .png, options: ImageConvertOptions(), output: apng)
    #expect(CGImageSourceGetCount(try files.source(apng)) == 2)
    let output = files.url("roundtrip.gif")
    try ImageEngine.convert(apng, to: .gif, options: ImageConvertOptions(), output: output)
    #expect(try ImageEngine.info(output).frameCount == 2)
    #expect(try files.pixel(output, index: 1)[2] > 240)
    let properties = try files.properties(output, index: 1)[kCGImagePropertyGIFDictionary as String] as? [String: Any]
    #expect(properties?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double == 0.4)
}

@Test func imageLargeIconDecodingUsesOnlyIconSizedThumbnails() throws {
    let input = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")
    guard FileManager.default.fileExists(atPath: input.path) else {
        print("SKIP imageLargeIconDecodingUsesOnlyIconSizedThumbnails: Sonoma.heic is absent")
        return
    }
    let files = try ImageTestFiles()
    defer { files.remove() }
    #expect(try ImageEngine.info(input).pixelWidth >= 6000)
    for format in [ImageFormat.ico, .icns] {
        let output = files.url("large-source.\(format.rawValue)")
        try ImageEngine.makeIcon(input, format: format, output: output)
        #expect(try ImageEngine.info(output).pixelWidth == (format == .ico ? 256 : 1024))
    }
    var usage = rusage()
    #expect(getrusage(RUSAGE_SELF, &usage) == 0)
    print("Large icon peak RSS, bytes: \(usage.ru_maxrss)")
}

@Test func imageFailedDecodeRemovesScratchAndNeverPublishesPartialOutput() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let png = try files.write()
    let broken = files.url("truncated.png")
    try Data(contentsOf: png).prefix(33).write(to: broken)
    let source = try files.source(broken)
    #expect(CGImageSourceGetCount(source) == 1)
    let before = try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted()
    let output = files.url("absent.png")
    #expect(throws: ImageEngineError.self) {
        try ImageEngine.convert(broken, to: .png, options: ImageConvertOptions(), output: output)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: files.directory.path).sorted() == before)
}
