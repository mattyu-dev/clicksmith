import AVFoundation
import Foundation
import Testing
@testable import ClicksmithCore

final class MediaProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var cancelled = false
    func record(_ value: Double) { lock.withLock { values.append(value) } }
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var samples: [Double] { lock.withLock { values } }
}

struct MediaFixture {
    let directory: URL
    let video: URL
    let audio: URL

    static func makeAudio(in directory: URL) throws -> URL {
        let audio = directory.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        pcm.frameLength = 96_000
        let channels = try #require(pcm.floatChannelData)
        for sample in 0..<96_000 {
            let value = Float(sin(Double(sample) * 2 * .pi * 440 / 48_000) * 0.4)
            channels[0][sample] = value
            channels[1][sample] = value
        }
        do {
            var settings = format.settings
            settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: audio, settings: settings)
            try file.write(from: pcm)
        }
        return audio
    }

    static func make(rotated: Bool = true, hdr: Bool = false, p3: Bool = false, metadata: Bool = true) async throws -> MediaFixture {
        let directory = try tempDir()
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let audio = try makeAudio(in: directory)
        let video = directory.appendingPathComponent("colors.mov")
        let writer = try AVAssetWriter(outputURL: video, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = "2026-11-16T10:11:12Z" as NSString
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+48.8566+002.3522/" as NSString
        writer.metadata = metadata ? [date, location] : []
        var settings: [String: Any] = [AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]]
        if hdr {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel"]
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        } else if p3 {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        writer.add(audioInput)
        let audioAsset = AVURLAsset(url: audio)
        let reader = try AVAssetReader(asset: audioAsset)
        defer { reader.cancelReading() }
        let audioTrack = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: MediaIO.pcmSettings)
        reader.add(audioOutput)
        guard writer.startWriting() else { throw PowerError.failed("Fixture writer failed to start.", detail: String(describing: writer.error)) }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw PowerError.failed("Fixture reader failed to start.", detail: String(describing: reader.error)) }
        var frame = 0
        var audioDone = false
        while frame < 48 || !audioDone {
            if frame < 48, input.isReadyForMoreMediaData {
                var pixel: CVPixelBuffer?
                let pool = try #require(adaptor.pixelBufferPool)
                #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess)
                let buffer = try #require(pixel)
                CVPixelBufferLockBaseAddress(buffer, [])
                if hdr {
                    let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
                    let strideY = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
                    for y in 0..<240 {
                        for x in 0..<320 { luma[y * strideY + x] = UInt16(64 + x * 876 / 319) << 6 }
                    }
                    let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
                    let strideUV = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
                    for y in 0..<120 {
                        for x in 0..<320 { chroma[y * strideUV + x] = 512 << 6 }
                    }
                } else {
                    let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
                    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<240 {
                        for x in 0..<320 {
                            let offset = y * rowBytes + x * 4
                            base[offset] = UInt8((x + y + frame * 9) % 256)
                            base[offset + 1] = UInt8((y + frame * 3) % 256)
                            base[offset + 2] = UInt8((x + frame * 7) % 256)
                            base[offset + 3] = 255
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
                frame += 1
                if frame == 48 { input.markAsFinished() }
            }
            if !audioDone, audioInput.isReadyForMoreMediaData {
                if let sample = audioOutput.copyNextSampleBuffer() { #expect(audioInput.append(sample)) }
                else { audioInput.markAsFinished(); audioDone = true }
            }
            if writer.status == .failed { throw writer.error ?? PowerError.failed("Fixture writer failed.") }
            try await Task.sleep(for: .milliseconds(1))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 48_000))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        completed = true
        return MediaFixture(directory: directory, video: video, audio: audio)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    /// 16-bit PCM WAV of a 440 Hz tone with an exact frame count.
    static func makeTone(in directory: URL, name: String = "speech.wav", frames: Int, sampleRate: Double, channels: UInt32) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try #require(pcm.floatChannelData)
        for channel in 0..<Int(channels) {
            for sample in 0..<frames { data[channel][sample] = Float(sin(Double(sample) * 2 * .pi * 440 / sampleRate) * 0.4) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            try file.write(from: pcm)
        }
        return url
    }
}
