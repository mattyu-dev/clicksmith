import CoreImage
import Foundation
import Vision

public enum BackgroundRemover {
    public static func removeBackground(_ input: URL, output: URL, progress: (Double) -> Void = { _ in },
                                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        try VisionIO.typed("Could not remove this image's background.") {
            try VisionIO.check(isCancelled)
            progress(0)
            let image = try VisionIO.image(input)
            let handler = VNImageRequestHandler(cgImage: image)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try VisionIO.perform(request, handler: handler, isCancelled: isCancelled)
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw PowerError.badInput("No foreground subject was found in this image.")
            }
            progress(0.7)
            try VisionIO.check(isCancelled)
            let pixels = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
            try VisionIO.check(isCancelled)
            let masked = CIImage(cvPixelBuffer: pixels)
            guard let result = CIContext().createCGImage(masked, from: masked.extent) else { throw PowerError.failed("Could not render the foreground image.") }
            let data = try VisionIO.png(result)
            try VisionIO.write(data, to: output, isCancelled: isCancelled)
            progress(1)
        }
    }
}
