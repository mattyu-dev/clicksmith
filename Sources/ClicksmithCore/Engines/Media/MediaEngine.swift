import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum MediaEngine {
    public static func readableVideoExtensions() -> Set<String> {
        extensions(conformingTo: .movie)
    }

    public static func readableAudioExtensions() -> Set<String> {
        extensions(conformingTo: .audio)
    }

    private static func extensions(conformingTo type: UTType) -> Set<String> {
        Set(AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
            .filter { $0.conforms(to: type) }.flatMap { $0.tags[.filenameExtension] ?? [] }.map { $0.lowercased() })
    }

    public static func writableAudioFormats() -> [AudioFormat] {
        AudioFormat.allCases.filter(MediaAudio.supports)
    }

    /// Output must not exist. MP4 is used for H.264/HEVC and MOV for ProRes Proxy.
    public static func convertVideo(_ input: URL, preset: VideoPreset, output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        let work = MediaWork(progress: progress, isCancelled: isCancelled)
        try await MediaIO.publish(input: input, output: output, work: work) { scratch in
            try await MediaVideo.encode(MediaIO.asset(input), preset: preset, output: scratch, work: work)
        }
    }

    public static func extractAudio(_ input: URL, format: AudioFormat, output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try await convertAudio(input, format: format, output: output, progress: progress, isCancelled: isCancelled)
    }

    /// Uses AudioFormat.fileExtension's container regardless of the output URL's suffix.
    public static func convertAudio(_ input: URL, format: AudioFormat, output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        let work = MediaWork(progress: progress, isCancelled: isCancelled)
        try await MediaIO.publish(input: input, output: output, work: work) { scratch in
            try await MediaAudio.encode(MediaIO.asset(input), format: format, output: scratch, work: work)
        }
    }

    public static func info(_ url: URL) async throws -> MediaInfo {
        do {
            let asset = try MediaIO.asset(url)
            let duration = try await MediaIO.duration(asset)
            let tracks = try await asset.load(.tracks)
            guard !tracks.isEmpty else { throw PowerError.badInput("The file contains no media tracks.") }
            var codecs: [String] = []
            var dimensions: CGSize?
            var fps = 0.0
            var hasAudio = false
            var hasVideo = false
            for track in tracks {
                for description in try await track.load(.formatDescriptions) {
                    let code = CMFormatDescriptionGetMediaSubType(description)
                    let codec = codecName(code)
                    if !codecs.contains(codec) { codecs.append(codec) }
                }
                if track.mediaType == .audio { hasAudio = true }
                if track.mediaType == .video {
                    hasVideo = true
                    if dimensions == nil {
                        let size = try await track.load(.naturalSize)
                        let transform = try await track.load(.preferredTransform)
                        dimensions = CGRect(origin: .zero, size: size).applying(transform).standardized.size
                        fps = Double(try await track.load(.nominalFrameRate))
                        if !fps.isFinite || fps < 0 { fps = 0 }
                    }
                }
            }
            let size = try MediaIO.size(url)
            return MediaInfo(duration: duration, size: size, codecs: codecs,
                bitrate: Int(min(Double(Int.max / 2), Double(size) * 8 / duration)), fps: fps,
                dimensions: dimensions, hasAudio: hasAudio, hasVideo: hasVideo)
        } catch {
            if error is CancellationError { throw PowerError.cancelled }
            if let error = error as? PowerError { throw error }
            throw PowerError.failed("Could not inspect the media.", detail: error.localizedDescription)
        }
    }

    static func codecName(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        let name = (String(bytes: bytes, encoding: .ascii) ?? String(code)).trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "apco": return "ProRes Proxy"
        case "aac", "mp4a": return "AAC"
        case "alac": return "ALAC"
        case "lpcm", "sowt", "twos": return "PCM"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        default: return name.isEmpty ? String(code) : name
        }
    }

    private static func payloadSizes(_ url: URL) async throws -> (video: Int64, audio: Int64) {
        let asset = try MediaIO.asset(url)
        var video: Int64 = 0
        var audio: Int64 = 0
        for track in try await asset.load(.tracks) {
            let count = max(0, try await track.load(.totalSampleDataLength))
            if track.mediaType == .video { video += count }
            if track.mediaType == .audio { audio += count }
        }
        return (video, audio)
    }

    /// AAC rate for the sound of a compressed video: more when the budget allows.
    static func compressAudioBitrate(totalBitsPerSecond rate: Double) -> Int {
        switch rate {
        case 2_500_000...: 160_000
        case 1_200_000...: 128_000
        default: 96_000
        }
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        bytes % 1_000_000 == 0 ? "\(bytes / 1_000_000) MB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    /// Requests encoder multipass when supported and measures audio before budgeting
    /// video. Retries an undersized result once higher and oversize results twice lower.
    /// Video audio uses 96 to 160 kb/s AAC by budget; audio-only files use 32 to 160 kb/s AAC.
    /// A file that already fits is refused: re-encoding it could only grow or degrade it.
    public static func compress(_ input: URL, targetBytes: Int64, output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> CompressReport {
        let work = MediaWork(progress: progress, isCancelled: isCancelled)
        return try await MediaIO.publish(input: input, output: output, work: work) { scratch in
            guard targetBytes > 0 else { throw PowerError.badInput("The target size must be positive.") }
            let original = try await info(input)
            guard original.hasVideo || original.hasAudio else { throw PowerError.badInput("The file has no audio or video.") }
            guard original.size > targetBytes else {
                throw PowerError.badInput("“\(input.lastPathComponent)” is already under \(sizeLabel(targetBytes)).")
            }
            let audioRate = compressAudioBitrate(totalBitsPerSecond: Double(targetBytes) * 8 / original.duration)
            let asset = try MediaIO.asset(input)
            var audioBytes = 0.0
            if original.hasVideo && original.hasAudio {
                let probe = scratch.deletingLastPathComponent().appendingPathComponent("audio-budget.m4a")
                let stage = MediaWork(progress: { value in progress(value * 0.1) }, isCancelled: isCancelled)
                try await MediaAudio.encode(asset, format: .aac, output: probe, work: stage, bitrate: UInt32(audioRate))
                audioBytes = Double(try await payloadSizes(probe).audio)
            }
            let overhead = max(1536, Double(targetBytes) * 0.02)
            var rate = (Double(targetBytes) - overhead - audioBytes) * 8 / original.duration
            let minimum = original.hasVideo ? 8_000.0 : 32_000.0
            let maximum = original.hasVideo ? 50_000_000.0 : 160_000.0
            guard rate.isFinite, rate >= minimum else { throw PowerError.badInput("The target is too small for this duration and the audio budget.") }
            rate = min(maximum, rate)
            var best: (url: URL, info: MediaInfo, rate: Double)?
            var raised = false
            var lowerRetries = 0
            for attempt in 0..<4 {
                try work.check()
                let candidate = scratch.deletingLastPathComponent()
                    .appendingPathComponent("attempt-\(attempt).\(original.hasVideo ? "mp4" : "m4a")")
                let stage = MediaWork(progress: { value in progress(0.1 + (Double(attempt) + value) / 4 * 0.88) }, isCancelled: isCancelled)
                do {
                    if original.hasVideo {
                        let fps = max(1, original.fps)
                        let pixels = rate / (fps * 0.08)
                        let source = original.dimensions ?? CGSize(width: 1920, height: 1080)
                        let factor = min(1, sqrt(pixels / max(1, source.width * source.height)))
                        let longEdge = max(16, min(1920, max(source.width, source.height) * factor))
                        let shortEdge = max(16, min(1080, min(source.width, source.height) * factor))
                        try await MediaVideo.encode(asset, preset: .h264_1080, output: candidate, work: stage,
                            bitrate: Int(rate), bounds: CGSize(width: longEdge, height: shortEdge), multipass: true,
                            audioBitrate: audioRate)
                    } else {
                        try await MediaAudio.encode(asset, format: .aac, output: candidate, work: stage, bitrate: UInt32(rate))
                    }
                } catch {
                    try work.check()
                    if best != nil { break }
                    throw error
                }
                let result = try await info(candidate)
                let payload = try await payloadSizes(candidate)
                let variableBytes = Double(original.hasVideo ? payload.video : payload.audio)
                let fixedBytes = max(0, Double(result.size) - variableBytes)
                let desiredPayload = Double(targetBytes) * 0.97 - fixedBytes
                let proposed = min(maximum, max(minimum, rate * desiredPayload / max(1, variableBytes)))
                if result.size <= targetBytes {
                    if result.size > (best?.info.size ?? 0) {
                        if let best { try FileManager.default.removeItem(at: best.url) }
                        best = (candidate, result, rate)
                    } else { try FileManager.default.removeItem(at: candidate) }
                    if Double(result.size) < Double(targetBytes) * 0.85, !raised, proposed > rate * 1.05 {
                        raised = true
                        rate = proposed
                        continue
                    }
                    break
                }
                try FileManager.default.removeItem(at: candidate)
                guard lowerRetries < 2 else { break }
                lowerRetries += 1
                if let best, rate > best.rate, result.size > best.info.size {
                    // A higher-quality retry can change resolution as well as rate.
                    // Interpolate between measured candidates rather than assuming
                    // encoded bytes remain proportional across that change.
                    let fraction = (Double(targetBytes) * 0.97 - Double(best.info.size))
                        / Double(result.size - best.info.size)
                    rate = best.rate + (rate - best.rate) * max(0.05, min(0.95, fraction))
                } else { rate = min(rate * 0.9, proposed) }
                if rate < minimum { break }
            }
            guard let best else {
                throw PowerError.failed("Could not fit the media within the target size.", detail: "Tried the bitrate budget and up to two lower bitrates.")
            }
            try work.check()
            try FileOps.renameExclusive(best.url, scratch)
            return CompressReport(before: original.size, after: best.info.size,
                resolution: best.info.dimensions, bitrate: best.info.bitrate)
        }
    }
}
