import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import ClicksmithCore

@Suite(.serialized) struct MediaTests {
    @Test func audioConversionWithoutVideo() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try MediaFixture.makeAudio(in: directory)
        let information = try await MediaEngine.info(audio)
        #expect(information.hasAudio && !information.hasVideo)
        let output = directory.appendingPathComponent("converted.aiff")
        try await MediaEngine.convertAudio(audio, format: .aiff, output: output)
        #expect(try MediaIO.size(output) > 0)
    }
    @Test func formatsAndReadExtensions() throws {
        #expect(MediaEngine.readableVideoExtensions().isSuperset(of: ["mov", "mp4"]))
        #expect(MediaEngine.readableAudioExtensions().isSuperset(of: ["wav", "m4a", "aiff"]))
        #expect(AudioFormat.opus.fileExtension == "caf")
        #expect(AudioFormat.aac.fileExtension == "m4a")
        for format in AudioFormat.allCases {
            #expect(try JSONDecoder().decode(AudioFormat.self, from: JSONEncoder().encode(format)) == format)
        }
        for preset in VideoPreset.allCases {
            #expect(try JSONDecoder().decode(VideoPreset.self, from: JSONEncoder().encode(preset)) == preset)
        }
        let formats = MediaEngine.writableAudioFormats()
        #expect(Set(formats).isSuperset(of: [.aac, .alac, .wav, .aiff]))
    }

    @Test func inspectAudioAndRotatedVideo() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let video = try await MediaEngine.info(fixture.video)
        #expect(video.hasVideo && video.hasAudio)
        #expect(abs(video.duration - 2) < 0.1)
        #expect(video.size == (try MediaIO.size(fixture.video)))
        #expect(video.dimensions == CGSize(width: 240, height: 320))
        #expect(abs(video.fps - 24) < 0.1)
        #expect(video.codecs.contains("H.264"))
        #expect(video.codecs.contains("AAC"))
        #expect(video.bitrate > 0)
        let audio = try await MediaEngine.info(fixture.audio)
        #expect(audio.hasAudio && !audio.hasVideo)
        #expect(audio.dimensions == nil && audio.fps == 0)
        #expect(abs(audio.duration - 2) < 0.01)
    }

    @Test(arguments: VideoPreset.allCases)
    func everyVideoPreset(_ preset: VideoPreset) async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.video)
        let output = fixture.directory.appendingPathComponent(preset == .prores_proxy ? "converted.mov" : "converted.mp4")
        let progress = MediaProgress()
        try await MediaEngine.convertVideo(fixture.video, preset: preset, output: output, progress: progress.record)
        let result = try await MediaEngine.info(output)
        #expect(result.hasVideo && result.hasAudio)
        #expect(result.dimensions == CGSize(width: 240, height: 320))
        #expect(abs(result.duration - 2) < 0.1)
        let expected = preset == .prores_proxy ? "ProRes Proxy" : (preset.codec == .hevc ? "HEVC" : "H.264")
        #expect(result.codecs.contains(expected))
        #expect(progress.samples.first == 0 && progress.samples.last == 1)
        #expect(progress.samples == progress.samples.sorted())
        #expect(try Data(contentsOf: fixture.video) == original)
        let metadata = try await AVURLAsset(url: output).load(.metadata)
        let date = try #require(metadata.first { $0.identifier == .quickTimeMetadataCreationDate || $0.identifier == .quickTimeUserDataCreationDate || $0.commonKey == .commonKeyCreationDate })
        #expect(try await date.load(.stringValue) == "2026-11-16T10:11:12Z")
        let location = try #require(metadata.first { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.identifier == .quickTimeUserDataLocationISO6709 || $0.commonKey == .commonKeyLocation })
        // MP4 stores location in the ISO 'loci' box (16.16 fixed point, altitude
        // always present), so compare coordinates, not the literal string.
        let coordinates = try #require(try await Self.coordinates(location.load(.stringValue)))
        #expect(abs(coordinates.latitude - 48.8566) < 0.0001)
        #expect(abs(coordinates.longitude - 2.3522) < 0.0001)
        if preset == .prores_proxy { #expect(try await location.load(.stringValue) == "+48.8566+002.3522/") }
    }

    /// Parses the latitude and longitude of an ISO 6709 string such as "+48.8566+002.3522+000.000/".
    static func coordinates(_ text: String?) -> (latitude: Double, longitude: Double)? {
        guard let text else { return nil }
        var parts: [Double] = []
        var current = ""
        for character in text {
            if (character == "+" || character == "-" || character == "/"), !current.isEmpty {
                guard let value = Double(current) else { return nil }
                parts.append(value); current = ""
            }
            if character != "/" { current.append(character) }
        }
        return parts.count >= 2 ? (parts[0], parts[1]) : nil
    }

    @Test func everyWritableAudioFormatAndExtraction() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.audio)
        let formats = MediaEngine.writableAudioFormats()
        print("Media writable audio formats: \(formats.map(\.rawValue).joined(separator: ", "))")
        for format in formats {
            let output = fixture.directory.appendingPathComponent("audio-\(format.rawValue).\(format.fileExtension)")
            let progress = MediaProgress()
            try await MediaEngine.convertAudio(fixture.audio, format: format, output: output, progress: progress.record)
            let result = try await MediaEngine.info(output)
            #expect(result.hasAudio && !result.hasVideo)
            #expect(abs(result.duration - 2) < 0.15)
            #expect(progress.samples.first == 0 && progress.samples.last == 1)
            let extracted = fixture.directory.appendingPathComponent("extracted-\(format.rawValue).\(format.fileExtension)")
            try await MediaEngine.extractAudio(fixture.video, format: format, output: extracted)
            let extraction = try await MediaEngine.info(extracted)
            #expect(extraction.hasAudio && !extraction.hasVideo)
            #expect(abs(extraction.duration - 2) < 0.15)
            // Decode the encoded file too. Container creation alone does not prove useful output.
            let decoded = fixture.directory.appendingPathComponent("roundtrip-\(format.rawValue).wav")
            try await MediaEngine.convertAudio(output, format: .wav, output: decoded)
            let file = try AVAudioFile(forReading: decoded)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)[0]
            let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
            #expect(peak > 0.2 && peak < 0.6)
        }
        #expect(try Data(contentsOf: fixture.audio) == original)
        for format in AudioFormat.allCases where !formats.contains(format) {
            let output = fixture.directory.appendingPathComponent("unsupported.\(format.fileExtension)")
            await #expect(throws: PowerError.self) {
                try await MediaEngine.convertAudio(fixture.audio, format: format, output: output)
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func gifTimingOrientationAndPalette() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("animated.gif")
        try await MediaEngine.videoToGIF(fixture.video, maxWidth: 120, fps: 8, start: 0.5, duration: 1, output: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 8)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 120 && image.height == 160)
        // ImageIO may expand an indexed GIF to RGB. Inspect the decoded colors
        // without assuming the decoder retains the original color-space model.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt32.self)
        #expect((128...256).contains(Set(UnsafeBufferPointer(start: pixels, count: image.width * image.height)).count))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        #expect(abs((gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? 0) - 0.125) < 0.01)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let text = try #require(CGImageMetadataCopyStringValueWithPath(metadata, nil, "clicksmith:SourceMetadata" as CFString)) as String
        let preserved = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(preserved.values.contains("2026-11-16T10:11:12Z"))
        #expect(preserved.values.contains("+48.8566+002.3522/"))
    }

    @Test func compressVideoToTightTarget() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("small.mp4")
        let progress = MediaProgress()
        let report = try await MediaEngine.compress(fixture.video, targetBytes: 38_000, output: output, progress: progress.record)
        #expect(report.before == (try MediaIO.size(fixture.video)))
        #expect(report.after == (try MediaIO.size(output)))
        #expect(report.after <= 38_000)
        #expect(report.resolution != nil && report.bitrate != nil)
        let result = try await MediaEngine.info(output)
        #expect(result.hasAudio && result.hasVideo)
        #expect(abs(result.duration - 2) < 0.1)
        #expect(result.dimensions!.width <= 240)
        #expect(progress.samples == progress.samples.sorted())
        #expect(progress.samples.last == 1)
    }

    @Test func compressAudioAndRejectImpossibleTarget() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("small.m4a")
        let result = try await MediaEngine.compress(fixture.audio, targetBytes: 35_000, output: output)
        #expect(result.after <= 35_000 && result.resolution == nil)
        let impossible = fixture.directory.appendingPathComponent("impossible.mp4")
        await #expect(throws: PowerError.self) {
            try await MediaEngine.compress(fixture.video, targetBytes: 1000, output: impossible)
        }
        #expect(!FileManager.default.fileExists(atPath: impossible.path))
    }

    @Test func cancellationCleansPartialOutput() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        for operation in 0..<4 {
            let output = fixture.directory.appendingPathComponent("cancel-\(operation).mp4")
            let state = MediaProgress()
            let progress: @Sendable (Double) -> Void = { value in
                if value > 0.05 { state.cancel() }
            }
            let started = ContinuousClock.now
            await #expect(throws: PowerError.cancelled) {
                switch operation {
                case 0: try await MediaEngine.convertVideo(fixture.video, preset: .h264_720, output: output, progress: progress, isCancelled: { state.isCancelled })
                case 1: try await MediaEngine.extractAudio(fixture.video, format: .aac, output: output, progress: progress, isCancelled: { state.isCancelled })
                case 2: try await MediaEngine.videoToGIF(fixture.video, output: output, progress: progress, isCancelled: { state.isCancelled })
                default: _ = try await MediaEngine.compress(fixture.video, targetBytes: 38_000, output: output, progress: progress, isCancelled: { state.isCancelled })
                }
            }
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(!FileManager.default.fileExists(atPath: output.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".clicksmith-media-") })
        }
    }

    @Test func taskCancellationAndExistingOutputSafety() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.video)
        await #expect(throws: PowerError.self) {
            try await MediaEngine.convertVideo(fixture.video, preset: .h264_720, output: fixture.video)
        }
        let occupied = try touch(fixture.directory, "occupied.mp4", "keep")
        await #expect(throws: PowerError.self) {
            try await MediaEngine.convertVideo(fixture.video, preset: .h264_720, output: occupied)
        }
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "keep")
        #expect(try Data(contentsOf: fixture.video) == original)
        let output = fixture.directory.appendingPathComponent("task-cancelled.mp4")
        let task = Task {
            try await MediaEngine.convertVideo(fixture.video, preset: .hevc_720, output: output)
        }
        task.cancel()
        await #expect(throws: PowerError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func invalidInputsAndGIFOptions() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let corrupt = try touch(fixture.directory, "bad.mov", "not media")
        await #expect(throws: PowerError.self) { try await MediaEngine.info(corrupt) }
        await #expect(throws: PowerError.self) { try await MediaEngine.info(fixture.directory) }
        let output = fixture.directory.appendingPathComponent("invalid.gif")
        for start in [-1.0, 2, .nan, .infinity] {
            await #expect(throws: PowerError.self) {
                try await MediaEngine.videoToGIF(fixture.video, start: start, output: output)
            }
        }
        await #expect(throws: PowerError.self) { try await MediaEngine.videoToGIF(fixture.video, fps: 0, output: output) }
        await #expect(throws: PowerError.self) { try await MediaEngine.convertVideo(fixture.audio, preset: .h264_720, output: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func h264ToneMapsHDRToSDRTags() async throws {
        let fixture = try await MediaFixture.make(rotated: false, hdr: true)
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("sdr.mp4")
        try await MediaEngine.convertVideo(fixture.video, preset: .h264_1080, output: output)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let values = try #require(CMFormatDescriptionGetExtensions(description)) as NSDictionary
        #expect(values[kCMFormatDescriptionExtension_TransferFunction] as? String == AVVideoTransferFunction_ITU_R_709_2)
        #expect(values[kCMFormatDescriptionExtension_ColorPrimaries] as? String == AVVideoColorPrimaries_ITU_R_709_2)
    }
}
