import CoreGraphics
import Foundation

extension ImageEngine {
    static let pdfDPI = 200.0

    static func isPDF(_ input: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: input) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 1024) else { return false }
        return prefix.range(of: Data("%PDF-".utf8)) != nil
    }

    static func pdfPageSize(_ page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    static func pdfPixelSize(_ page: CGPDFPage, maxPixelSize: Int?) throws -> CGSize {
        let size = pdfPageSize(page)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw ImageEngineError.invalidInput("PDF page has invalid dimensions.")
        }
        let scale = maxPixelSize.map { Double($0) / max(size.width, size.height) } ?? (pdfDPI / 72)
        let width = max(1, ceil(size.width * scale))
        let height = max(1, ceil(size.height * scale))
        guard width < Double(Int32.max), height < Double(Int32.max) else {
            throw ImageEngineError.invalidOptions("PDF raster dimensions are too large.")
        }
        return CGSize(width: width, height: height)
    }

    /// Decode only the requested page, directly into its final raster size.
    static func pdfImage(_ page: CGPDFPage, maxPixelSize: Int?) throws -> CGImage {
        let size = try pdfPixelSize(page, maxPixelSize: maxPixelSize)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageEngineError.encodingFailed("Cannot allocate PDF page bitmap.")
        }
        let rect = CGRect(origin: .zero, size: size)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(rect)
        context.concatenate(PDFRasterTransform.make(page, pixelSize: size))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ImageEngineError.encodingFailed("Cannot render PDF page.") }
        return image
    }
}

/// Explicitly scales PDF points into the requested pixels. Core Graphics' fitting
/// transform does not enlarge a 72 DPI page to fill a higher-resolution bitmap.
enum PDFRasterTransform {
    static func make(_ page: CGPDFPage, pixelSize: CGSize) -> CGAffineTransform {
        let box = page.getBoxRect(.cropBox)
        let rotation = (Int(page.rotationAngle) % 360 + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let transform: CGAffineTransform
        switch rotation {
        case 90: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
        case 180: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.maxX, ty: box.maxY)
        case 270: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
        default: transform = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        }
        return transform.concatenating(CGAffineTransform(scaleX: pixelSize.width / size.width,
                                                        y: pixelSize.height / size.height))
    }
}
