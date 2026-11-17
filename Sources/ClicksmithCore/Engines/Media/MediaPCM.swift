import AVFoundation
import AudioToolbox
import Foundation

/// Source precision and channel order, independent of the destination container.
struct MediaPCM: Sendable {
    let sampleRate: Double
    let channels: UInt32
    let bitDepth: UInt32
    let isFloat: Bool
    var channelLayout: Data? = nil

    static let lossy = MediaPCM(sampleRate: 48_000, channels: 2, bitDepth: 32, isFloat: true)
    static let lossyMono = MediaPCM(sampleRate: 48_000, channels: 1, bitDepth: 32, isFloat: true)

    /// Lossy encoders run at 48 kHz. A mono source stays mono; more channels mix to stereo.
    static func lossy(for track: AVAssetTrack) async throws -> MediaPCM {
        let channels = try await track.load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        return channels == 1 ? lossyMono : lossy
    }

    static func source(_ track: AVAssetTrack, url: URL? = nil) async throws -> MediaPCM {
        guard let description = try await track.load(.formatDescriptions).first,
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw PowerError.unsupported("Cannot determine the source audio format.")
        }
        let stream = pointer.pointee
        guard stream.mSampleRate.isFinite, stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else {
            throw PowerError.badInput("The source audio format is invalid.")
        }
        var depth = stream.mBitsPerChannel
        if depth == 0, stream.mFormatID == kAudioFormatAppleLossless {
            depth = [kAppleLosslessFormatFlag_16BitSourceData: 16,
                     kAppleLosslessFormatFlag_20BitSourceData: 20,
                     kAppleLosslessFormatFlag_24BitSourceData: 24,
                     kAppleLosslessFormatFlag_32BitSourceData: 32][stream.mFormatFlags] ?? 24
        }
        var floating = stream.mFormatID == kAudioFormatLinearPCM && stream.mFormatFlags & kAudioFormatFlagIsFloat != 0
        if let url {
            var file: AudioFileID?
            if AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file {
                defer { AudioFileClose(file) }
                var nativeDepth: Int32 = 0
                var size = UInt32(MemoryLayout.size(ofValue: nativeDepth))
                if AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &nativeDepth) == noErr, nativeDepth != 0 {
                    depth = UInt32(abs(Int64(nativeDepth)))
                    floating = floating || nativeDepth < 0
                }
            }
        }
        if depth == 0 { depth = 24 }
        var size = 0
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size)
        let layoutData = withExtendedLifetime(description) {
            layout.flatMap { size > 0 ? Data(bytes: $0, count: size) : nil }
        }
        return MediaPCM(sampleRate: stream.mSampleRate, channels: stream.mChannelsPerFrame,
            bitDepth: depth, isFloat: floating, channelLayout: layoutData)
    }

    // A 32-bit integer client preserves 24-bit input exactly. Float sources use
    // their native precision. Only the destination chooses a lower integer depth.
    var clientDepth: UInt32 { isFloat && bitDepth > 32 ? 64 : 32 }
    var bytesPerFrame: UInt32 { channels * clientDepth / 8 }
    var settings: [String: Any] {
        var result: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: clientDepth, AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
        if let channelLayout { result[AVChannelLayoutKey] = channelLayout }
        return result
    }
    var clientDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels, mBitsPerChannel: clientDepth, mReserved: 0)
    }
    var integerDepth: UInt32 { min(24, max(8, bitDepth)) }
    var alacDepth: UInt32 { integerDepth <= 16 ? 16 : (integerDepth <= 20 ? 20 : 24) }
}
