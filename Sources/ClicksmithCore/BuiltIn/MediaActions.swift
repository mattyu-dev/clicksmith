import Foundation

/// Finder menu entries for the media engine (T-0008). All work is local (AVFoundation).
enum MediaExts {
    static let video = MediaEngine.readableVideoExtensions()
    static let audio = MediaEngine.readableAudioExtensions()
    static let any = video.union(audio)
}

private func output(_ c: ActionContext, _ url: URL, ext: String, suffix: String,
                    _ work: (URL) async throws -> Void) async throws -> URL {
    try await c.files.produce(base: OutputNamer.base(for: url, suffix: suffix), ext: ext,
                              in: url.deletingLastPathComponent(), async: work)
}

struct ConvertVideoAction: PerFileAction {
    let descriptor = ActionDescriptor(
        id: "media.convertVideo", title: "Convert Video", symbol: "film", group: .media,
        summary: "Re-encodes video on this Mac. Keeps orientation, date and location.",
        extensions: MediaExts.video,
        variants: [
            ActionVariant("MP4 (H.264, 1080p)", options: ["preset": VideoPreset.h264_1080.rawValue]),
            ActionVariant("MP4 (H.264, 720p)", options: ["preset": VideoPreset.h264_720.rawValue]),
            ActionVariant("HEVC 1080p (Smaller)", options: ["preset": VideoPreset.hevc_1080.rawValue]),
            ActionVariant("HEVC 720p", options: ["preset": VideoPreset.hevc_720.rawValue]),
            ActionVariant("HEVC 4K", options: ["preset": VideoPreset.hevc_4k.rawValue]),
            ActionVariant("ProRes Proxy (Editing)", options: ["preset": VideoPreset.prores_proxy.rawValue]),
        ], isLongRunning: true)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let preset = VideoPreset(rawValue: c.options["preset"] ?? "") else { throw PowerError.badInput("Choose a video format.") }
        let ext = preset == .prores_proxy ? "mov" : "mp4"
        let suffix = preset.rawValue.replacingOccurrences(of: "_", with: " ")
        return [try await output(c, url, ext: ext, suffix: suffix) {
            try await MediaEngine.convertVideo(url, preset: preset, output: $0, isCancelled: c.isCancelled)
        }]
    }
}

struct ConvertAudioAction: PerFileAction {
    let descriptor = ActionDescriptor(
        id: "media.convertAudio", title: "Convert Audio", symbol: "waveform", group: .media,
        summary: "Converts audio, or takes the sound out of a video. Lossless formats keep full quality.",
        extensions: MediaExts.any, isLongRunning: true)

    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu {
        .variants(MediaEngine.writableAudioFormats().map { ActionVariant($0.title, options: ["format": $0.rawValue]) })
    }

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let format = AudioFormat(rawValue: c.options["format"] ?? "") else { throw PowerError.badInput("Choose an audio format.") }
        return [try await output(c, url, ext: format.fileExtension, suffix: Self.suffix(for: url, format: format)) {
            try await MediaEngine.convertAudio(url, format: format, output: $0, isCancelled: c.isCancelled)
        }]
    }

    /// "speech.wav" → "speech.m4a". The format goes in the name only when the
    /// extension stays the same ("song.m4a" → "song alac.m4a"). Other clashes
    /// get the usual number from FileOps.
    static func suffix(for url: URL, format: AudioFormat) -> String {
        url.pathExtension.lowercased() == format.fileExtension ? format.rawValue : ""
    }
}

struct CompressMediaAction: PerFileAction {
    static let targets: [(String, Int64)] = [("For Discord (10 MB)", 10), ("For Email (24 MB)", 24), ("Under 50 MB", 50), ("Under 100 MB", 100)]
    let descriptor = ActionDescriptor(
        id: "media.compress", title: "Compress to Size", symbol: "arrow.down.right.and.arrow.up.left", group: .media,
        summary: "Makes a video or audio file fit a size limit, with the best quality that fits.",
        extensions: MediaExts.any,
        variants: CompressMediaAction.targets.map { ActionVariant($0.0, options: ["mb": "\($0.1)"]) }, isLongRunning: true)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let mb = Int64(c.options["mb"] ?? ""), mb > 0, mb <= 1_000_000 else { throw PowerError.badInput("Choose a size from 1 MB to 1 TB.") }
        let isVideo = MediaExts.video.contains(url.pathExtension.lowercased())
        return [try await output(c, url, ext: isVideo ? "mp4" : "m4a", suffix: "\(mb) MB") {
            _ = try await MediaEngine.compress(url, targetBytes: mb * 1_000_000, output: $0, isCancelled: c.isCancelled)
        }]
    }
}

struct MakeGIFAction: PerFileAction {
    let descriptor = ActionDescriptor(
        id: "media.gif", title: "Make GIF", symbol: "photo.stack", group: .media,
        summary: "Turns a video into an animated GIF (480 px wide, 12 fps; long clips use fewer frames).",
        extensions: MediaExts.video, isLongRunning: true)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        [try await output(c, url, ext: "gif", suffix: "") {
            try await MediaEngine.videoToGIF(url, output: $0, isCancelled: c.isCancelled)
        }]
    }
}
