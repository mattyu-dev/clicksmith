import AVFoundation
import AudioToolbox
import Foundation

/// One operation owns its scratch files. The caller journals the published output with FileOps.
struct MediaWork: Sendable {
    let progress: @Sendable (Double) -> Void
    let isCancelled: @Sendable () -> Bool

    func check() throws {
        if Task.isCancelled || isCancelled() { throw PowerError.cancelled }
    }

    func report(_ value: Double) throws {
        try check()
        progress(max(0, min(0.99, value)))
    }

    func pause() async throws {
        try check()
        try await Task.sleep(for: .milliseconds(5))
    }

    func pauseBlocking() throws {
        try check()
        Thread.sleep(forTimeInterval: 0.005)
    }
}

/// Owns cancellation across the caller's task and one dedicated media queue.
private final class MediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

/// Transfers a configured AV pipeline to its sole worker. The caller must not
/// access the contents after transfer. AVFoundation objects are not Sendable.
final class MediaTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum MediaIO {
    static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw PowerError.failed(message, detail: "OSStatus \(status)") }
    }

    static func size(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    static func asset(_ input: URL) throws -> AVURLAsset {
        guard input.isFileURL,
              (try? input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw PowerError.badInput("Choose a readable media file.")
        }
        return AVURLAsset(url: input, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    static func duration(_ asset: AVAsset) async throws -> Double {
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw PowerError.badInput("The media has no finite duration.") }
        return seconds
    }

    static func publish<T>(input: URL, output: URL, work: MediaWork,
                           body: (URL) async throws -> T) async throws -> T {
        var scratchDirectory: URL?
        var scratchLock: Int32 = -1
        defer { if scratchLock >= 0 { close(scratchLock) } }
        do {
            try work.report(0)
            _ = try asset(input)
            guard output.isFileURL, input.standardizedFileURL != output.standardizedFileURL else {
                throw PowerError.badInput("Choose a different output file.")
            }
            var existing = stat()
            guard lstat(output.path, &existing) != 0, errno == ENOENT else {
                throw PowerError.badInput("The output file already exists.")
            }
            let root = scratchRoot(near: output.deletingLastPathComponent())
            // Never sweep a user's output folder; a scratch folder placed there
            // (other volume) is removed by this job only.
            if root != output.deletingLastPathComponent() { sweepStale(in: root) }
            let (directory, lock) = try makeScratch(in: root)
            scratchLock = lock
            scratchDirectory = directory
            let scratch = directory.appendingPathComponent("output").appendingPathExtension(output.pathExtension)
            let value = try await body(scratch)
            try work.check()
            guard try size(scratch) > 0 else { throw PowerError.failed("The encoder wrote no media.") }
            // QuickTime-family writers stamp the movie header with today. Put the
            // source's recording date back so Finder, Photos and exiftool agree.
            if ["mp4", "m4v", "mov", "m4a"].contains(scratch.pathExtension.lowercased()),
               let date = try? await MediaMetadata.sourceDate(asset(input)) {
                // A header we cannot patch only loses the date, not the media.
                try? MediaAtoms.setMovieDates(scratch, to: date)
            }
            // Preserve the file system dates as well as metadata carried inside the container.
            let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
            var dates: [FileAttributeKey: Any] = [:]
            for key in [FileAttributeKey.creationDate, .modificationDate] { dates[key] = attributes[key] }
            if !dates.isEmpty { try FileManager.default.setAttributes(dates, ofItemAtPath: scratch.path) }
            try work.check()
            try FileOps.renameExclusive(scratch, output)
            try? FileManager.default.removeItem(at: directory)
            work.progress(1)
            return value
        } catch {
            if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
            if error is CancellationError || Task.isCancelled || work.isCancelled() { throw PowerError.cancelled }
            if let error = error as? PowerError { throw error }
            throw PowerError.failed("Could not process the media.", detail: error.localizedDescription)
        }
    }

    static let scratchPrefix = ".clicksmith-media-"
    static let ownerMarker = ".clicksmith-owner"
    static let staleScratchAge: TimeInterval = 86_400

    /// One fixed folder for scratch work, so a killed job's leftovers are found
    /// and removed by the next job. It must be on the output's volume, because
    /// publishing is an atomic rename. Other volumes use the output folder.
    static func scratchRoot(near directory: URL) -> URL {
        let fm = FileManager.default
        let shared = fm.temporaryDirectory.appendingPathComponent("Clicksmith Media", isDirectory: true)
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let target = (try? directory.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              let temporary = (try? fm.temporaryDirectory.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              target.isEqual(temporary),
              (try? fm.createDirectory(at: shared, withIntermediateDirectories: true)) != nil,
              isOwnDirectory(shared.path) else { return directory }
        return shared
    }

    /// A real directory (not a symlink) owned by this user.
    static func isOwnDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    /// Exactly prefix + UUID: the only names this engine creates.
    static func isScratchName(_ name: String) -> Bool {
        name.hasPrefix(scratchPrefix) && UUID(uuidString: String(name.dropFirst(scratchPrefix.count))) != nil
    }

    /// Creates a scratch folder with an ownership marker ("pid start-time").
    /// The returned descriptor holds an exclusive flock on the marker for the
    /// whole job; the caller closes it after removing the folder.
    static func makeScratch(in root: URL) throws -> (directory: URL, lock: Int32) {
        let directory = root.appendingPathComponent("\(scratchPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let marker = directory.appendingPathComponent(ownerMarker)
        let fd = open(marker.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let detail = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: directory)
            throw PowerError.failed("Cannot create the media scratch folder.", detail: detail)
        }
        let text = Array("\(getpid()) \(Int(Date().timeIntervalSince1970))\n".utf8)
        let written = text.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0, written == text.count else {
            close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw PowerError.failed("Cannot lock the media scratch folder.")
        }
        return (directory, fd)
    }

    /// Removes scratch folders of dead jobs from the shared scratch root only.
    /// A folder goes only when every check proves it is ours and abandoned:
    /// exact name, a real directory of this user, older than a day, our marker
    /// file, marker not locked by a running job, recorded pid not alive.
    static func sweepStale(in root: URL, now: Date = Date()) {
        guard isOwnDirectory(root.path),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where isScratchName(name) {
            let path = root.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > staleScratchAge else { continue }
            let marker = path + "/" + ownerMarker
            var markerInfo = stat()
            guard lstat(marker, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG else { continue }
            let fd = open(marker, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard count > 0,
                  let field = String(decoding: bytes.prefix(count), as: UTF8.self).split(separator: " ").first,
                  let pid = Int32(field), pid > 0 else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static var pcmSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
         AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
         AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
         AVLinearPCMIsBigEndianKey: false]
    }

    static var pcmDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }

    static func onWorker<T: Sendable>(work: MediaWork,
        _ body: @escaping @Sendable (MediaWork) throws -> T) async throws -> T {
        try work.check()
        let cancellation = MediaCancellation()
        let worker = MediaWork(progress: work.progress, isCancelled: { cancellation.isCancelled || work.isCancelled() })
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue(label: "org.clicksmith.media.\(UUID().uuidString)", qos: .utility)
                queue.async {
                    do { continuation.resume(returning: try body(worker)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    /// Called only on the media worker, after every append has returned. Wait for
    /// the completion callback, including after cancellation, before scratch cleanup.
    static func finish(_ writer: AVAssetWriter, work: MediaWork) throws {
        try work.check()
        let completion = DispatchSemaphore(value: 0)
        writer.finishWriting { completion.signal() }
        while completion.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
            do { try work.check() }
            catch {
                writer.cancelWriting()
                completion.wait()
                throw error
            }
        }
        guard writer.status == .completed else {
            throw PowerError.failed("Could not finish the media file.", detail: writer.error?.localizedDescription)
        }
        try work.check()
    }
}
