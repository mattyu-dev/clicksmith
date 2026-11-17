import AVFoundation
import AudioToolbox
import Foundation

public enum VideoPreset: String, Codable, Sendable, CaseIterable {
    case h264_1080, h264_720, hevc_1080, hevc_720, hevc_4k, prores_proxy

    var codec: AVVideoCodecType {
        switch self {
        case .h264_1080, .h264_720: .h264
        case .hevc_1080, .hevc_720, .hevc_4k: .hevc
        case .prores_proxy: .proRes422Proxy
        }
    }

    var bounds: CGSize {
        switch self {
        case .h264_720, .hevc_720: CGSize(width: 1280, height: 720)
        case .hevc_4k: CGSize(width: 3840, height: 2160)
        default: CGSize(width: 1920, height: 1080)
        }
    }
}

public enum AudioFormat: String, Codable, Sendable, CaseIterable {
    case aac, alac, wav, aiff, flac, opus

    public var title: String { self == .opus ? "Opus (.caf)" : rawValue.uppercased() }
    var isLossless: Bool { self != .aac && self != .opus }

    /// AAC and ALAC use M4A. System Opus encoding uses CAF, not an Ogg container.
    public var fileExtension: String {
        switch self {
        case .aac, .alac: "m4a"
        case .opus: "caf"
        default: rawValue
        }
    }

    var fileType: AudioFileTypeID {
        switch self {
        case .aac, .alac: kAudioFileM4AType
        case .wav: kAudioFileWAVEType
        case .aiff: kAudioFileAIFFType
        case .flac: kAudioFileFLACType
        case .opus: kAudioFileCAFType
        }
    }

    var formatID: AudioFormatID {
        switch self {
        case .aac: kAudioFormatMPEG4AAC
        case .alac: kAudioFormatAppleLossless
        case .wav, .aiff: kAudioFormatLinearPCM
        case .flac: kAudioFormatFLAC
        case .opus: kAudioFormatOpus
        }
    }

    func description(pcm: MediaPCM = .lossy) throws -> AudioStreamBasicDescription {
        var result = AudioStreamBasicDescription()
        result.mSampleRate = pcm.sampleRate
        result.mChannelsPerFrame = pcm.channels
        result.mFormatID = formatID
        if self == .flac || self == .alac {
            // Apple's FLAC and ALAC encoders take the source precision in
            // mFormatFlags (1 = 16-bit, 2 = 20-bit, 3 = 24-bit source data).
            // Measured on macOS 27: FLAC with flag 3 round-trips 24-bit PCM
            // exactly; the 32-bit flag (4) is rejected. Depth is capped at 24.
            result.mFormatFlags = pcm.alacDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData
                : (pcm.alacDepth == 20 ? kAppleLosslessFormatFlag_20BitSourceData : kAppleLosslessFormatFlag_24BitSourceData)
            var size = UInt32(MemoryLayout.size(ofValue: result))
            try MediaIO.check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &result),
                              "Cannot configure the \(title) encoder.")
            return result
        }
        if formatID == kAudioFormatLinearPCM {
            let floating = self == .wav && pcm.isFloat
            result.mFormatFlags = (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked
            if self == .aiff { result.mFormatFlags |= kAudioFormatFlagIsBigEndian }
            result.mBitsPerChannel = floating ? pcm.clientDepth : pcm.integerDepth
            if !floating, result.mBitsPerChannel % 8 != 0 {
                result.mFormatFlags &= ~kAudioFormatFlagIsPacked
                result.mFormatFlags |= kAudioFormatFlagIsAlignedHigh
            }
            if self == .wav, result.mBitsPerChannel == 8 {
                result.mFormatFlags &= ~kAudioFormatFlagIsSignedInteger
            }
            result.mFramesPerPacket = 1
            result.mBytesPerFrame = pcm.channels * ((result.mBitsPerChannel + 7) / 8)
            result.mBytesPerPacket = result.mBytesPerFrame
        } else {
            // Opus defaults to 2.5 ms packets (120 frames): ten times the packet
            // overhead of the usual 20 ms. afconvert also uses 20 ms.
            if self == .opus { result.mFramesPerPacket = UInt32(pcm.sampleRate / 50) }
            var size = UInt32(MemoryLayout.size(ofValue: result))
            try MediaIO.check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &result),
                              "Cannot configure the audio encoder.")
        }
        return result
    }
}

public struct MediaInfo: Sendable {
    public let duration: Double
    public let size: Int64
    public let codecs: [String]
    public let bitrate: Int
    public let fps: Double
    /// Display dimensions, including the track's preferred transform.
    public let dimensions: CGSize?
    public let hasAudio: Bool
    public let hasVideo: Bool
}

public struct CompressReport: Sendable {
    public let before: Int64
    public let after: Int64
    public let resolution: CGSize?
    /// Measured total output bitrate, including audio and container overhead.
    public let bitrate: Int?
}
