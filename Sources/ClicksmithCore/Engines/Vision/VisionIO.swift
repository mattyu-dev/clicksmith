import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import Darwin

/// Shared validation, rendering and exclusive output publication for this engine.
enum VisionIO {
    static func check(_ isCancelled: () -> Bool) throws {
        if isCancelled() || Task.isCancelled { throw PowerError.cancelled }
    }

    static func typed<T>(_ message: String, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as PowerError { throw error }
        catch { throw PowerError.failed(message, detail: error.localizedDescription) }
    }

    static func image(_ url: URL) throws -> CGImage {
        guard url.isFileURL else { throw PowerError.badInput("Choose a local image file.") }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw PowerError.badInput("This file could not be read as an image.")
        }
        guard width > 0, height > 0 else { throw PowerError.badInput("This image has invalid dimensions.") }
        // Bound the decode itself, including 48 MP phone photos, without touching the source.
        let longest = Double(max(width, height))
        let scale = min(1, 16_000 / longest, sqrt(40_000_000 / Double(width) / Double(height)))
        let maxPixelSize = max(1, Int(floor(longest * scale)))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PowerError.badInput("This image could not be decoded.")
        }
        try validateDimensions(width: image.width, height: image.height)
        return image
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16_000, height <= 16_000, width <= 40_000_000 / height else {
            throw PowerError.unsupported("Images must have at most 40 million pixels and 16,000 pixels per side.")
        }
    }

    static func pdf(_ url: URL) throws -> PDFDocument {
        guard url.isFileURL, let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw PowerError.badInput("Choose a readable, unlocked PDF with at least one page.")
        }
        return document
    }

    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        guard (1...1_200).contains(dpi), let ref = page.pageRef else { throw PowerError.badInput("Choose a PDF resolution between 1 and 1200 DPI.") }
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let w = ceil((rotated ? box.height : box.width) * Double(dpi) / 72)
        let h = ceil((rotated ? box.width : box.height) * Double(dpi) / 72)
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 16_000, h <= 16_000 else { throw PowerError.unsupported("This PDF page is too large to render at this resolution.") }
        let width = Int(w), height = Int(h)
        try validateDimensions(width: width, height: height)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PowerError.failed("Could not allocate a PDF page image.")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
        ctx.concatenate(PDFRasterTransform.make(ref, pixelSize: CGSize(width: width, height: height)))
        ctx.drawPDFPage(ref)
        guard let image = ctx.makeImage() else { throw PowerError.failed("Could not render this PDF page.") }
        return image
    }

    static func perform(_ request: VNRequest, handler: VNImageRequestHandler,
                        isCancelled: @escaping @Sendable () -> Bool) throws {
        try check(isCancelled)
        try withUnsafeCurrentTask { currentTask in
            let watcher = VisionRequestCancellation(request: request, currentTask: currentTask, isCancelled: isCancelled)
            // Join the watcher before the unsafe task reference's valid scope ends.
            defer { watcher.stop() }
            do { try handler.perform([request]) }
            catch {
                if watcher.didCancel || isCancelled() || Task.isCancelled { throw PowerError.cancelled }
                throw PowerError.failed("Vision could not process this image.", detail: error.localizedDescription)
            }
            if watcher.didCancel { throw PowerError.cancelled }
            try check(isCancelled)
        }
    }

    static func png(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw PowerError.failed("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PowerError.failed("Could not encode the PNG image.") }
        return bytes as Data
    }

    /// Write in an owned sibling file, then use RENAME_EXCL to publish complete bytes.
    /// Existing files, directories and symlinks are never replaced, even on a race.
    static func write(_ data: Data, to output: URL, isCancelled: () -> Bool) throws {
        try check(isCancelled)
        guard output.isFileURL else { throw PowerError.badInput("Choose a local output file.") }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".clicksmith-vision-\(UUID().uuidString)")
        // Let open apply the process umask without changing that process-wide setting.
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o666)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlink(staging.path) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let finalMode = attributes.st_mode & 0o666
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try check(isCancelled)
                let n = Darwin.write(fd, base.advanced(by: offset), min(65_536, buffer.count - offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += n
            }
        }
        try check(isCancelled)
        guard fchmod(fd, finalMode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard renamex_np(staging.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// Only VNRequest.cancel() and UnsafeCurrentTask.isCancelled cross queues.
/// The task reference is valid until `stop()` drains the queue inside withUnsafeCurrentTask.
private final class VisionRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let currentTask: UnsafeCurrentTask?
    private let request: VNRequest

    var didCancel: Bool { lock.withLock { cancelled } }

    init(request: VNRequest, currentTask: UnsafeCurrentTask?, isCancelled: @escaping @Sendable () -> Bool) {
        self.request = request
        self.currentTask = currentTask
        let queue = DispatchQueue(label: "Clicksmith.VisionCancellation")
        self.queue = queue
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.currentTask?.isCancelled == true || isCancelled() {
                self.lock.withLock { self.cancelled = true }
                self.request.cancel()
            }
        }
        timer.resume()
    }

    func stop() {
        timer.cancel()
        queue.sync { }
    }
}
