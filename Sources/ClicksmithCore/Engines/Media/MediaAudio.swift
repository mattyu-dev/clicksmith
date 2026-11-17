import AVFoundation
import AudioToolbox
import Foundation

enum MediaAudio {
    /// Query both the container and converter. Decoder support alone is insufficient.
    static func supports(_ format: AudioFormat) -> Bool {
        var fileType = format.fileType
        var byteCount: UInt32 = 0
        guard AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_WritableTypes, 0, nil, &byteCount) == noErr else { return false }
        var writable = [AudioFileTypeID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_WritableTypes, 0, nil, &byteCount, &writable) == noErr,
              writable.contains(fileType) else { return false }
        guard AudioFileGetGlobalInfoSize(kAudioFileGlobalInfo_AvailableFormatIDs,
            UInt32(MemoryLayout.size(ofValue: fileType)), &fileType, &byteCount) == noErr else { return false }
        var ids = [AudioFormatID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioFormatID>.size)
        guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_AvailableFormatIDs,
            UInt32(MemoryLayout.size(ofValue: fileType)), &fileType, &byteCount, &ids) == noErr,
            ids.contains(format.formatID) else { return false }
        // Capability probing uses a 16-bit baseline. Source precision (up to
        // 24-bit, also for FLAC) is set per conversion in description(pcm:).
        guard var output = try? format.description(pcm: .init(sampleRate: 48_000, channels: 2, bitDepth: 16, isFloat: false)) else { return false }
        var input = MediaPCM.lossy.clientDescription
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return false }
        AudioConverterDispose(converter)
        return true
    }

    static func encode(_ asset: AVAsset, format: AudioFormat, output: URL, work: MediaWork,
                       bitrate: UInt32? = nil) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw PowerError.badInput("The file has no audio track.")
        }
        let duration = try await MediaIO.duration(asset)
        let pcm = format.isLossless ? try await MediaPCM.source(track, url: (asset as? AVURLAsset)?.url) : try await MediaPCM.lossy(for: track)
        let bitrate = bitrate ?? defaultBitrate(format, channels: pcm.channels)
        let items = try await MediaMetadata.writerItems(asset, fileType: .m4a)
        let text = try await MediaMetadata.text(asset)
        let standalone = try await asset.loadTracks(withMediaType: .video).isEmpty
        let pipeline = MediaTransfer((asset, track, items))
        try await MediaIO.onWorker(work: work) { worker in
            guard supports(format) else { throw PowerError.unsupported("This Mac cannot encode \(format.title).") }
            let (asset, track, items) = pipeline.value
            if format == .aac || format == .alac {
                try encodeM4A(asset, track: track, metadata: items, pcm: pcm, format: format,
                              output: output, work: worker, duration: duration, bitrate: bitrate)
            } else {
                try encodeFile(asset, track: track, metadata: text, pcm: pcm, standalone: standalone,
                               format: format, output: output, work: worker, duration: duration, bitrate: bitrate)
            }
        }
    }

    /// AAC 192/128 kb/s and Opus 96/64 kb/s (stereo/mono): transparent for
    /// music, and Opus stays well below lossless sizes.
    static func defaultBitrate(_ format: AudioFormat, channels: UInt32) -> UInt32 {
        switch format {
        case .opus: channels == 1 ? 64_000 : 96_000
        default: channels == 1 ? 128_000 : 192_000
        }
    }

    private static func encodeFile(_ asset: AVAsset, track: AVAssetTrack, metadata: [String: String],
        pcm: MediaPCM, standalone: Bool, format: AudioFormat, output: URL, work: MediaWork,
        duration: Double, bitrate: UInt32) throws {
        var description = try format.description(pcm: pcm)
        var opened: ExtAudioFileRef?
        try MediaIO.check(ExtAudioFileCreateWithURL(output as CFURL, format.fileType, &description, nil, 0, &opened),
                          "Cannot create the audio file.")
        guard let file = opened else { throw PowerError.failed("The audio encoder did not open.") }
        var disposed = false
        defer { if !disposed { ExtAudioFileDispose(file) } }
        var client = pcm.clientDescription
        try MediaIO.check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client), "Cannot configure PCM audio.")
        if let layout = pcm.channelLayout, pcm.channels > 2 {
            let status = layout.withUnsafeBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return kAudio_ParamError }
                return ExtAudioFileSetProperty(file, kExtAudioFileProperty_FileChannelLayout, UInt32(buffer.count), base)
            }
            try MediaIO.check(status, "Cannot preserve the audio channel layout.")
        }
        if format == .opus {
            var converter: AudioConverterRef?
            var size = UInt32(MemoryLayout.size(ofValue: converter))
            try MediaIO.check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter),
                              "Cannot configure the audio bitrate.")
            if let converter {
                var rate = bitrate
                try MediaIO.check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                    UInt32(MemoryLayout.size(ofValue: rate)), &rate), "Cannot set the audio bitrate.")
                var configuration: CFArray?
                let status = withUnsafePointer(to: &configuration) {
                    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), $0)
                }
                try MediaIO.check(status, "Cannot apply the audio bitrate.")
            }
        }
        try copyMetadata(metadata, to: file, format: format)
        var sourceFile: ExtAudioFileRef?
        defer { if let sourceFile { ExtAudioFileDispose(sourceFile) } }
        if standalone, let asset = asset as? AVURLAsset {
            if ExtAudioFileOpenURL(asset.url as CFURL, &sourceFile) == noErr, let sourceFile {
                try MediaIO.check(ExtAudioFileSetProperty(sourceFile, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout.size(ofValue: client)), &client), "Cannot decode PCM audio.")
            }
        }
        if let sourceFile {
            var framesRead: Int64 = 0
            var bytes = [UInt8](repeating: 0, count: 4096 * Int(pcm.bytesPerFrame))
            while true {
                try work.check()
                var frames: UInt32 = 4096
                try bytes.withUnsafeMutableBytes { data in
                    var buffer = AudioBufferList(mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: pcm.channels, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
                    try MediaIO.check(ExtAudioFileRead(sourceFile, &frames, &buffer), "Could not decode audio.")
                    if frames > 0 { try MediaIO.check(ExtAudioFileWrite(file, frames, &buffer), "Could not encode audio.") }
                }
                if frames == 0 { break }
                framesRead += Int64(frames)
                try work.report(Double(framesRead) / pcm.sampleRate / duration)
            }
        } else {
            let reader = try AVAssetReader(asset: asset)
            defer { reader.cancelReading() }
            let source = AVAssetReaderTrackOutput(track: track, outputSettings: pcm.settings)
            guard reader.canAdd(source) else { throw PowerError.unsupported("Cannot decode this audio track.") }
            reader.add(source)
            guard reader.startReading() else {
                throw PowerError.failed("Could not read audio.", detail: String(describing: reader.error))
            }
            while true {
                try work.check()
                let hasSample = try autoreleasepool {
                    guard let sample = source.copyNextSampleBuffer() else { return false }
                    guard let block = CMSampleBufferGetDataBuffer(sample) else {
                        throw PowerError.failed("The audio decoder returned no PCM data.")
                    }
                    var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                    try MediaIO.check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes),
                                      "Cannot read decoded audio.")
                    try bytes.withUnsafeMutableBytes { data in
                        var buffer = AudioBufferList(mNumberBuffers: 1,
                            mBuffers: AudioBuffer(mNumberChannels: pcm.channels, mDataByteSize: UInt32(data.count), mData: data.baseAddress))
                        try MediaIO.check(ExtAudioFileWrite(file, UInt32(CMSampleBufferGetNumSamples(sample)), &buffer), "Could not encode audio.")
                    }
                    try work.report(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                    return true
                }
                if !hasSample { break }
            }
            guard reader.status == .completed else {
                throw PowerError.failed("Could not decode audio.", detail: reader.error?.localizedDescription)
            }
        }
        let status = ExtAudioFileDispose(file)
        disposed = true
        try MediaIO.check(status, "Could not finish the audio file.")
        if format == .flac {
            // The system FLAC writer emits an unreadable file when the input is
            // shorter than one 4608-frame packet. Never publish such a file.
            var check: AudioFileID?
            guard AudioFileOpenURL(output as CFURL, .readPermission, 0, &check) == noErr, let check else {
                throw PowerError.unsupported("The audio is too short for FLAC. Use WAV, AIFF or ALAC.")
            }
            AudioFileClose(check)
        }
        try work.check()
    }

    private static func encodeM4A(_ asset: AVAsset, track: AVAssetTrack, metadata: [AVMetadataItem],
        pcm: MediaPCM, format: AudioFormat, output: URL, work: MediaWork, duration: Double, bitrate: UInt32) throws {
        let reader = try AVAssetReader(asset: asset)
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: pcm.settings)
        guard reader.canAdd(source) else { throw PowerError.unsupported("Cannot decode this audio track.") }
        reader.add(source)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        defer {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
        }
        writer.metadata = metadata
        var settings: [String: Any] = [AVFormatIDKey: format.formatID, AVSampleRateKey: pcm.sampleRate, AVNumberOfChannelsKey: pcm.channels]
        if let layout = pcm.channelLayout { settings[AVChannelLayoutKey] = layout }
        if format == .aac { settings[AVEncoderBitRateKey] = bitrate }
        else { settings[AVEncoderBitDepthHintKey] = pcm.alacDepth }
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw PowerError.unsupported("Cannot encode this audio format.") }
        let destination = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(destination) else { throw PowerError.unsupported("Cannot write this audio track.") }
        writer.add(destination)
        try work.check()
        guard writer.startWriting() else { throw PowerError.failed("Could not start the audio encoder.", detail: writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw PowerError.failed("Could not read audio.", detail: reader.error?.localizedDescription) }
        var frames: Int64 = 0
        while true {
            try work.check()
            guard writer.status == .writing else { throw PowerError.failed("Audio conversion failed.", detail: writer.error?.localizedDescription) }
            if !destination.isReadyForMoreMediaData { try work.pauseBlocking(); continue }
            let appended = try autoreleasepool {
                guard let sample = source.copyNextSampleBuffer() else { return false }
                guard destination.append(sample) else { throw PowerError.failed("Could not encode audio.", detail: writer.error?.localizedDescription) }
                frames += Int64(CMSampleBufferGetNumSamples(sample))
                try work.report(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                return true
            }
            if !appended { break }
        }
        guard reader.status == .completed else { throw PowerError.failed("Could not decode audio.", detail: reader.error?.localizedDescription) }
        destination.markAsFinished()
        try MediaIO.finish(writer, work: work)
        if format == .alac { try MediaAtoms.trimSoundTrack(output, validFrames: frames) }
    }

    private static func copyMetadata(_ metadata: [String: String], to file: ExtAudioFileRef, format: AudioFormat) throws {
        // The system FLAC writer has no user-chunk metadata contract. The lead
        // approved omitting unsupported FLAC tags rather than failing conversion.
        guard !metadata.isEmpty, format != .flac else { return }
        var audioFile: AudioFileID?
        var size = UInt32(MemoryLayout.size(ofValue: audioFile))
        try MediaIO.check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile), "Cannot preserve audio metadata.")
        guard let audioFile else { throw PowerError.failed("Cannot preserve audio metadata.") }
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let identifier: UInt32
        var data = Data()
        switch format {
        case .wav:
            identifier = 0x4C495354
            data.append(contentsOf: "INFOICMT".utf8)
            var length = UInt32(json.count + 1).littleEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(json); data.append(0)
            if data.count % 2 != 0 { data.append(0) }
        case .aiff:
            identifier = 0x414E4E4F
            data = json
        case .opus:
            identifier = 0x696E666F
            var count = UInt32(metadata.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            for key in metadata.keys.sorted() {
                data.append(contentsOf: key.utf8); data.append(0)
                data.append(contentsOf: (metadata[key] ?? "").utf8); data.append(0)
            }
        default: return
        }
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudio_ParamError }
            return AudioFileSetUserData(audioFile, identifier, 0, UInt32(buffer.count), base)
        }
        try MediaIO.check(status, "Cannot preserve audio metadata in this container.")
    }
}
