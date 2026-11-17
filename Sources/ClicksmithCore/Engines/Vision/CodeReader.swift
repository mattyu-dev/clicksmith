import CoreGraphics
import Foundation
import Vision

public struct DetectedCode: Sendable, Equatable {
    public let payloadString: String
    public let symbology: VNBarcodeSymbology
    /// Normalized coordinates with the origin at the lower left of the oriented image or PDF page.
    public let bounds: CGRect

    public init(payloadString: String, symbology: VNBarcodeSymbology, bounds: CGRect) {
        self.payloadString = payloadString; self.symbology = symbology; self.bounds = bounds
    }
}

public extension CodeReader {
    static func read(image: URL, progress: (Double) -> Void = { _ in },
                     isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [DetectedCode] {
        try VisionIO.typed("Could not read codes from this image.") {
            try VisionIO.check(isCancelled)
            progress(0)
            let result = try read(cgImage: VisionIO.image(image), isCancelled: isCancelled)
            progress(1)
            return result
        }
    }

    static func read(cgImage: CGImage, progress: (Double) -> Void = { _ in },
                     isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [DetectedCode] {
        try VisionIO.typed("Could not read codes from this image.") {
            try VisionIO.check(isCancelled)
            try VisionIO.validateDimensions(width: cgImage.width, height: cgImage.height)
            progress(0)
            let request = VNDetectBarcodesRequest()
            request.symbologies = try request.supportedSymbologies()
            try VisionIO.perform(request, handler: VNImageRequestHandler(cgImage: cgImage), isCancelled: isCancelled)
            let codes = (request.results ?? []).compactMap { observation -> DetectedCode? in
                guard let payload = observation.payloadStringValue else { return nil }
                return DetectedCode(payloadString: payload, symbology: observation.symbology, bounds: observation.boundingBox)
            }
            progress(1)
            return codes
        }
    }

    static func read(pdf: URL, dpi: Int = 200, progress: (Double) -> Void = { _ in },
                     isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> [DetectedCode] {
        try VisionIO.typed("Could not read codes from this PDF.") {
            try VisionIO.check(isCancelled)
            guard (1...1_200).contains(dpi) else { throw PowerError.badInput("Choose a PDF resolution between 1 and 1200 DPI.") }
            let document = try VisionIO.pdf(pdf)
            progress(0)
            var codes: [DetectedCode] = []
            for index in 0..<document.pageCount {
                try VisionIO.check(isCancelled)
                try autoreleasepool {
                    guard let page = document.page(at: index) else { throw PowerError.failed("Could not read PDF page \(index + 1).") }
                    let image = try VisionIO.render(page, dpi: dpi)
                    codes += try read(cgImage: image, isCancelled: isCancelled)
                }
                progress(Double(index + 1) / Double(document.pageCount))
            }
            try VisionIO.check(isCancelled)
            return codes
        }
    }
}
