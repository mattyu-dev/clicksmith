import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import ClicksmithCore

/// Regressions from the 2026-11-16 end-to-end media test (T-0015).
@Suite(.serialized) struct MediaPolishTests {
    private func date(_ text: String) throws -> Date { try #require(MediaMetadata.parseDate(text)) }

    private func creationTag(_ url: URL) async throws -> String? {
        for item in try await AVURLAsset(url: url).load(.metadata) where MediaMetadata.isCreationDate(item) {
            if let value = try await item.load(.stringValue) { return value }
        }
        return nil
    }

    private func fileDates(_ url: URL) throws -> (created: Date, modified: Date) {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return (try #require(values.creationDate), try #require(values.contentModificationDate))
    }

    // 1. Convert Video keeps the recording date.
    @Test func convertVideoKeepsTaggedDateLocationAndFileDates() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let old = try date("2019-01-02T03:04:05Z")
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: fixture.video.path)
        let output = fixture.directory.appendingPathComponent("hevc.mp4")
        try await MediaEngine.convertVideo(fixture.video, preset: .hevc_720, output: output)
        let recorded = try date("2026-11-16T10:11:12Z")
        let header = try #require(try MediaAtoms.movieCreationDate(output))
        #expect(abs(header.timeIntervalSince(recorded)) < 1)
        #expect(try await creationTag(output) == "2026-11-16T10:11:12Z")
        let values = try await AVURLAsset(url: output).load(.metadata)
        var location = false
        for item in values where (try await item.load(.stringValue))?.hasPrefix("+48.8566+002.3522") == true { location = true }
        #expect(location)
        let dates = try fileDates(output)
        #expect(abs(dates.created.timeIntervalSince(old)) < 1 && abs(dates.modified.timeIntervalSince(old)) < 1)
    }

    @Test func headerOnlyDateSurvivesVideoAudioAndCompress() async throws {
        let fixture = try await MediaFixture.make(metadata: false)
        defer { fixture.remove() }
        let recorded = try date("2018-03-04T05:06:07Z")
        try MediaAtoms.setMovieDates(fixture.video, to: recorded)
        // Independent check of the patch: AVFoundation reads the movie header.
        let source = try await AVURLAsset(url: fixture.video).load(.creationDate)
        #expect(try await source?.load(.dateValue) == recorded)
        #expect(try await MediaMetadata.sourceDate(AVURLAsset(url: fixture.video)) == recorded)

        let outputs = [("h264.mp4", VideoPreset.h264_720), ("proxy.mov", .prores_proxy)].map {
            (fixture.directory.appendingPathComponent($0.0), $0.1)
        }
        for (output, preset) in outputs {
            try await MediaEngine.convertVideo(fixture.video, preset: preset, output: output)
            #expect(try MediaAtoms.movieCreationDate(output) == recorded)
            let tag = try #require(try await creationTag(output))
            #expect(MediaMetadata.parseDate(tag) == recorded)
        }
        let audio = fixture.directory.appendingPathComponent("sound.m4a")
        try await MediaEngine.extractAudio(fixture.video, format: .aac, output: audio)
        #expect(try MediaAtoms.movieCreationDate(audio) == recorded)
        #expect(MediaMetadata.parseDate(try #require(try await creationTag(audio))) == recorded)
        let small = fixture.directory.appendingPathComponent("small.mp4")
        _ = try await MediaEngine.compress(fixture.video, targetBytes: 60_000, output: small)
        #expect(try MediaAtoms.movieCreationDate(small) == recorded)
    }

    // 2. Compress to Size never grows a file that already fits.
    @Test func compressRefusesFileThatAlreadyFits() async throws {
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let before = names(fixture.directory)
        let output = fixture.directory.appendingPathComponent("colors 24 MB.mp4")
        do {
            _ = try await MediaEngine.compress(fixture.video, targetBytes: 24_000_000, output: output)
            Issue.record("Compress re-encoded a file that already fits.")
        } catch let error as PowerError {
            #expect(error == .badInput("“colors.mov” is already under 24 MB."))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(names(fixture.directory) == before)
        #expect(MediaEngine.compressAudioBitrate(totalBitsPerSecond: 3_200_000) == 160_000)
        #expect(MediaEngine.compressAudioBitrate(totalBitsPerSecond: 1_500_000) == 128_000)
        #expect(MediaEngine.compressAudioBitrate(totalBitsPerSecond: 150_000) == 96_000)
    }

    // 3. ALAC keeps the exact sample count for every decoder.
    @Test func alacKeepsExactSampleCount() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try MediaFixture.makeTone(in: directory, frames: 100_858, sampleRate: 22_050, channels: 1)
        let output = directory.appendingPathComponent("speech.m4a")
        try await MediaEngine.convertAudio(input, format: .alac, output: output)
        #expect(try AVAudioFile(forReading: output).length == 100_858)
        let duration = try await AVURLAsset(url: output).load(.duration)
        #expect(duration == CMTime(value: 100_858, timescale: 22_050))
        let ffprobe = "/opt/homebrew/bin/ffprobe"
        if FileManager.default.isExecutableFile(atPath: ffprobe) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-count_packets", "-show_entries", "stream=duration_ts",
                                 "-of", "default=nw=1:nk=1", output.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == "100858")
        }
        // Same check through the WAV decoder path.
        let back = directory.appendingPathComponent("back.wav")
        try await MediaEngine.convertAudio(output, format: .wav, output: back)
        #expect(try AVAudioFile(forReading: back).length == 100_858)
    }

    // 4. GIF plays at the real speed.
    @Test func gifTotalDurationIsExact() async throws {
        let delays = MediaEngine.gifDelays(count: 240, interval: 1.0 / 12, total: 20)
        #expect(delays.reduce(0, +) == 2000)
        #expect(Set(delays).isSubset(of: [8, 9]))
        let fixture = try await MediaFixture.make()
        defer { fixture.remove() }
        let output = fixture.directory.appendingPathComponent("clip.gif")
        try await MediaEngine.videoToGIF(fixture.video, maxWidth: 64, fps: 12, output: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        var total = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any])
            let gif = try #require(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
            total += try #require(gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
        }
        #expect(abs(total - 2) < 0.02)
    }

    // 5. Audio names and channel/bitrate choices.
    @Test func audioNamesKeepMonoAndSaneBitrates() async throws {
        let wav = URL(fileURLWithPath: "/x/speech.wav")
        #expect(ConvertAudioAction.suffix(for: wav, format: .aac) == "")
        #expect(ConvertAudioAction.suffix(for: wav, format: .wav) == "wav")
        #expect(ConvertAudioAction.suffix(for: URL(fileURLWithPath: "/x/song.M4A"), format: .alac) == "alac")
        #expect(MediaAudio.defaultBitrate(.opus, channels: 2) == 96_000)
        #expect(MediaAudio.defaultBitrate(.opus, channels: 1) == 64_000)
        #expect(MediaAudio.defaultBitrate(.aac, channels: 2) == 192_000)
        #expect(MediaAudio.defaultBitrate(.aac, channels: 1) == 128_000)

        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try MediaFixture.makeTone(in: directory, frames: 22_050 * 20, sampleRate: 22_050, channels: 1)
        var c = context([input]); c.options = ["format": AudioFormat.aac.rawValue]
        let aac = try #require(try await ConvertAudioAction().run(c).created.first)
        #expect(aac.lastPathComponent == "speech.m4a")
        #expect(try AVAudioFile(forReading: aac).fileFormat.channelCount == 1)
        let formats = MediaEngine.writableAudioFormats()
        if formats.contains(.opus) {
            let opus = directory.appendingPathComponent("speech.caf")
            try await MediaEngine.convertAudio(input, format: .opus, output: opus)
            #expect(try AVAudioFile(forReading: opus).fileFormat.channelCount == 1)
            // Was 188 kb/s stereo: 2.5 ms packets plus a header reserve that grew with them.
            #expect(try await MediaEngine.info(opus).bitrate < 90_000)
        }
    }

    // 6. A killed job's scratch folder is removed by the next job.
    @Test func staleScratchIsSweptByNextJob() async throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = MediaIO.scratchRoot(near: directory)
        #expect(root.lastPathComponent == "Clicksmith Media")
        let stale = try ScratchFixture.folder(in: root, pid: try ScratchFixture.deadPID())
        let fresh = try ScratchFixture.folder(in: root, pid: try ScratchFixture.deadPID(), old: false)
        defer { try? FileManager.default.removeItem(at: fresh) }
        // The user's output folder is never swept, even for our exact pattern.
        let userFile = try touch(directory, ".clicksmith-media-source.wav")
        let lookalike = try ScratchFixture.folder(in: directory, pid: try ScratchFixture.deadPID())
        try ScratchFixture.age(userFile)
        let input = try MediaFixture.makeTone(in: directory, frames: 48_000, sampleRate: 48_000, channels: 2)
        try await MediaEngine.convertAudio(input, format: .aac, output: directory.appendingPathComponent("out.m4a"))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: userFile.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
    }

    @Test func sweepDeletesOnlyProvablyAbandonedScratch() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dead = try ScratchFixture.deadPID()
        let fm = FileManager.default
        // Kept: user files and folders that only look like ours.
        let userFile = try touch(root, ".clicksmith-media-source.wav")
        let uuidFile = try touch(root, "\(MediaIO.scratchPrefix)\(UUID().uuidString)")
        let noMarker = root.appendingPathComponent("\(MediaIO.scratchPrefix)\(UUID().uuidString)")
        try fm.createDirectory(at: noMarker, withIntermediateDirectories: false)
        _ = try touch(noMarker, "output.mp4")
        let badName = try ScratchFixture.folder(in: root, name: "\(MediaIO.scratchPrefix)not-a-uuid", pid: dead)
        let markerIsFolder = root.appendingPathComponent("\(MediaIO.scratchPrefix)\(UUID().uuidString)")
        try fm.createDirectory(at: markerIsFolder.appendingPathComponent(MediaIO.ownerMarker), withIntermediateDirectories: true)
        let target = try ScratchFixture.folder(in: try tempDir("target"), pid: dead)
        defer { try? fm.removeItem(at: target.deletingLastPathComponent()) }
        let link = root.appendingPathComponent("\(MediaIO.scratchPrefix)\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let live = try ScratchFixture.folder(in: root, pid: getpid())
        let locked = try ScratchFixture.folder(in: root, pid: dead)
        let fresh = try ScratchFixture.folder(in: root, pid: dead, old: false)
        // Removed: exact name, our marker, old, unlocked, owner process gone.
        let abandoned = try ScratchFixture.folder(in: root, pid: dead)
        for item in [userFile, uuidFile, noMarker, markerIsFolder] { try ScratchFixture.age(item) }
        let fd = open(locked.appendingPathComponent(MediaIO.ownerMarker).path, O_RDONLY)
        #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { close(fd) }

        MediaIO.sweepStale(in: root)
        for kept in [userFile, uuidFile, noMarker, badName, markerIsFolder, link, live, locked, fresh, target] {
            #expect(fm.fileExists(atPath: kept.path), "\(kept.lastPathComponent) must stay")
        }
        #expect(!fm.fileExists(atPath: abandoned.path))
    }

    @Test func runningJobHoldsItsScratchLock() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = try MediaIO.makeScratch(in: root)
        let marker = try String(contentsOf: scratch.directory.appendingPathComponent(MediaIO.ownerMarker), encoding: .utf8)
        #expect(marker.hasPrefix("\(getpid()) "))
        try ScratchFixture.age(scratch.directory)
        // A paused job, a day old: its lock (and live pid) protect it.
        MediaIO.sweepStale(in: root, now: Date(timeIntervalSinceNow: 7 * 86_400))
        #expect(FileManager.default.fileExists(atPath: scratch.directory.path))
        close(scratch.lock)
    }

    // Codex review: malformed headers must throw, never trap, never change the file.
    @Test func malformedMovieHeadersNeverCrashOrChangeTheFile() throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ftyp = AtomFixture.box("ftyp", Array("isom".utf8) + [0, 0, 0, 0])
        let mvhd = AtomFixture.box("mvhd", [0] + [UInt8](repeating: 0, count: 99))
        let mvhdV1Short = AtomFixture.box("mvhd", [1, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
        let soundTrak = AtomFixture.box("trak", AtomFixture.box("tkhd", []) + AtomFixture.box("mdia",
            AtomFixture.box("hdlr", [UInt8](repeating: 0, count: 8) + Array("soun".utf8)) + AtomFixture.box("mdhd", [])
            + AtomFixture.box("minf", AtomFixture.box("stbl", AtomFixture.box("stts", [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])))))
        var largeHuge = [UInt8](repeating: 0, count: 16)
        largeHuge[3] = 1; largeHuge.replaceSubrange(4..<8, with: Array("mvhd".utf8))
        for i in 8..<16 { largeHuge[i] = 0xFF }
        var largeSmall = largeHuge
        for i in 8..<16 { largeSmall[i] = 0 }
        largeSmall[15] = 8
        let cases: [(String, [UInt8])] = [
            ("empty mvhd", ftyp + AtomFixture.box("moov", AtomFixture.box("mvhd", []))),
            ("short v1 mvhd", ftyp + AtomFixture.box("moov", mvhdV1Short)),
            ("empty tkhd and mdhd", ftyp + AtomFixture.box("moov", mvhd + AtomFixture.box("trak",
                AtomFixture.box("tkhd", []) + AtomFixture.box("mdia", AtomFixture.box("mdhd", []))))),
            ("sound track with empty headers and huge stts count", ftyp + AtomFixture.box("moov", mvhd + soundTrak)),
            ("truncated moov", ftyp + Array(AtomFixture.box("moov", mvhd).prefix(40))),
            ("child box claims more than parent", ftyp + AtomFixture.box("moov", [0, 0, 0x10, 0] + Array("mvhd".utf8) + [0, 0, 0, 0])),
            ("size smaller than header", ftyp + AtomFixture.box("moov", [0, 0, 0, 4] + Array("mvhd".utf8))),
            ("top-level size smaller than header", ftyp + [0, 0, 0, 3] + Array("moov".utf8)),
            ("huge 32-bit size", ftyp + [0xFF, 0xFF, 0xFF, 0xFF] + Array("moov".utf8) + mvhd),
            ("huge 64-bit size", ftyp + AtomFixture.box("moov", largeHuge)),
            ("64-bit size below header", ftyp + AtomFixture.box("moov", largeSmall)),
            ("size zero runs to end", ftyp + [0, 0, 0, 0] + Array("moov".utf8) + AtomFixture.box("mvhd", [])),
            ("no moov", ftyp),
            // Codex re-review: count × delta and the running sum overflow Int64.
            // Empty mvhd: setMovieDates must fail too, so the file stays unchanged.
            ("stts overflow", ftyp + AtomFixture.box("moov", AtomFixture.box("mvhd", []) + AtomFixture.soundTrak(stts:
                [0, 0, 0, 0, 0, 0, 0, 3] + [UInt8](repeating: 0xFF, count: 24)))),
            ("stts sum overflow", ftyp + AtomFixture.box("moov", AtomFixture.box("mvhd", []) + AtomFixture.soundTrak(stts:
                [0, 0, 0, 0, 0, 0, 0, 3] + [UInt8](repeating: 0x7F, count: 24)))),
        ]
        for (name, bytes) in cases {
            let url = directory.appendingPathComponent("case.mp4")
            try Data(bytes).write(to: url)
            _ = try? MediaAtoms.movieCreationDate(url)
            _ = try? MediaAtoms.setMovieDates(url, to: Date(timeIntervalSince1970: 1_500_000_000))
            _ = try? MediaAtoms.trimSoundTrack(url, validFrames: 10)
            #expect(try Data(contentsOf: url) == Data(bytes), "\(name): file changed")
        }
        let empty = directory.appendingPathComponent("empty.mp4")
        try Data(ftyp + AtomFixture.box("moov", AtomFixture.box("mvhd", []))).write(to: empty)
        #expect(throws: PowerError.self) { try MediaAtoms.setMovieDates(empty, to: Date()) }
        #expect(throws: PowerError.self) { try MediaAtoms.movieCreationDate(empty) }
        let overflow = directory.appendingPathComponent("overflow.m4a")
        let overflowBytes = ftyp + AtomFixture.box("moov", mvhd + AtomFixture.soundTrak(stts:
            [0, 0, 0, 0, 0, 0, 0, 1] + [UInt8](repeating: 0xFF, count: 8)))
        try Data(overflowBytes).write(to: overflow)
        #expect(throws: PowerError.self) { try MediaAtoms.trimSoundTrack(overflow, validFrames: 10) }
        #expect(throws: PowerError.self) { try MediaAtoms.trimSoundTrack(overflow, validFrames: .max) }
        #expect(try Data(contentsOf: overflow) == Data(overflowBytes))

        // A well-formed header still round-trips.
        let good = directory.appendingPathComponent("good.mp4")
        try Data(ftyp + AtomFixture.box("moov", mvhd)).write(to: good)
        let when = Date(timeIntervalSince1970: 1_500_000_000)
        try MediaAtoms.setMovieDates(good, to: when)
        #expect(try MediaAtoms.movieCreationDate(good) == when)
    }
}

enum AtomFixture {
    /// A sound track with valid v0 tkhd/mdhd/hdlr and the given stts payload.
    static func soundTrak(stts: [UInt8]) -> [UInt8] {
        let mdhd = [UInt8](repeating: 0, count: 12) + [0, 0, 0x56, 0x22] + [0, 0, 0, 0] + [0, 0, 0, 0]
        return box("trak", box("tkhd", [UInt8](repeating: 0, count: 84)) + box("mdia",
            box("mdhd", mdhd) + box("hdlr", [UInt8](repeating: 0, count: 8) + Array("soun".utf8) + [UInt8](repeating: 0, count: 13))
            + box("minf", box("stbl", box("stts", stts)))))
    }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count + 8)
        return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: size >> $0) } + Array(type.utf8) + payload
    }
}

enum ScratchFixture {
    /// A pid that just exited.
    static func deadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    static func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: url.path)
    }

    static func folder(in root: URL, name: String? = nil, pid: Int32, old: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent(name ?? "\(MediaIO.scratchPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        _ = try touch(folder, "output.mp4")
        _ = try touch(folder, MediaIO.ownerMarker, "\(pid) 1700000000\n")
        if old { try age(folder) }
        return folder
    }
}
