import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Only exposes AVFoundation's cancellation entry point across tasks. Image requests
/// and generator configuration stay on the operation's task.
private final class MediaImageCancellation: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(_ generator: AVAssetImageGenerator) { self.generator = generator }
    func cancel() { generator.cancelAllCGImageGeneration() }
}

extension MediaEngine {
    /// ImageIO retains GIF frames until finalize. Long clips lower their sampling
    /// frame rate to fit this limit while preserving the complete requested duration.
    public static let maximumGIFFrames = 300

    static func gifFramePlan(duration: Double, fps: Int) -> (count: Int, interval: Double) {
        let requested = duration * Double(fps)
        let count = max(1, Int(min(Double(maximumGIFFrames), ceil(requested))))
        return (count, requested > Double(maximumGIFFrames) ? duration / Double(count) : 1 / Double(fps))
    }

    /// GIF stores delays in whole centiseconds. Rounding each frame alone drifts
    /// (12 fps: 8 cs instead of 8.33 cs, 4% fast). Round the frame start times
    /// instead, so delays alternate (8, 9, 8, ...) and the total stays exact.
    static func gifDelays(count: Int, interval: Double, total: Double) -> [Int] {
        (0..<count).map { frame in
            let start = (Double(frame) * interval * 100).rounded()
            let end = (min(total, Double(frame + 1) * interval) * 100).rounded()
            return max(2, Int(end - start))
        }
    }

    public static func videoToGIF(_ input: URL, maxWidth: Int = 480, fps: Int = 12,
        start: Double? = nil, duration: Double? = nil, output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        let work = MediaWork(progress: progress, isCancelled: isCancelled)
        try await MediaIO.publish(input: input, output: output, work: work) { scratch in
            guard (1...4096).contains(maxWidth), (1...50).contains(fps) else {
                throw PowerError.badInput("Choose a GIF width from 1 to 4096 and a frame rate from 1 to 50.")
            }
            let asset = try MediaIO.asset(input)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw PowerError.badInput("The file has no video track.")
            }
            let length = try await MediaIO.duration(asset)
            let first = start ?? 0
            let requested = duration ?? (length - first)
            guard first.isFinite, first >= 0, first < length, requested.isFinite, requested > 0 else {
                throw PowerError.badInput("Choose a valid GIF time range.")
            }
            let lengthToRead = min(requested, length - first)
            let plan = gifFramePlan(duration: lengthToRead, fps: fps)
            let frames = plan.count
            let delays = gifDelays(count: frames, interval: plan.interval, total: lengthToRead)
            let sourceMetadata = try await MediaMetadata.text(asset)
            let metadata = CGImageMetadataCreateMutable()
            if !sourceMetadata.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: sourceMetadata, options: [.sortedKeys])
                guard CGImageMetadataRegisterNamespaceForPrefix(metadata, "urn:clicksmith:media:metadata" as CFString,
                    "clicksmith" as CFString, nil),
                    CGImageMetadataSetValueWithPath(metadata, nil, "clicksmith:SourceMetadata" as CFString,
                        String(decoding: data, as: UTF8.self) as CFString) else {
                    throw PowerError.failed("Cannot preserve the GIF metadata.")
                }
            }
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let display = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
            guard display.width > 0, display.height > 0 else { throw PowerError.badInput("The video dimensions are invalid.") }
            let width = min(Double(maxWidth), display.width)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: width, height: width * display.height / display.width)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let canceller = MediaImageCancellation(generator)
            let cancellation = Task {
                while !Task.isCancelled {
                    if isCancelled() { canceller.cancel(); return }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            }
            defer {
                cancellation.cancel()
                generator.cancelAllCGImageGeneration()
            }
            guard let destination = CGImageDestinationCreateWithURL(scratch as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
                throw PowerError.failed("Cannot create the GIF file.")
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for frame in 0..<frames {
                try work.check()
                // ImageIO builds an adaptive 256-color palette per frame from full-color source images.
                let time = first + Double(frame) * plan.interval
                let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 60_000)).image
                // ImageIO converts seconds to centiseconds; the quarter keeps it
                // from truncating 0.09 (0.08999...) down to 8.
                let delay = (Double(delays[frame]) + 0.25) / 100
                CGImageDestinationAddImageAndMetadata(destination, image, frame == 0 ? metadata : nil, [
                    kCGImageDestinationLossyCompressionQuality: 1.0,
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
                ] as CFDictionary)
                try work.report(Double(frame + 1) / Double(frames))
            }
            try work.check()
            guard CGImageDestinationFinalize(destination) else { throw PowerError.failed("Could not finish the GIF file.") }
        }
    }
}
