import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ClicksmithCore

// Each fixture is generated in a private temporary directory. No user files or binary fixtures.
struct ImageTestFiles {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    func image(width: Int = 80, height: Int = 40, alpha: Bool = false, blue: Bool = false,
               colorSpace: CGColorSpace? = nil) throws -> CGImage {
        let space = try #require(colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: blue ? 0 : 1, green: 0, blue: blue ? 1 : 0, alpha: alpha ? 0.5 : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @discardableResult
    func write(_ name: String = "input.png", type: String = "public.png",
               properties: [String: Any] = [:], image: CGImage? = nil) throws -> URL {
        let target = url(name)
        let destination = try #require(CGImageDestinationCreateWithURL(target as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try image ?? self.image(), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return target
    }

    func source(_ url: URL) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    func properties(_ url: URL, index: Int = 0) throws -> [String: Any] {
        try #require(CGImageSourceCopyPropertiesAtIndex(try source(url), index, nil) as? [String: Any])
    }

    func animation(_ name: String = "animation.gif", type: String = "com.compuserve.gif") throws -> URL {
        let target = url(name)
        let destination = try #require(CGImageDestinationCreateWithURL(target as CFURL, type as CFString, 2, nil))
        let heics = type == "public.heics"
        let dictionary = (heics ? kCGImagePropertyHEICSDictionary : kCGImagePropertyGIFDictionary) as String
        let loop = (heics ? kCGImagePropertyHEICSLoopCount : kCGImagePropertyGIFLoopCount) as String
        let delay = (heics ? kCGImagePropertyHEICSDelayTime : kCGImagePropertyGIFDelayTime) as String
        CGImageDestinationSetProperties(destination, [dictionary: [loop: 3]] as CFDictionary)
        for index in 0..<2 {
            let frame = try image(blue: index == 1)
            CGImageDestinationAddImage(destination, frame, [dictionary: [delay: index == 0 ? 0.2 : 0.4]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return target
    }

    func pixel(_ url: URL, index: Int = 0) throws -> [UInt8] {
        let decoded = try #require(CGImageSourceCreateImageAtIndex(try source(url), index, nil))
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }
}

@Test func imageFormatDiscoveryMatchesNativeWritersAndCustomIcons() throws {
    let native = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
    let identifiers: [ImageFormat: String] = [
        .jpeg: "public.jpeg", .png: "public.png", .heic: "public.heic", .avif: "public.avif",
        .tiff: "public.tiff", .gif: "com.compuserve.gif", .bmp: "com.microsoft.bmp",
        .webp: "org.webmproject.webp", .jp2: "public.jpeg-2000", .pdf: "com.adobe.pdf"
    ]
    let expected = ImageFormat.allCases.filter {
        $0 == .ico || $0 == .icns || native.contains(identifiers[$0] ?? "")
    }
    #expect(ImageEngine.writableFormats() == expected)
    #expect(Set(ImageEngine.readableTypes()) == Set(CGImageSourceCopyTypeIdentifiers() as! [String]).union(["com.adobe.pdf"]))
    let options = ImageConvertOptions(quality: 0.8, maxPixelSize: 64, stripMetadata: true,
                                      keepColorProfile: false, background: ImageBackground(red: 0, green: 0.5, blue: 1))
    let decoded = try JSONDecoder().decode(ImageConvertOptions.self, from: JSONEncoder().encode(options))
    #expect(decoded.quality == 0.8)
    #expect(decoded.maxPixelSize == 64)
    #expect(decoded.stripMetadata)
    #expect(!decoded.keepColorProfile)
    #expect(decoded.background.green == 0.5)
    #expect(try JSONDecoder().decode(ImageFormat.self, from: JSONEncoder().encode(ImageFormat.heic)) == .heic)
}

@Test(arguments: ImageFormat.allCases)
func imageRoundTripEveryAdvertisedFormat(format: ImageFormat) throws {
    if [.heic, .avif].contains(format), !ImageNativeTest.isWorker {
        try ImageNativeTest.run("roundtrip", format: format)
        return
    }
    guard ImageEngine.writableFormats().contains(format) else {
        print("SKIP \(format.rawValue): no native writer")
        return
    }
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let before = try Data(contentsOf: input)
    let output = files.url("converted.\(format.rawValue)")
    try ImageEngine.convert(input, to: format, options: ImageConvertOptions(), output: output)
    if format == .pdf {
        let pdf = try #require(CGPDFDocument(output as CFURL))
        #expect(pdf.numberOfPages == 1)
        let page = try #require(pdf.page(at: 1))
        #expect(page.getBoxRect(.mediaBox).width == 80)
        #expect(page.getBoxRect(.mediaBox).height == 40)
    } else {
        let source = try files.source(output)
        #expect(CGImageSourceGetCount(source) > 0)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
    }
    if format != .ico && format != .icns {
        let info = try ImageEngine.info(output)
        #expect(info.pixelWidth == (format == .pdf ? 223 : 80))
        #expect(info.pixelHeight == (format == .pdf ? 112 : 40))
    }
    let roundTrip = files.url("roundtrip.png")
    try ImageEngine.convert(output, to: .png, options: ImageConvertOptions(), output: roundTrip)
    #expect(CGImageSourceCreateImageAtIndex(try files.source(roundTrip), 0, nil) != nil)
    #expect(try Data(contentsOf: input) == before)
}

@Test func imageInfoReadsDPIExifAndCamera() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write("metadata.tiff", type: "public.tiff", properties: [
        kCGImagePropertyDPIWidth as String: 144, kCGImagePropertyDPIHeight as String: 144,
        kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:11:16 12:34:56"],
        kCGImagePropertyTIFFDictionary as String: [
            kCGImagePropertyTIFFMake as String: "Test camera", kCGImagePropertyTIFFModel as String: "Model 4"
        ]
    ], image: files.image(alpha: true))
    let info = try ImageEngine.info(input)
    #expect(info.pixelWidth == 80)
    #expect(info.pixelHeight == 40)
    #expect(info.dpiWidth == 144)
    #expect(info.dpiHeight == 144)
    #expect(info.colorModel == "RGB")
    #expect(info.hasAlpha)
    #expect(info.exifDate == "2026:11:16 12:34:56")
    #expect(info.cameraMake == "Test camera")
    #expect(info.cameraModel == "Model 4")
    #expect(info.frameCount == 1)
}

@Test func imageStripMetadataRemovesGPSAndCameraButKeepsProfile() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write("gps.tiff", type: "public.tiff", properties: [
        kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 48.8, kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 2.3, kCGImagePropertyGPSLongitudeRef as String: "E"
        ],
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Private camera"]
    ], image: files.image(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)))
    #expect(try files.properties(input)[kCGImagePropertyGPSDictionary as String] != nil)
    let kept = files.url("kept.tiff")
    try ImageEngine.convert(input, to: .tiff, options: ImageConvertOptions(), output: kept)
    let gps = try files.properties(kept)[kCGImagePropertyGPSDictionary as String] as? [String: Any]
    #expect(gps?[kCGImagePropertyGPSLatitude as String] as? Double == 48.8)
    let stripped = files.url("stripped.tiff")
    try ImageEngine.convert(input, to: .tiff, options: ImageConvertOptions(stripMetadata: true), output: stripped)
    #expect(try files.properties(stripped)[kCGImagePropertyGPSDictionary as String] == nil)
    #expect(try ImageEngine.info(stripped).cameraMake == nil)
    let decoded = try #require(CGImageSourceCreateImageAtIndex(try files.source(stripped), 0, nil))
    #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
    let unprofiled = files.url("unprofiled.png")
    try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(keepColorProfile: false), output: unprofiled)
    let converted = try #require(CGImageSourceCreateImageAtIndex(try files.source(unprofiled), 0, nil))
    #expect(converted.colorSpace?.name != CGColorSpace.displayP3)
}

@Test func imageResizeFitsBoundsWithoutUpscaling() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let output = files.url("resized.png")
    try ImageEngine.resize(input, maxPixelSize: 20, output: output)
    #expect(try ImageEngine.info(output).pixelWidth == 20)
    #expect(try ImageEngine.info(output).pixelHeight == 10)
    let large = files.url("not-upscaled.png")
    try ImageEngine.resize(input, maxPixelSize: 1000, output: large)
    #expect(try ImageEngine.info(large).pixelWidth == 80)
    #expect(try ImageEngine.info(large).pixelHeight == 40)
    let combined = files.url("converted-small.jpeg")
    try ImageEngine.convert(input, to: .jpeg, options: ImageConvertOptions(maxPixelSize: 16), output: combined)
    #expect(try ImageEngine.info(combined).pixelWidth == 16)
    #expect(try ImageEngine.info(combined).pixelHeight == 8)
}

@Test func imageConversionAppliesExifOrientationOnce() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write("oriented.tiff", type: "public.tiff", properties: [kCGImagePropertyOrientation as String: 6])
    let output = files.url("upright.png")
    try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(), output: output)
    #expect(try ImageEngine.info(output).pixelWidth == 40)
    #expect(try ImageEngine.info(output).pixelHeight == 80)
    let second = files.url("upright-again.png")
    try ImageEngine.convert(output, to: .png, options: ImageConvertOptions(), output: second)
    #expect(try ImageEngine.info(second).pixelWidth == 40)
    #expect(try ImageEngine.info(second).pixelHeight == 80)
}

@Test func imageJPEGFlattensAlphaAgainstChosenBackground() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write(image: files.image(alpha: true))
    let white = files.url("white.jpg")
    try ImageEngine.convert(input, to: .jpeg, options: ImageConvertOptions(quality: 1), output: white)
    let whitePixel = try files.pixel(white)
    #expect(whitePixel[0] > 240)
    #expect(whitePixel[1] > 100 && whitePixel[1] < 150)
    #expect(whitePixel[2] > 100 && whitePixel[2] < 150)
    #expect(try !ImageEngine.info(white).hasAlpha)
    let blue = files.url("blue.jpg")
    try ImageEngine.convert(input, to: .jpeg,
                            options: ImageConvertOptions(quality: 1, background: ImageBackground(red: 0, green: 0, blue: 1)),
                            output: blue)
    let bluePixel = try files.pixel(blue)
    #expect(bluePixel[0] > 100 && bluePixel[0] < 150)
    #expect(bluePixel[1] < 15)
    #expect(bluePixel[2] > 100 && bluePixel[2] < 150)
    let png = files.url("alpha.png")
    try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(), output: png)
    #expect(try ImageEngine.info(png).hasAlpha)
    #expect(try files.pixel(png)[3] > 100 && files.pixel(png)[3] < 150)
}

@Test(arguments: [ImageFormat.gif, .png, .tiff, .heic])
func imageAnimationRetainsFramesAndTiming(format: ImageFormat) throws {
    if format == .heic, !ImageNativeTest.isWorker {
        try ImageNativeTest.run("animation")
        return
    }
    guard ImageEngine.writableFormats().contains(format) else {
        print("SKIP \(format.rawValue): no native writer")
        return
    }
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.animation()
    let output = files.url("converted-animation.\(format.rawValue)")
    try ImageEngine.convert(input, to: format, options: ImageConvertOptions(stripMetadata: true), output: output)
    #expect(CGImageSourceGetCount(try files.source(output)) == 2)
    #expect(try files.pixel(output)[0] > 240)
    #expect(try files.pixel(output, index: 1)[2] > 240)
    if format != .tiff {
        let dictionary = (format == .gif ? kCGImagePropertyGIFDictionary :
                          format == .png ? kCGImagePropertyPNGDictionary : kCGImagePropertyHEICSDictionary) as String
        let delay = (format == .gif ? kCGImagePropertyGIFUnclampedDelayTime :
                     format == .png ? kCGImagePropertyAPNGUnclampedDelayTime : kCGImagePropertyHEICSUnclampedDelayTime) as String
        let loop = (format == .gif ? kCGImagePropertyGIFLoopCount :
                    format == .png ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyHEICSLoopCount) as String
        let first = try files.properties(output, index: 0)[dictionary] as? [String: Any]
        #expect(abs((ImageEngine.number(first?[delay]) ?? 0) - 0.2) < 0.02)
        // macOS limit (probed 2026-11-16): the HEICS writer stores the last frame with the
        // previous frame's duration (stts [0.2, 0.4] -> [0.2, 0.2]) whatever delay is passed.
        if format != .heic {
            let last = try files.properties(output, index: 1)[dictionary] as? [String: Any]
            #expect(abs((ImageEngine.number(last?[delay]) ?? 0) - 0.4) < 0.02)
        }
        let container = CGImageSourceCopyProperties(try files.source(output), nil) as? [String: Any]
        // macOS limit (probed 2026-11-16): the HEICS writer always stores LoopCount 1. GIF/APNG keep it.
        if format != .heic { #expect((container?[dictionary] as? [String: Any])?[loop] as? Int == 3) }
    }
}

@Test func imagePDFResizeRetainsPDFAndCanBeReadBack() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let pdf = files.url("input.pdf")
    try ImageEngine.convert(input, to: .pdf, options: ImageConvertOptions(), output: pdf)
    let resized = files.url("small.pdf")
    try ImageEngine.resize(pdf, maxPixelSize: 20, output: resized)
    #expect(try #require(CGPDFDocument(resized as CFURL)).numberOfPages == 1)
    #expect(try ImageEngine.info(resized).pixelWidth == 20)
    #expect(try ImageEngine.info(resized).pixelHeight == 10)
}

@Test func imageMultiPagePDFKeepsPagesAndReadsWithoutPDFExtension() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let tiff = try files.animation("pages.tiff", type: "public.tiff")
    let pdf = files.url("pages.data")
    try ImageEngine.convert(tiff, to: .pdf, options: ImageConvertOptions(), output: pdf)
    #expect(try #require(CGPDFDocument(pdf as CFURL)).numberOfPages == 2)
    #expect(try ImageEngine.info(pdf).frameCount == 2)
    let roundTrip = files.url("pages-again.tiff")
    try ImageEngine.convert(pdf, to: .tiff, options: ImageConvertOptions(), output: roundTrip)
    #expect(try ImageEngine.info(roundTrip).frameCount == 2)
    #expect(try files.pixel(roundTrip)[0] > 240)
    #expect(try files.pixel(roundTrip, index: 1)[2] > 240)
}

@Test func imagePDFMarkerInsideImageMetadataDoesNotChangeItsFormat() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write("description.tiff", type: "public.tiff", properties: [
        kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFImageDescription as String: "%PDF-1.7"]
    ], image: files.image(width: 4, height: 2))
    let bytes = try Data(contentsOf: input)
    #expect(bytes.prefix(1024).range(of: Data("%PDF-".utf8)) != nil)
    #expect(try ImageEngine.info(input).pixelWidth == 4)
    let output = files.url("still-tiff.data")
    try ImageEngine.resize(input, maxPixelSize: 2, output: output)
    #expect(CGImageSourceGetType(try files.source(output)) as String? == "public.tiff")
}

@Test func imageHEICSInputRetainsAnimationWhenEncoderIsAvailable() throws {
    if !ImageNativeTest.isWorker { try ImageNativeTest.run("heics"); return }
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.animation("input.heics", type: "public.heics")
    let output = files.url("converted.gif")
    try ImageEngine.convert(input, to: .gif, options: ImageConvertOptions(), output: output)
    #expect(try ImageEngine.info(output).frameCount == 2)
    #expect(try files.pixel(output)[0] > 230)
    #expect(try files.pixel(output, index: 1)[2] > 230)
}

@Test func imageResizeKeepsAnimationInInputFormat() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.animation()
    let output = files.url("small.gif")
    try ImageEngine.resize(input, maxPixelSize: 20, output: output)
    #expect(CGImageSourceGetType(try files.source(output)) as String? == "com.compuserve.gif")
    #expect(try ImageEngine.info(output).frameCount == 2)
    #expect(try ImageEngine.info(output).pixelWidth == 20)
}

@Test(arguments: [ImageFormat.ico, .icns])
func imageIconsContainAllRepresentationsAndDecode(format: ImageFormat) throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let output = files.url("icon.\(format.rawValue)")
    try ImageEngine.makeIcon(input, format: format, output: output)
    let source = try files.source(output)
    var sizes = Set<Int>()
    for index in 0..<CGImageSourceGetCount(source) {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        #expect(image.width == image.height)
        sizes.insert(image.width)
    }
    if format == .ico {
        #expect(sizes == [16, 32, 48, 64, 128, 256])
    } else {
        #expect(sizes == [16, 32, 64, 128, 256, 512, 1024])
        let data = try Data(contentsOf: output)
        let tags = ["icp4", "icp5", "ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"]
        for tag in tags { #expect(data.range(of: Data(tag.utf8)) != nil) }
        #expect(data.range(of: Data("icp6".utf8)) == nil)
        // Re-read through Apple's independent iconutil, including the Retina variants.
        let extracted = files.url("extracted.iconset")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "iconset", "-o", extracted.path, output.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("icon_512x512@2x.png").path))
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("icon_16x16@2x.png").path))
    }
}

@Test(arguments: [ImageFormat.ico, .icns])
func imageIconConversionUsesLargestRepresentationAndResizeHonorsBound(format: ImageFormat) throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let icon = files.url("large.\(format.rawValue)")
    try ImageEngine.makeIcon(input, format: format, output: icon)
    let png = files.url("largest.png")
    try ImageEngine.convert(icon, to: .png, options: ImageConvertOptions(), output: png)
    #expect(CGImageSourceGetCount(try files.source(png)) == 1)
    #expect(try ImageEngine.info(png).pixelWidth == (format == .ico ? 256 : 1024))
    #expect(try ImageEngine.info(icon).pixelWidth == (format == .ico ? 256 : 1024))
    #expect(try ImageEngine.info(icon).frameCount == 1)
    let small = files.url("small.\(format.rawValue)")
    try ImageEngine.resize(icon, maxPixelSize: 32, output: small)
    let source = try files.source(small)
    for index in 0..<CGImageSourceGetCount(source) {
        let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
        #expect(image.width <= 32)
        #expect(image.height <= 32)
    }
    #expect(try ImageEngine.info(small).pixelWidth == 32)
}

@Test func imageConcurrentConversionsNeverOverwriteWinner() async throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let red = try files.write("red.png")
    let blue = try files.write("blue.png", image: files.image(blue: true))
    let output = files.url("winner.png")
    let wins = await withTaskGroup(of: Int.self) { group in
        for input in [red, blue] {
            group.addTask {
                do {
                    try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(), output: output)
                    return 1
                } catch ImageEngineError.outputExists {
                    return 0
                } catch {
                    Issue.record("Unexpected conversion error: \(error)")
                    return 0
                }
            }
        }
        var count = 0
        for await result in group { count += result }
        return count
    }
    #expect(wins == 1)
    let pixel = try files.pixel(output)
    #expect((pixel[0] > 240 && pixel[2] < 15) || (pixel[2] > 240 && pixel[0] < 15))
}

@Test func imageExistingOutputAndInputAreNeverReplaced() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let original = try Data(contentsOf: input)
    #expect(throws: ImageEngineError.self) {
        try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(), output: input)
    }
    let output = files.url("existing.png")
    try Data("keep me".utf8).write(to: output)
    #expect(throws: ImageEngineError.self) {
        try ImageEngine.resize(input, maxPixelSize: 20, output: output)
    }
    #expect(try Data(contentsOf: output) == Data("keep me".utf8))
    #expect(try Data(contentsOf: input) == original)
    let link = files.url("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
    #expect(throws: ImageEngineError.self) {
        try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(), output: link)
    }
    #expect(try Data(contentsOf: input) == original)
}

@Test func imageInvalidInputsAndOptionsProduceTypedErrorsWithoutOutput() throws {
    let files = try ImageTestFiles()
    defer { files.remove() }
    let input = try files.write()
    let output = files.url("absent.png")
    let invalidOptions = [
        ImageConvertOptions(quality: -0.1), ImageConvertOptions(quality: 1.1), ImageConvertOptions(quality: .nan),
        ImageConvertOptions(maxPixelSize: 0), ImageConvertOptions(maxPixelSize: -1),
        ImageConvertOptions(background: ImageBackground(red: .infinity, green: 0, blue: 0))
    ]
    for options in invalidOptions {
        #expect(throws: ImageEngineError.self) {
            try ImageEngine.convert(input, to: .png, options: options, output: output)
        }
    }
    #expect(throws: ImageEngineError.self) { try ImageEngine.info(files.url("missing.png")) }
    let invalid = files.url("invalid.png")
    try Data("not an image".utf8).write(to: invalid)
    do {
        try ImageEngine.convert(invalid, to: .png, options: ImageConvertOptions(), output: output)
        Issue.record("Invalid image unexpectedly converted")
    } catch let error as ImageEngineError {
        #expect(!error.localizedDescription.isEmpty)
        #expect(!error.detail.isEmpty)
    }
    #expect(throws: ImageEngineError.self) { try ImageEngine.makeIcon(input, format: .png, output: output) }
    for format in ImageFormat.allCases where !ImageEngine.writableFormats().contains(format) {
        #expect(throws: ImageEngineError.self) {
            try ImageEngine.convert(input, to: format, options: ImageConvertOptions(), output: output)
        }
    }
    #expect(throws: ImageEngineError.self) {
        try ImageEngine.convert(input, to: .png, options: ImageConvertOptions(), output: files.url("missing/output.png"))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}
