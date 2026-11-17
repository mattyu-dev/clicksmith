import AVFoundation
import Foundation

enum MediaVideo {
    static func scaledSize(_ natural: CGSize, transform: CGAffineTransform, bounds: CGSize) throws -> CGSize {
        guard natural.width.isFinite, natural.height.isFinite, natural.width >= 2, natural.height >= 2 else {
            throw PowerError.badInput("The video dimensions are invalid.")
        }
        let display = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        guard display.width.isFinite, display.height.isFinite, display.width > 0, display.height > 0 else {
            throw PowerError.badInput("The video transform is invalid.")
        }
        let limit = display.height > display.width ? CGSize(width: bounds.height, height: bounds.width) : bounds
        let scale = min(1, limit.width / display.width, limit.height / display.height)
        return CGSize(width: max(2, floor(natural.width * scale / 2) * 2),
                      height: max(2, floor(natural.height * scale / 2) * 2))
    }

    static func encode(_ asset: AVAsset, preset: VideoPreset, output: URL, work: MediaWork,
                       bitrate: Int? = nil, bounds: CGSize? = nil, multipass: Bool = false,
                       audioBitrate: Int = 96_000) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PowerError.badInput("The file has no video track.")
        }
        let duration = try await MediaIO.duration(asset)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalRate = try await track.load(.nominalFrameRate)
        let frameRate = nominalRate.isFinite && nominalRate > 0 ? nominalRate : 30
        let size = try scaledSize(natural, transform: transform, bounds: bounds ?? preset.bounds)
        let metadata = try await MediaMetadata.writerItems(asset, fileType: preset == .prores_proxy ? .mov : .mp4)
        let descriptions = try await track.load(.formatDescriptions)
        let extensions = descriptions.first.flatMap { CMFormatDescriptionGetExtensions($0) } as NSDictionary?
        let color = MediaColor(source: extensions, codec: preset.codec)
        let colors = color.properties
        let keepHDR = color.keepHDR

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: preset == .prores_proxy ? .mov : .mp4)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        var settings: [String: Any] = [AVVideoCodecKey: preset.codec, AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height), AVVideoColorPropertiesKey: colors]
        if keepHDR && preset == .prores_proxy { settings.removeValue(forKey: AVVideoColorPropertiesKey) }
        if preset != .prores_proxy {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate ?? Int(size.width * size.height * (preset.codec == .hevc ? 3 : 5)),
                AVVideoExpectedSourceFrameRateKey: max(1, frameRate),
                AVVideoMaxKeyFrameIntervalDurationKey: 2
            ]
            if preset.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if preset.codec == .hevc && keepHDR { compression[AVVideoProfileLevelKey] = "HEVC_Main10_AutoLevel" }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw PowerError.unsupported("This Mac cannot encode the selected video preset.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.performsMultiPassEncodingIfSupported = multipass
        // Pixel scaling changes the translation needed by a rotated or mirrored track.
        var orientation = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
        let rectangle = CGRect(origin: .zero, size: size).applying(orientation)
        orientation.tx = -rectangle.minX
        orientation.ty = -rectangle.minY
        videoInput.transform = orientation
        guard writer.canAdd(videoInput) else { throw PowerError.unsupported("Cannot write this video track.") }
        writer.add(videoInput)

        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = CMTime(seconds: 1 / Double(max(1, frameRate)), preferredTimescale: 60_000)
        composition.colorPrimaries = colors[AVVideoColorPrimariesKey]
        composition.colorTransferFunction = colors[AVVideoTransferFunctionKey]
        composition.colorYCbCrMatrix = colors[AVVideoYCbCrMatrixKey]
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(scaleX: size.width / natural.width, y: size.height / natural.height), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let pixelFormat = keepHDR
            ? (preset == .prores_proxy ? kCVPixelFormatType_422YpCbCr10 : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : kCVPixelFormatType_32BGRA
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOutput.videoComposition = composition
        videoOutput.supportsRandomAccess = multipass
        guard reader.canAdd(videoOutput) else { throw PowerError.unsupported("Cannot decode this video track.") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let source = AVAssetReaderTrackOutput(track: audio, outputSettings: MediaIO.pcmSettings)
            let destination = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioBitrate
            ])
            guard reader.canAdd(source), writer.canAdd(destination) else {
                throw PowerError.unsupported("Cannot encode the video's audio track.")
            }
            reader.add(source)
            writer.add(destination)
            audioOutput = source
            audioInput = destination
        }
        let pipeline = MediaTransfer((reader, writer, videoInput, videoOutput, audioInput, audioOutput))
        try await MediaIO.onWorker(work: work) { work in
            let (reader, writer, videoInput, videoOutput, audioInput, audioOutput) = pipeline.value
            defer {
                reader.cancelReading()
                if writer.status == .writing { writer.cancelWriting() }
            }
            try work.check()
            guard writer.startWriting() else {
                throw PowerError.failed("Cannot start the video encoder.", detail: String(describing: writer.error))
            }
            writer.startSession(atSourceTime: .zero)
            guard reader.startReading() else {
                throw PowerError.failed("Could not read video.", detail: reader.error?.localizedDescription)
            }
            var videoDone = false
            var audioDone = audioInput == nil
            var waitingPass: AVAssetWriterInputPassDescription?
            var maximumProgress = 0.0
            while !videoDone || !audioDone {
                try work.check()
                guard writer.status == .writing, reader.status != .failed else {
                    throw PowerError.failed("Video conversion failed.", detail: (writer.error ?? reader.error)?.localizedDescription)
                }
                var advanced = false
                if let waiting = waitingPass {
                    let next = videoInput.currentPassDescription
                    if next !== waiting {
                        waitingPass = nil
                        if let next {
                            videoOutput.reset(forReadingTimeRanges: next.sourceTimeRanges)
                        } else {
                            videoOutput.markConfigurationAsFinal()
                            videoInput.markAsFinished()
                            videoDone = true
                        }
                        advanced = true
                    }
                } else if !videoDone && videoInput.isReadyForMoreMediaData {
                    try autoreleasepool {
                        if let sample = videoOutput.copyNextSampleBuffer() {
                            if let pixel = CMSampleBufferGetImageBuffer(sample) { color.apply(to: pixel) }
                            guard videoInput.append(sample) else {
                                throw PowerError.failed("Could not encode a video frame.", detail: writer.error?.localizedDescription)
                            }
                            maximumProgress = max(maximumProgress, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                            try work.report(maximumProgress)
                        } else if reader.status == .failed {
                            throw PowerError.failed("Could not decode a video frame.", detail: reader.error?.localizedDescription)
                        } else if multipass && videoInput.canPerformMultiplePasses {
                            waitingPass = videoInput.currentPassDescription
                            videoInput.markCurrentPassAsFinished()
                        } else {
                            if multipass { videoOutput.markConfigurationAsFinal() }
                            videoInput.markAsFinished()
                            videoDone = true
                        }
                    }
                    advanced = true
                }
                if !audioDone, let audioOutput, let audioInput, audioInput.isReadyForMoreMediaData {
                    try autoreleasepool {
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            guard audioInput.append(sample) else {
                                throw PowerError.failed("Could not encode the audio track.", detail: writer.error?.localizedDescription)
                            }
                        } else {
                            audioInput.markAsFinished()
                            audioDone = true
                        }
                    }
                    advanced = true
                }
                if !advanced { try work.pauseBlocking() }
            }
            guard reader.status == .completed else {
                throw PowerError.failed("Could not finish reading the media.", detail: reader.error?.localizedDescription)
            }
            try MediaIO.finish(writer, work: work)
        }
    }
}
