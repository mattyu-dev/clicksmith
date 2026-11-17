import CoreGraphics
import Darwin
import Foundation
import ImageIO

public enum ImageEngine {
    /// Enumeration only. Native codecs can hang while encoding, so discovery never invokes them.
    public static func writableFormats() -> [ImageFormat] {
        let native = nativeWriters()
        return ImageFormat.allCases.filter { $0 == .ico || $0 == .icns || native.contains($0.typeIdentifier) }
    }

    public static func readableTypes() -> [String] {
        var types = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        if !types.contains("com.adobe.pdf") { types.append("com.adobe.pdf") }
        return types
    }

    /// The caller chooses a new path and journals the created output. Existing files are never replaced.
    public static func convert(_ input: URL, to format: ImageFormat,
                               options: ImageConvertOptions, output: URL) throws {
        try validate(options)
        try validateOutput(output)
        guard writableFormats().contains(format) else { throw ImageEngineError.unsupportedFormat(format) }
        let source = try ImageInput(input)
        try produce(output: output, format: format) { scratch in
            if format == .ico || format == .icns {
                try iconData(source, format: format, options: options).write(to: scratch, options: .withoutOverwriting)
            } else {
                try encode(source, format: format, options: options, output: scratch)
            }
        }
    }

    /// Retains the input format. PDF/TIFF pages stay pages; still HEIF collections use their primary image.
    public static func resize(_ input: URL, maxPixelSize: Int, output: URL) throws {
        let identifier = try ImageInput(input).typeIdentifier
        guard let format = ImageFormat.allCases.first(where: { $0.typeIdentifier == identifier }) ??
                (identifier == "public.heics" ? .heic : nil) else {
            throw ImageEngineError.invalidInput("No output format for \(identifier).")
        }
        try convert(input, to: format, options: ImageConvertOptions(maxPixelSize: maxPixelSize), output: output)
    }

    public static func makeIcon(_ input: URL, format: ImageFormat, output: URL) throws {
        guard format == .ico || format == .icns else {
            throw ImageEngineError.invalidOptions("makeIcon accepts only ico or icns.")
        }
        try convert(input, to: format, options: ImageConvertOptions(), output: output)
    }

    public static func info(_ url: URL) throws -> ImageInfo {
        let source = try ImageInput(url)
        let properties = source.properties(at: source.primaryIndex)
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else {
            throw ImageEngineError.invalidInput("Missing pixel dimensions in \(url.path).")
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        return ImageInfo(
            pixelWidth: width, pixelHeight: height,
            dpiWidth: properties[kCGImagePropertyDPIWidth as String] as? Double,
            dpiHeight: properties[kCGImagePropertyDPIHeight as String] as? Double,
            colorModel: properties[kCGImagePropertyColorModel as String] as? String,
            hasAlpha: properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false,
            exifDate: exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            cameraMake: tiff?[kCGImagePropertyTIFFMake as String] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel as String] as? String,
            frameCount: source.frameCount
        )
    }

    private static func nativeWriters() -> Set<String> {
        Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
    }

    private static func properties(_ source: CGImageSource, index: Int) -> [String: Any] {
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
    }

    private static func validate(_ options: ImageConvertOptions) throws {
        if let quality = options.quality, !quality.isFinite || !(0...1).contains(quality) {
            throw ImageEngineError.invalidOptions("Quality must be finite and in 0...1.")
        }
        if let size = options.maxPixelSize, size <= 0 {
            throw ImageEngineError.invalidOptions("maxPixelSize must be positive.")
        }
        for component in [options.background.red, options.background.green, options.background.blue] {
            guard component.isFinite, (0...1).contains(component) else {
                throw ImageEngineError.invalidOptions("Background RGB components must be finite and in 0...1.")
            }
        }
    }

    private static func validateOutput(_ output: URL) throws {
        guard output.isFileURL else { throw ImageEngineError.invalidOptions("Output must be a file URL.") }
        if (try? FileManager.default.attributesOfItem(atPath: output.path)) != nil {
            throw ImageEngineError.outputExists(output.path)
        }
    }

    /// Same-volume staging, like FileOps.produce. Publish with an exclusive rename, including on exFAT.
    /// A failed encoder leaves neither a partial output nor a scratch directory behind.
    static func produce(output: URL, format: ImageFormat, writer: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let directory = output.deletingLastPathComponent().appendingPathComponent(".clicksmith-image-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ImageEngineError.writeFailed("\(output.path): \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: directory) }
        let scratch = directory.appendingPathComponent("output.\(format.rawValue)")
        do {
            try writer(scratch)
            try publish(scratch, to: output)
        } catch let error as ImageEngineError {
            throw error
        } catch {
            throw ImageEngineError.writeFailed("\(output.path): \(error.localizedDescription)")
        }
    }

    static func publish(_ scratch: URL, to output: URL) throws {
        guard renamex_np(scratch.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw ImageEngineError.outputExists(output.path) }
            throw ImageEngineError.writeFailed("\(output.path): \(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))")
        }
    }

    private static func encode(_ source: ImageInput, format: ImageFormat,
                               options: ImageConvertOptions, output: URL) throws {
        let indices = source.indices(for: format)
        let sequence = format == .heic && source.isAnimation && indices.count > 1 && nativeWriters().contains("public.heics")
        let identifier = sequence ? "public.heics" : format.typeIdentifier
        let selected = format == .heic && !sequence ? [source.primaryIndex] : indices
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, identifier as CFString, selected.count, nil) else {
            throw ImageEngineError.encodingFailed("Cannot create \(identifier) destination with \(selected.count) frames.")
        }
        var containerProperties: [String: Any] = [:]
        if source.isAnimation, let keys = animationKeys(format), let loop = animationLoop(source.containerProperties) {
            containerProperties[keys.dictionary] = [keys.loop: loop]
        }
        CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
        for index in selected {
            try autoreleasepool {
                var image = try source.image(at: index, maxPixelSize: options.maxPixelSize)
                let original = source.properties(at: index)
                let sourceAlpha = original[kCGImagePropertyHasAlpha as String] as? Bool ?? hasAlpha(image)
                let keepProfile = options.keepColorProfile && ![.bmp, .gif, .jp2].contains(format)
                // HEIF/AVIF thumbnail providers can be drawable but not directly consumable by
                // another ImageIO encoder. Materialize their pixels in a bitmap context first.
                let materialize = ["public.heic", "public.heics", "public.heif", "public.avif", "public.avis"].contains(source.typeIdentifier)
                if materialize || !keepProfile || format == .jpeg || (!sourceAlpha && hasAlpha(image)) {
                    image = try rendered(image, keepColorProfile: keepProfile,
                                         background: format == .jpeg ? options.background : nil,
                                         preserveAlpha: sourceAlpha)
                }
                var outputProperties = options.stripMetadata ? [:] : original
                outputProperties[kCGImagePropertyOrientation as String] = 1
                outputProperties[kCGImagePropertyPixelWidth as String] = image.width
                outputProperties[kCGImagePropertyPixelHeight as String] = image.height
                outputProperties[kCGImagePropertyHasAlpha as String] = hasAlpha(image)
                if var tiff = outputProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                    tiff[kCGImagePropertyTIFFOrientation as String] = 1
                    outputProperties[kCGImagePropertyTIFFDictionary as String] = tiff
                }
                if var exif = outputProperties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                    exif[kCGImagePropertyExifPixelXDimension as String] = image.width
                    exif[kCGImagePropertyExifPixelYDimension as String] = image.height
                    outputProperties[kCGImagePropertyExifDictionary as String] = exif
                }
                if !keepProfile { outputProperties.removeValue(forKey: kCGImagePropertyProfileName as String) }
                if let quality = options.quality { outputProperties[kCGImageDestinationLossyCompressionQuality as String] = quality }
                if source.isAnimation, let keys = animationKeys(format), let delay = animationDelay(original) {
                    outputProperties[keys.dictionary] = [keys.delay: delay, keys.unclampedDelay: delay]
                }
                CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEngineError.encodingFailed("ImageIO could not finalize \(identifier).")
        }
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func decodedImage(_ source: CGImageSource, index: Int, maxPixelSize: Int?) throws -> CGImage {
        let properties = properties(source, index: index)
        guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int, width > 0, height > 0 else {
            throw ImageEngineError.invalidInput("Missing dimensions in frame \(index).")
        }
        let bound = min(maxPixelSize ?? max(width, height), max(width, height))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bound,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions as CFDictionary) else {
            throw ImageEngineError.invalidInput("ImageIO could not decode frame \(index).")
        }
        return image
    }

    static func rendered(_ image: CGImage, keepColorProfile: Bool, background: ImageBackground? = nil,
                         canvasSize: Int? = nil, preserveAlpha: Bool? = nil) throws -> CGImage {
        let width = canvasSize ?? image.width
        let height = canvasSize ?? image.height
        let colorSpace = keepColorProfile && image.colorSpace?.model == .rgb ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        let retainAlpha = preserveAlpha ?? (hasAlpha(image) || canvasSize != nil)
        let alpha = background == nil && retainAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: alpha.rawValue) else {
            throw ImageEngineError.encodingFailed("Cannot allocate \(width)x\(height) RGB bitmap.")
        }
        if let background {
            context.setFillColor(red: background.red, green: background.green, blue: background.blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawWidth = Double(image.width) * scale
        let drawHeight = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(width) - drawWidth) / 2,
                                       y: (Double(height) - drawHeight) / 2, width: drawWidth, height: drawHeight))
        guard let result = context.makeImage() else { throw ImageEngineError.encodingFailed("Cannot create rendered bitmap.") }
        return result
    }

    private static func animationKeys(_ format: ImageFormat)
        -> (dictionary: String, loop: String, delay: String, unclampedDelay: String)? {
        switch format {
        case .gif:
            (kCGImagePropertyGIFDictionary as String, kCGImagePropertyGIFLoopCount as String,
             kCGImagePropertyGIFDelayTime as String, kCGImagePropertyGIFUnclampedDelayTime as String)
        case .png:
            (kCGImagePropertyPNGDictionary as String, kCGImagePropertyAPNGLoopCount as String,
             kCGImagePropertyAPNGDelayTime as String, kCGImagePropertyAPNGUnclampedDelayTime as String)
        case .heic:
            (kCGImagePropertyHEICSDictionary as String, kCGImagePropertyHEICSLoopCount as String,
             kCGImagePropertyHEICSDelayTime as String, kCGImagePropertyHEICSUnclampedDelayTime as String)
        default: nil
        }
    }

    private static func animationDelay(_ properties: [String: Any]) -> Double? {
        for format in [ImageFormat.gif, .png, .heic] {
            if let keys = animationKeys(format), let values = properties[keys.dictionary] as? [String: Any],
               let delay = number(values[keys.unclampedDelay]) ?? number(values[keys.delay]) { return delay }
        }
        return nil
    }

    private static func animationLoop(_ properties: [String: Any]) -> Int? {
        for format in [ImageFormat.gif, .png, .heic] {
            if let keys = animationKeys(format), let values = properties[keys.dictionary] as? [String: Any],
               let loop = number(values[keys.loop]).map({ Int($0) }) { return loop }
        }
        return nil
    }

    /// ImageIO returns HEICS timing as a string ("0.4"), GIF/APNG as NSNumber. Accept both.
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}
