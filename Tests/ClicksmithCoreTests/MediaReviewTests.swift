import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import ClicksmithCore

@Suite(.serialized) struct MediaReviewTests {
    @Test func metadataKeysCodecsAndOpusLabel() async throws {
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = "2026-11-16T10:11:12Z" as NSString
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+48.8566+002.3522/" as NSString
        let originals = [date, location]
        for type in [AVFileType.mp4, .m4a] {
            let items = MediaMetadata.containerItems(originals, fileType: type)
            #expect(items.map { $0.keySpace } == [.quickTimeUserData, .quickTimeUserData])
            #expect(items.compactMap { ($0.key as? NSNumber)?.uint32Value } == [0xA9646179, 0xA978797A])
            #expect(try await items[0].load(.stringValue) == "2026-11-16T10:11:12Z")
            #expect(try await items[1].load(.stringValue) == "+48.8566+002.3522/")
        }
        #expect(MediaMetadata.containerItems(originals, fileType: .mov).first?.identifier == .quickTimeMetadataCreationDate)
        #expect(originals.first?.identifier == .quickTimeMetadataCreationDate)
        #expect(MediaEngine.codecName(0x61616320) == "AAC")
        #expect(MediaEngine.codecName(0x6D703461) == "AAC")
        #expect(MediaEngine.codecName(0x61766331) == "H.264")
        #expect(MediaEngine.codecName(0x78797A20) == "xyz")
        #expect(AudioFormat.opus.title == "Opus (.caf)")
    }

    @Test func gifFrameLimitPreservesDuration() {
        let short = MediaEngine.gifFramePlan(duration: 1.05, fps: 12)
        #expect(short.count == 13)
        #expect(short.interval == 1.0 / 12)
        let long = MediaEngine.gifFramePlan(duration: 40, fps: 12)
        #expect(long.count == 300)
        #expect(abs(long.interval * Double(long.count) - 40) < 0.00001)
        let veryLong = MediaEngine.gifFramePlan(duration: 600, fps: 50)
        #expect(veryLong.count <= MediaEngine.maximumGIFFrames)
        #expect(veryLong.interval == 2)
    }

    @Test func losslessFormatDescriptions() throws {
        let source = MediaPCM(sampleRate: 44_100, channels: 1, bitDepth: 24, isFloat: false)
        let available = MediaEngine.writableAudioFormats()
        for format in [AudioFormat.wav, .aiff, .flac, .alac] where available.contains(format) {
            let result = try format.description(pcm: source)
            #expect(result.mSampleRate == 44_100)
            #expect(result.mChannelsPerFrame == 1)
            if format == .alac || format == .flac { #expect(result.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData) }
            else { #expect(result.mBitsPerChannel == 24) }
        }
        let cd = MediaPCM(sampleRate: 44_100, channels: 2, bitDepth: 16, isFloat: false)
        #expect(try AudioFormat.flac.description(pcm: cd).mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData)
        #expect(try AudioFormat.alac.description(pcm: cd).mFormatFlags == kAppleLosslessFormatFlag_16BitSourceData)
        let float = MediaPCM(sampleRate: 96_000, channels: 2, bitDepth: 64, isFloat: true)
        #expect(try AudioFormat.wav.description(pcm: float).mBitsPerChannel == 64)
        #expect(try AudioFormat.aiff.description(pcm: float).mBitsPerChannel == 24)
    }

    @Test func colorAndHDRMetadata() throws {
        let p3: NSDictionary = [kCMFormatDescriptionExtension_ColorPrimaries: AVVideoColorPrimaries_P3_D65,
            kCMFormatDescriptionExtension_TransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2]
        let sdr = MediaColor(source: p3, codec: .h264)
        #expect(sdr.properties[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_P3_D65)
        #expect(!sdr.keepHDR)
        let mastering = Data(repeating: 1, count: 24)
        let light = Data([3, 232, 1, 144])
        let hdr: NSDictionary = [kCMFormatDescriptionExtension_ColorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
            kCMFormatDescriptionExtension_YCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020,
            kCMFormatDescriptionExtension_MasteringDisplayColorVolume: mastering,
            kCMFormatDescriptionExtension_ContentLightLevelInfo: light]
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        let hevc = MediaColor(source: hdr, codec: .hevc)
        #expect(hevc.keepHDR)
        hevc.apply(to: buffer)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data == mastering)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data == light)
        let h264 = MediaColor(source: hdr, codec: .h264)
        h264.apply(to: buffer)
        #expect(h264.properties[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_709_2)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil)
    }

    @Test func workerRunsOutsideCooperativeTaskAndHonorsCancellation() async throws {
        let outside = try await MediaIO.onWorker(work: .init(progress: { _ in }, isCancelled: { false })) { _ in
            !Thread.isMainThread && withUnsafeCurrentTask { $0 == nil }
        }
        #expect(outside)
        let started = MediaProgress()
        let task = Task {
            try await MediaIO.onWorker(work: .init(progress: { _ in }, isCancelled: { false })) { work in
                started.cancel()
                while true { try work.pauseBlocking() }
            }
        }
        while !started.isCancelled { try await Task.sleep(for: .milliseconds(1)) }
        let time = ContinuousClock.now
        task.cancel()
        await #expect(throws: PowerError.cancelled) { try await task.value }
        #expect(ContinuousClock.now - time < .seconds(1))
    }

    @Test func losslessPreserves44100Mono24BitSamples() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("precise.wav")
        let samples = (0..<8192).map { index in Int32((index * 7919) % 0x7FFFFF) << 8 }
        var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 3, mFramesPerPacket: 1, mBytesPerFrame: 3,
            mChannelsPerFrame: 1, mBitsPerChannel: 24, mReserved: 0)
        var client = format
        client.mBitsPerChannel = 32; client.mBytesPerPacket = 4; client.mBytesPerFrame = 4
        try Self.write(input, format: &format, client: &client, samples: samples)
        let original = try Data(contentsOf: input)
        for destination in MediaEngine.writableAudioFormats() where destination.isLossless {
            let output = directory.appendingPathComponent("converted-\(destination.rawValue).\(destination.fileExtension)")
            try await MediaEngine.convertAudio(input, format: destination, output: output)
            let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
            let source = try await MediaPCM.source(track, url: output)
            #expect(source.sampleRate == 44_100)
            #expect(source.channels == 1)
            #expect(source.bitDepth == 24)
            #expect(try Self.read(output, client: &client, count: samples.count, type: Int32.self) == samples)
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func flacKeeps16BitAndRejectsTooShortInput() async throws {
        guard MediaEngine.writableAudioFormats().contains(.flac) else { return }
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var client = format
        let samples = (0..<20_000).map { Int16(truncatingIfNeeded: $0 * 7919) }
        let input = directory.appendingPathComponent("cd.wav")
        try Self.write(input, format: &format, client: &client, samples: samples)
        let output = directory.appendingPathComponent("cd.flac")
        try await MediaEngine.convertAudio(input, format: .flac, output: output)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).first)
        #expect(try await MediaPCM.source(track, url: output).bitDepth == 16)
        #expect(try Self.read(output, client: &client, count: samples.count, type: Int16.self) == samples)
        // Shorter than one 4608-frame FLAC packet: clear error, no output.
        let short = directory.appendingPathComponent("short.wav")
        try Self.write(short, format: &format, client: &client, samples: Array(samples.prefix(1000)))
        let shortOutput = directory.appendingPathComponent("short.flac")
        await #expect(throws: PowerError.self) {
            try await MediaEngine.convertAudio(short, format: .flac, output: shortOutput)
        }
        #expect(!FileManager.default.fileExists(atPath: shortOutput.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".clicksmith-media") })
    }

    @Test func wavKeepsFloat64Precision() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("float.wav")
        let samples = (0..<8192).map { 0.5 + Double($0) * 0.0000000000000001 }
        var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 1, mBitsPerChannel: 64, mReserved: 0)
        var client = format
        try Self.write(input, format: &format, client: &client, samples: samples)
        let output = directory.appendingPathComponent("converted.wav")
        try await MediaEngine.convertAudio(input, format: .wav, output: output)
        let read: [Double] = try Self.read(output, client: &client, count: samples.count, type: Double.self)
        #expect(read.map(\.bitPattern) == samples.map(\.bitPattern))
        var file: AudioFileID?
        #expect(AudioFileOpenURL(output as CFURL, .readPermission, 0, &file) == noErr)
        let opened = try #require(file)
        defer { AudioFileClose(opened) }
        var info = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: info))
        #expect(AudioFileGetProperty(opened, kAudioFilePropertyDataFormat, &size, &info) == noErr)
        #expect(info.mBitsPerChannel == 64)
        #expect(info.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    @Test func wavKeepsUnsigned8BitSamples() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("eight-bit.wav")
        let samples = (0..<8192).map { Int32($0 % 256 - 128) << 24 }
        var format = AudioStreamBasicDescription(mSampleRate: 22_050, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsPacked, mBytesPerPacket: 1, mFramesPerPacket: 1,
            mBytesPerFrame: 1, mChannelsPerFrame: 1, mBitsPerChannel: 8, mReserved: 0)
        var client = format
        client.mFormatFlags |= kAudioFormatFlagIsSignedInteger
        client.mBitsPerChannel = 32; client.mBytesPerPacket = 4; client.mBytesPerFrame = 4
        try Self.write(input, format: &format, client: &client, samples: samples)
        let output = directory.appendingPathComponent("converted.wav")
        try await MediaEngine.convertAudio(input, format: .wav, output: output)
        #expect(try Self.read(output, client: &client, count: samples.count, type: Int32.self) == samples)
    }

    @Test func taggedSourceConvertsToEveryReportedLosslessFormat() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try MediaFixture.makeAudio(in: directory)
        var file: AudioFileID?
        #expect(AudioFileOpenURL(input as CFURL, .readWritePermission, 0, &file) == noErr)
        let opened = try #require(file)
        var metadata = Data("INFOICMT".utf8)
        let text = Data("creation date and location\0".utf8)
        var length = UInt32(text.count).littleEndian
        withUnsafeBytes(of: &length) { metadata.append(contentsOf: $0) }
        metadata.append(text)
        if metadata.count % 2 != 0 { metadata.append(0) }
        #expect(metadata.withUnsafeBytes { AudioFileSetUserData(opened, 0x4C495354, 0, UInt32($0.count), $0.baseAddress!) } == noErr)
        AudioFileClose(opened)
        for format in MediaEngine.writableAudioFormats() where format.isLossless {
            let output = directory.appendingPathComponent("tagged-\(format.rawValue).\(format.fileExtension)")
            try await MediaEngine.convertAudio(input, format: format, output: output)
            #expect(try MediaIO.size(output) > 0)
        }
    }

    @Test func compressionUsesPlayableContainersAndFillsBudget() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("sharing.mp4")
        let report = try await MediaEngine.compress(fixture.video, targetBytes: 40_000, output: output)
        #expect(report.after <= 40_000)
        #expect(report.after >= 34_000)
        #expect(try await MediaEngine.info(output).hasVideo)
        let audio = fixture.directory.appendingPathComponent("sharing.m4a")
        let audioReport = try await MediaEngine.compress(fixture.audio, targetBytes: 35_000, output: audio)
        #expect(audioReport.after <= 35_000)
        #expect(try await MediaEngine.info(audio).hasAudio)
    }

    @Test func p3ColorSurvivesH264Conversion() async throws {
        let fixture = try await MediaFixture.make(rotated: false, p3: true)
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("p3.mp4")
        try await MediaEngine.convertVideo(fixture.video, preset: .h264_720, output: output)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        let tags = try #require(CMFormatDescriptionGetExtensions(description)) as NSDictionary
        #expect(tags[kCMFormatDescriptionExtension_ColorPrimaries] as? String == AVVideoColorPrimaries_P3_D65)
        #expect(tags[kCMFormatDescriptionExtension_TransferFunction] as? String == AVVideoTransferFunction_ITU_R_709_2)
    }

    private static func write<T>(_ url: URL, format: inout AudioStreamBasicDescription,
        client: inout AudioStreamBasicDescription, samples: [T]) throws {
        var file: ExtAudioFileRef?
        #expect(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileWAVEType, &format, nil, 0, &file) == noErr)
        let opened = try #require(file)
        defer { ExtAudioFileDispose(opened) }
        try #require(ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
        samples.withUnsafeBytes {
            var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1,
                mDataByteSize: UInt32($0.count), mData: UnsafeMutableRawPointer(mutating: $0.baseAddress)))
            #expect(ExtAudioFileWrite(opened, UInt32(samples.count), &buffer) == noErr)
        }
    }

    private static func read<T>(_ url: URL, client: inout AudioStreamBasicDescription,
        count: Int, type: T.Type) throws -> [T] {
        var file: ExtAudioFileRef?
        #expect(ExtAudioFileOpenURL(url as CFURL, &file) == noErr)
        let opened = try #require(file)
        defer { ExtAudioFileDispose(opened) }
        try #require(ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { storage.deallocate() }
        var frames = UInt32(count)
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: client.mChannelsPerFrame,
            mDataByteSize: UInt32(count * MemoryLayout<T>.stride), mData: storage))
        try #require(ExtAudioFileRead(opened, &frames, &buffer) == noErr)
        #expect(frames == UInt32(count))
        return Array(UnsafeBufferPointer(start: storage, count: Int(frames)))
    }
}
