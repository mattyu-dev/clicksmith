import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import ClicksmithCore

@Suite(.serialized) struct MediaSafetyTests {
    @Test func formatsAndSizing() throws {
        for format in AudioFormat.allCases {
            #expect(try JSONDecoder().decode(AudioFormat.self, from: JSONEncoder().encode(format)) == format)
            #expect(!format.fileExtension.isEmpty)
        }
        for preset in VideoPreset.allCases {
            #expect(try JSONDecoder().decode(VideoPreset.self, from: JSONEncoder().encode(preset)) == preset)
        }
        #expect(AudioFormat.opus.fileExtension == "caf")
        #expect(AudioFormat.alac.fileExtension == "m4a")
        let landscape = try MediaVideo.scaledSize(CGSize(width: 3840, height: 2160), transform: .identity, bounds: VideoPreset.h264_720.bounds)
        #expect(landscape == CGSize(width: 1280, height: 720))
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2160, ty: 0)
        let portrait = try MediaVideo.scaledSize(CGSize(width: 3840, height: 2160), transform: rotation, bounds: VideoPreset.hevc_1080.bounds)
        #expect(portrait == CGSize(width: 1920, height: 1080))
        #expect(try MediaVideo.scaledSize(CGSize(width: 321, height: 241), transform: .identity, bounds: VideoPreset.hevc_4k.bounds) == CGSize(width: 320, height: 240))
        #expect(throws: PowerError.self) { try MediaVideo.scaledSize(.zero, transform: .identity, bounds: landscape) }
        #expect(throws: PowerError.self) { try MediaVideo.scaledSize(landscape, transform: .init(scaleX: 0, y: 0), bounds: landscape) }
        #expect(throws: PowerError.self) { try MediaIO.check(-50, "Synthetic error") }
    }

    @Test func everyLocallyWritableAudioFormat() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try MediaFixture.makeAudio(in: directory)
        let original = try Data(contentsOf: input)
        let formats = MediaEngine.writableAudioFormats()
        #expect(formats.contains(.wav) && formats.contains(.aiff))
        print("Media audio encoders in this process: \(formats.map(\.rawValue).joined(separator: ", "))")
        for format in formats {
            let output = directory.appendingPathComponent("\(format.rawValue).\(format.fileExtension)")
            let progress = MediaProgress()
            try await MediaEngine.convertAudio(input, format: format, output: output, progress: progress.record)
            let result = try await MediaEngine.info(output)
            #expect(result.hasAudio && !result.hasVideo)
            #expect(abs(result.duration - 2) < 0.15)
            #expect(progress.samples == progress.samples.sorted())
            #expect(progress.samples.first == 0 && progress.samples.last == 1)
            let file = try AVAudioFile(forReading: output)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)[0]
            let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
            #expect(peak > 0.2 && peak < 0.6)
        }
        #expect(try Data(contentsOf: input) == original)
        for format in AudioFormat.allCases where !formats.contains(format) {
            let output = directory.appendingPathComponent("unsupported-\(format.rawValue)")
            await #expect(throws: PowerError.self) { try await MediaEngine.convertAudio(input, format: format, output: output) }
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func audioCancellationAndOutputRaces() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try MediaFixture.makeAudio(in: directory)
        let before = try Data(contentsOf: input)
        let cancelled = directory.appendingPathComponent("cancelled.aiff")
        let state = MediaProgress()
        var started = ContinuousClock.now
        await #expect(throws: PowerError.cancelled) {
            try await MediaEngine.convertAudio(input, format: .aiff, output: cancelled,
                progress: { value in if value > 0.1 { state.cancel() } }, isCancelled: { state.isCancelled })
        }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: cancelled.path))
        let occupied = try touch(directory, "existing.aiff", "existing output")
        await #expect(throws: PowerError.self) { try await MediaEngine.convertAudio(input, format: .aiff, output: occupied) }
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "existing output")
        await #expect(throws: PowerError.self) { try await MediaEngine.convertAudio(input, format: .wav, output: input) }
        let symlink = directory.appendingPathComponent("broken-symlink.aiff")
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: directory.appendingPathComponent("absent").path)
        await #expect(throws: PowerError.self) { try await MediaEngine.convertAudio(input, format: .aiff, output: symlink) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path) == directory.appendingPathComponent("absent").path)
        let race = directory.appendingPathComponent("race.aiff")
        let made = MediaProgress()
        await #expect(throws: PowerError.self) {
            try await MediaEngine.convertAudio(input, format: .aiff, output: race, progress: { value in
                if value > 0.1 && !made.isCancelled {
                    made.cancel()
                    try? Data("raced output".utf8).write(to: race, options: .withoutOverwriting)
                }
            })
        }
        #expect(try String(contentsOf: race, encoding: .utf8) == "raced output")
        let taskOutput = directory.appendingPathComponent("task.aiff")
        started = .now
        let task = Task { try await MediaEngine.convertAudio(input, format: .aiff, output: taskOutput) }
        task.cancel()
        await #expect(throws: PowerError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: taskOutput.path))
        #expect(try Data(contentsOf: input) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".clicksmith-media-") })
    }

    @Test func pcmPreservesCreationAndLocationMetadata() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try MediaFixture.makeAudio(in: directory)
        var source: AudioFileID?
        #expect(AudioFileOpenURL(input as CFURL, .readWritePermission, 0, &source) == noErr)
        let sourceFile = try #require(source)
        var list = Data("INFO".utf8)
        for (key, value) in [("ICRD", "2026-11-16T10:11:12Z"), ("ICMT", "+48.8566+002.3522/")] {
            list.append(contentsOf: key.utf8)
            var size = UInt32(value.utf8.count + 1).littleEndian
            withUnsafeBytes(of: &size) { list.append(contentsOf: $0) }
            list.append(contentsOf: value.utf8)
            list.append(0)
            if list.count % 2 != 0 { list.append(0) }
        }
        #expect(list.withUnsafeBytes { AudioFileSetUserData(sourceFile, 0x4C495354, 0, UInt32($0.count), $0.baseAddress!) } == noErr)
        AudioFileClose(sourceFile)
        let before = try Data(contentsOf: input)
        let output = directory.appendingPathComponent("tagged.aiff")
        try await MediaEngine.convertAudio(input, format: .aiff, output: output)
        var file: AudioFileID?
        #expect(AudioFileOpenURL(output as CFURL, .readPermission, 0, &file) == noErr)
        let opened = try #require(file)
        defer { AudioFileClose(opened) }
        var size: UInt32 = 0
        #expect(AudioFileGetUserDataSize(opened, 0x414E4E4F, 0, &size) == noErr)
        var bytes = [UInt8](repeating: 0, count: Int(size))
        #expect(AudioFileGetUserData(opened, 0x414E4E4F, 0, &size, &bytes) == noErr)
        let metadata = try #require(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: String])
        #expect(metadata.values.contains("2026-11-16T10:11:12Z"))
        #expect(metadata.values.contains("+48.8566+002.3522/"))
        let items = try await MediaMetadata.writerItems(AVURLAsset(url: input))
        let creation = try #require(items.first { $0.identifier == .quickTimeMetadataCreationDate })
        #expect(try await creation.load(.stringValue) == "2026-11-16T10:11:12Z")
        let roundtrip = directory.appendingPathComponent("roundtrip.wav")
        try await MediaEngine.convertAudio(output, format: .wav, output: roundtrip)
        let recovered = try await MediaMetadata.text(AVURLAsset(url: roundtrip))
        #expect(recovered.values.contains("2026-11-16T10:11:12Z"))
        #expect(recovered.values.contains("+48.8566+002.3522/"))
        #expect(try Data(contentsOf: input) == before)
        let inputDate = try #require(input.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let outputDate = try #require(output.resourceValues(forKeys: [.creationDateKey]).creationDate)
        #expect(abs(inputDate.timeIntervalSince(outputDate)) < 1)
    }

    @Test func workReportsAndFailedPublishCleanup() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try touch(directory, "input.wav")
        let output = directory.appendingPathComponent("output.wav")
        let progress = MediaProgress()
        let work = MediaWork(progress: progress.record, isCancelled: { false })
        try work.report(-1)
        try work.report(5)
        #expect(progress.samples == [0, 0.99])
        let cancelled = MediaWork(progress: { _ in }, isCancelled: { true })
        #expect(throws: PowerError.cancelled) { try cancelled.check() }
        await #expect(throws: PowerError.failed("Injected error")) {
            try await MediaIO.publish(input: input, output: output, work: work) { scratch in
                try Data("partial".utf8).write(to: scratch)
                throw PowerError.failed("Injected error")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["input.wav"])
    }

    @Test func invalidMediaGetsTypedErrors() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = try touch(directory, "bad.mov", "not media")
        await #expect(throws: PowerError.self) { try await MediaEngine.info(invalid) }
        await #expect(throws: PowerError.self) { try await MediaEngine.info(directory) }
        #expect(throws: PowerError.self) { try MediaIO.asset(URL(string: "https://example.invalid/media.mp4")!) }
        let output = directory.appendingPathComponent("no-output.gif")
        await #expect(throws: PowerError.self) { try await MediaEngine.videoToGIF(invalid, maxWidth: 0, output: output) }
        await #expect(throws: PowerError.self) { try await MediaEngine.videoToGIF(invalid, fps: 0, output: output) }
        await #expect(throws: PowerError.self) { try await MediaEngine.compress(invalid, targetBytes: -1, output: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
