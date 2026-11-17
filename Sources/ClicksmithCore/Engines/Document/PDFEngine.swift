import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum ImageKind: String, Codable, Sendable, CaseIterable { case png, jpeg }
public enum PDFPageSize: String, Codable, Sendable, CaseIterable { case fit, a4, letter }

/// Native PDFKit image policies. Text, vector content and annotations remain editable.
public enum PDFCompressionQuality: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    var options: [PDFDocumentWriteOption: Any] {
        switch self {
        case .low: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        case .medium: [.optimizeImagesForScreenOption: true]
        case .high: [.saveImagesAsJPEGOption: true]
        }
    }
}

public enum PDFEngine {
    public static func pagesToImages(_ pdf: URL, format: ImageKind, dpi: Int = 150, outputDirectory: URL,
                                     progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [URL] {
        try DocumentIO.checked {
            guard (1...1200).contains(dpi) else { throw PowerError.badInput("DPI must be between 1 and 1200.") }
            try DocumentIO.requireFileURL(pdf)
            try DocumentIO.checkCancellation(isCancelled)
            guard let document = CGPDFDocument(pdf as CFURL), !document.isEncrypted || document.isUnlocked, document.numberOfPages > 0 else {
                throw PowerError.badInput("The PDF is invalid, empty, or password locked.")
            }
            progress(0)
            return try DocumentIO.batch(outputDirectory, isCancelled: isCancelled) { stage in
                var outputs: [URL] = []
                for n in 1...document.numberOfPages {
                    try DocumentIO.checkCancellation(isCancelled)
                    let output = stage.appendingPathComponent(pageName(n, ext: format.rawValue))
                    try autoreleasepool {
                        guard let page = document.page(at: n) else { throw PowerError.failed("Could not read PDF page \(n).") }
                        let box = page.getBoxRect(.cropBox)
                        let rotated = abs(page.rotationAngle) % 180 == 90
                        let width = ceil((rotated ? box.height : box.width) * Double(dpi) / 72)
                        let height = ceil((rotated ? box.width : box.height) * Double(dpi) / 72)
                        guard width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 40_000_000 else {
                            throw PowerError.badInput("This PDF page is too large to rasterize. Use a lower DPI.")
                        }
                        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                            throw PowerError.failed("Could not allocate a PDF page image.")
                        }
                        let rect = CGRect(x: 0, y: 0, width: width, height: height)
                        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
                        // getDrawingTransform fits a page but does not enlarge it.
                        // Map the cropped PDF coordinates explicitly, including clockwise /Rotate.
                        let rotation = (Int(page.rotationAngle) % 360 + 360) % 360
                        let transform: CGAffineTransform
                        switch rotation {
                        case 90: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
                        case 180: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.maxX, ty: box.maxY)
                        case 270: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
                        default: transform = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                        }
                        context.scaleBy(x: CGFloat(dpi) / 72, y: CGFloat(dpi) / 72)
                        context.concatenate(transform)
                        context.drawPDFPage(page)
                        try DocumentIO.checkCancellation(isCancelled)
                        guard let image = context.makeImage(),
                              let destination = CGImageDestinationCreateWithURL(output as CFURL, (format == .png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else {
                            throw PowerError.failed("Could not encode the PDF page image.")
                        }
                        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                                                       kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                        guard CGImageDestinationFinalize(destination) else { throw PowerError.failed("Could not save the PDF page image.") }
                    }
                    outputs.append(output); progress(Double(n) / Double(document.numberOfPages))
                }
                return outputs
            }
        }
    }

    public static func text(_ pdf: URL, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> String {
        try DocumentIO.checked {
            try DocumentIO.checkCancellation(isCancelled)
            let doc = try open(pdf)
            var pages: [String] = []
            progress(0)
            for n in 0..<doc.pageCount {
                try DocumentIO.checkCancellation(isCancelled)
                guard let page = doc.page(at: n) else { throw PowerError.failed("Could not read a PDF page.") }
                pages.append(page.string ?? "")
                progress(Double(n + 1) / Double(doc.pageCount))
            }
            try DocumentIO.checkCancellation(isCancelled)
            return pages.joined(separator: "\n\u{000c}\n")
        }
    }

    public static func merge(_ pdfs: [URL], output: URL, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        try DocumentIO.checked {
            guard !pdfs.isEmpty else { throw PowerError.badInput("Select at least one PDF.") }
            try DocumentIO.single(output, isCancelled: isCancelled) { scratch in
                let result = PDFDocument(), root = PDFOutline()
                progress(0)
                for (index, url) in pdfs.enumerated() {
                    try DocumentIO.checkCancellation(isCancelled)
                    let source = try open(url)
                    let start = result.pageCount
                    for n in 0..<source.pageCount {
                        try DocumentIO.checkCancellation(isCancelled)
                        guard let page = source.page(at: n)?.copy() as? PDFPage else { throw PowerError.failed("Could not copy a PDF page.") }
                        result.insert(page, at: result.pageCount)
                        progress((Double(index) + Double(n + 1) / Double(source.pageCount)) / Double(pdfs.count))
                    }
                    let bookmark = PDFOutline()
                    root.insertChild(bookmark, at: root.numberOfChildren)
                    bookmark.label = url.deletingPathExtension().lastPathComponent
                    if let first = result.page(at: start) { bookmark.destination = PDFDestination(page: first, at: first.bounds(for: .cropBox).origin) }
                    if let outline = source.outlineRoot {
                        for n in 0..<outline.numberOfChildren {
                            if let child = outline.child(at: n) { try copyOutline(child, into: bookmark, source: source, result: result, offset: start, isCancelled: isCancelled) }
                        }
                    }
                }
                result.outlineRoot = root
                try DocumentIO.checkCancellation(isCancelled)
                guard result.write(to: scratch) else { throw PowerError.failed("Could not write the merged PDF.") }
            }
        }
    }

    public static func split(_ pdf: URL, outputDirectory: URL, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [URL] {
        try DocumentIO.checked {
            try DocumentIO.checkCancellation(isCancelled)
            let source = try open(pdf)
            progress(0)
            return try DocumentIO.batch(outputDirectory, isCancelled: isCancelled) { stage in
                var outputs: [URL] = []
                for n in 0..<source.pageCount {
                    try DocumentIO.checkCancellation(isCancelled)
                    let output = stage.appendingPathComponent(pageName(n + 1, ext: "pdf"))
                    try autoreleasepool {
                        guard let page = source.page(at: n)?.copy() as? PDFPage else { throw PowerError.failed("Could not copy a PDF page.") }
                        let document = PDFDocument(); document.insert(page, at: 0)
                        document.documentAttributes = source.documentAttributes
                        guard document.write(to: output) else { throw PowerError.failed("Could not write a split PDF page.") }
                    }
                    outputs.append(output); progress(Double(n + 1) / Double(source.pageCount))
                }
                return outputs
            }
        }
    }

    public static func imagesToPDF(_ images: [URL], output: URL, pageSize: PDFPageSize = .fit,
                                   progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        try DocumentIO.checked {
            guard !images.isEmpty else { throw PowerError.badInput("Select at least one image.") }
            try DocumentIO.single(output, isCancelled: isCancelled) { scratch in
                guard let consumer = CGDataConsumer(url: scratch as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
                    throw PowerError.failed("Could not create the image PDF.")
                }
                defer { context.closePDF() }
                progress(0)
                for (index, url) in images.enumerated() {
                    try DocumentIO.checkCancellation(isCancelled)
                    try DocumentIO.requireFileURL(url)
                    try autoreleasepool {
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                              let width = properties[kCGImagePropertyPixelWidth] as? Double,
                              let height = properties[kCGImagePropertyPixelHeight] as? Double,
                              width > 0, height > 0, width * height <= 40_000_000,
                              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                                                       kCGImageSourceThumbnailMaxPixelSize: max(width, height)] as CFDictionary) else {
                            throw PowerError.badInput("Could not decode the image: \(url.lastPathComponent).")
                        }
                        let size: CGSize
                        switch pageSize {
                        case .fit: size = CGSize(width: image.width, height: image.height)
                        case .a4: size = CGSize(width: 595.28, height: 841.89)
                        case .letter: size = CGSize(width: 612, height: 792)
                        }
                        var box = CGRect(origin: .zero, size: size)
                        let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
                        let content = pageSize == .fit ? box : box.insetBy(dx: 36, dy: 36)
                        let scale = min(content.width / CGFloat(image.width), content.height / CGFloat(image.height))
                        let rect = CGRect(x: content.midX - CGFloat(image.width) * scale / 2, y: content.midY - CGFloat(image.height) * scale / 2,
                                          width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                        context.draw(image, in: rect)
                        context.endPDFPage()
                    }
                    progress(Double(index + 1) / Double(images.count))
                }
            }
        }
    }

    public static func compress(_ pdf: URL, quality: PDFCompressionQuality, output: URL,
                                progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> (before: Int64, after: Int64) {
        try DocumentIO.checked {
            try DocumentIO.checkCancellation(isCancelled)
            let source = try open(pdf)
            let original = try Data(contentsOf: pdf)
            var after = Int64(original.count)
            progress(0)
            try DocumentIO.single(output, isCancelled: isCancelled) { scratch in
                // A loaded PDF can be written by reusing its original byte stream,
                // bypassing image optimization. Rebuild its page tree first.
                let document = PDFDocument()
                document.documentAttributes = source.documentAttributes
                for index in 0..<source.pageCount {
                    try DocumentIO.checkCancellation(isCancelled)
                    guard let page = source.page(at: index)?.copy() as? PDFPage else { throw PowerError.failed("Could not copy a PDF page.") }
                    document.insert(page, at: document.pageCount)
                    progress(0.8 * Double(index + 1) / Double(source.pageCount))
                }
                if let outline = source.outlineRoot {
                    let root = PDFOutline(); document.outlineRoot = root
                    for index in 0..<outline.numberOfChildren {
                        if let child = outline.child(at: index) { try copyOutline(child, into: root, source: source, result: document, offset: 0, isCancelled: isCancelled) }
                    }
                }
                try DocumentIO.checkCancellation(isCancelled)
                guard document.write(to: scratch, withOptions: quality.options) else { throw PowerError.failed("Could not compress the PDF.") }
                try DocumentIO.checkCancellation(isCancelled)
                let size = try scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                if size >= original.count { try original.write(to: scratch) }
                else { after = Int64(size) }
                progress(1)
            }
            return (Int64(original.count), after)
        }
    }

    public static func info(_ pdf: URL) throws -> (pages: Int, title: String?, encrypted: Bool) {
        try DocumentIO.checked {
            try DocumentIO.requireFileURL(pdf)
            guard let document = PDFDocument(url: pdf) else { throw PowerError.badInput("This file is not a readable PDF.") }
            return (document.pageCount, document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, document.isEncrypted)
        }
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        try DocumentIO.requireFileURL(url)
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw PowerError.badInput("The PDF is invalid, empty, or password locked.")
        }
        return document
    }

    private static func pageName(_ page: Int, ext: String) -> String { String(format: "page-%03d.%@", page, ext) }

    private static func copyOutline(_ outline: PDFOutline, into parent: PDFOutline, source: PDFDocument, result: PDFDocument, offset: Int,
                                    isCancelled: () -> Bool) throws {
        try DocumentIO.checkCancellation(isCancelled)
        let copy = PDFOutline(); copy.label = outline.label
        // PDFKit ignores destination assignments while an outline has no parent.
        parent.insertChild(copy, at: parent.numberOfChildren)
        if let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination, let page = destination.page {
            let index = source.index(for: page)
            if index != NSNotFound, let target = result.page(at: offset + index) {
                let mapped = PDFDestination(page: target, at: destination.point); mapped.zoom = destination.zoom
                copy.destination = mapped
            }
        } else if let action = outline.action?.copy() as? PDFAction { copy.action = action }
        for index in 0..<outline.numberOfChildren {
            if let child = outline.child(at: index) { try copyOutline(child, into: copy, source: source, result: result, offset: offset, isCancelled: isCancelled) }
        }
        copy.isOpen = outline.isOpen
    }
}
