import CoreGraphics
import Foundation
import ImageIO

/// Holds a decoder or PDF document, never a collection of decoded page bitmaps.
struct ImageInput {
    private enum Storage {
        case image(CGImageSource)
        case pdf(CGPDFDocument)
    }

    private let storage: Storage
    let typeIdentifier: String

    init(_ url: URL) throws {
        guard url.isFileURL else { throw ImageEngineError.invalidInput(url.absoluteString) }
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String?, type != "com.adobe.pdf" {
            storage = .image(source)
            typeIdentifier = type
        } else if ImageEngine.isPDF(url), let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
                  !document.isEncrypted || document.isUnlocked {
            storage = .pdf(document)
            typeIdentifier = "com.adobe.pdf"
        } else {
            throw ImageEngineError.invalidInput(url.absoluteString)
        }
    }

    var count: Int {
        switch storage {
        case .image(let source): CGImageSourceGetCount(source)
        case .pdf(let document): document.numberOfPages
        }
    }

    var isIcon: Bool { typeIdentifier == "com.microsoft.ico" || typeIdentifier == "com.apple.icns" }
    var isDocument: Bool { typeIdentifier == "public.tiff" || typeIdentifier == "com.adobe.pdf" }

    var containerProperties: [String: Any] {
        guard case .image(let source) = storage else { return [:] }
        return CGImageSourceCopyProperties(source, nil) as? [String: Any] ?? [:]
    }

    var isAnimation: Bool {
        guard count > 1, !isIcon, !isDocument else { return false }
        if containerProperties["CanAnimate"] as? Bool == true { return true }
        if typeIdentifier == "com.compuserve.gif" || typeIdentifier == "public.heics" { return true }
        if typeIdentifier == "public.png",
           let png = properties(at: 0)[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            return png[kCGImagePropertyAPNGDelayTime as String] != nil ||
                png[kCGImagePropertyAPNGUnclampedDelayTime as String] != nil
        }
        return false
    }

    var primaryIndex: Int {
        guard case .image(let source) = storage else { return 0 }
        if isIcon {
            return (0..<count).max {
                (properties(at: $0)[kCGImagePropertyPixelWidth as String] as? Int ?? 0) <
                    (properties(at: $1)[kCGImagePropertyPixelWidth as String] as? Int ?? 0)
            } ?? 0
        }
        return min(CGImageSourceGetPrimaryImageIndex(source), count - 1)
    }

    var frameCount: Int { isAnimation || isDocument ? count : 1 }

    func indices(for format: ImageFormat) -> [Int] {
        if isAnimation && [.gif, .png, .heic, .tiff, .pdf].contains(format) { return Array(0..<count) }
        if isDocument && [.tiff, .pdf].contains(format) { return Array(0..<count) }
        return [primaryIndex]
    }

    func properties(at index: Int) -> [String: Any] {
        switch storage {
        case .image(let source):
            return CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        case .pdf(let document):
            guard let page = document.page(at: index + 1),
                  let size = try? ImageEngine.pdfPixelSize(page, maxPixelSize: nil) else { return [:] }
            return [kCGImagePropertyPixelWidth as String: Int(size.width),
                    kCGImagePropertyPixelHeight as String: Int(size.height),
                    kCGImagePropertyDPIWidth as String: ImageEngine.pdfDPI,
                    kCGImagePropertyDPIHeight as String: ImageEngine.pdfDPI,
                    kCGImagePropertyColorModel as String: "RGB", kCGImagePropertyHasAlpha as String: false]
        }
    }

    func image(at index: Int, maxPixelSize: Int?) throws -> CGImage {
        switch storage {
        case .image(let source):
            return try ImageEngine.decodedImage(source, index: index, maxPixelSize: maxPixelSize)
        case .pdf(let document):
            guard let page = document.page(at: index + 1) else { throw ImageEngineError.invalidInput("Missing PDF page.") }
            return try ImageEngine.pdfImage(page, maxPixelSize: maxPixelSize)
        }
    }
}
