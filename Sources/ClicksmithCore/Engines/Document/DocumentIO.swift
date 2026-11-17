import Foundation
import Darwin

/// Scratch outputs only. Actions publish and journal them through FileOps.
enum DocumentIO {
    static func checked<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as PowerError { throw error }
        catch { throw PowerError.failed("The document operation failed.", detail: error.localizedDescription) }
    }

    static func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() || withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
            throw PowerError.cancelled
        }
    }

    static func requireFileURL(_ url: URL) throws {
        guard url.isFileURL else { throw PowerError.badInput("A local file URL is required.") }
    }

    static func requireAbsent(_ url: URL) throws {
        try requireFileURL(url)
        var value = stat()
        if lstat(url.path, &value) == 0 {
            throw PowerError.badInput("The output already exists: \(url.lastPathComponent).")
        }
        guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func scratch(near url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent().appendingPathComponent(".clicksmith-document-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    static func publish(_ source: URL, to output: URL) throws {
        guard renamex_np(source.path, output.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func single(_ output: URL, isCancelled: () -> Bool, writer: (URL) throws -> Void) throws {
        try requireAbsent(output)
        try checkCancellation(isCancelled)
        let dir = try scratch(near: output)
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("output").appendingPathExtension(output.pathExtension)
        try writer(temp)
        try checkCancellation(isCancelled)
        try publish(temp, to: output)
    }

    /// Roll back our unchanged outputs on failure. Keep files another process has changed.
    static func batch(_ directory: URL, isCancelled: () -> Bool, writer: (URL) throws -> [URL]) throws -> [URL] {
        try requireFileURL(directory)
        var identity = stat()
        guard lstat(directory.path, &identity) == 0, identity.st_mode & S_IFMT == S_IFDIR,
              try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw PowerError.badInput("The output directory must exist and be empty.")
        }
        try checkCancellation(isCancelled)
        let stage = try scratch(near: directory)
        defer { try? FileManager.default.removeItem(at: stage) }
        let files = try writer(stage)
        try checkCancellation(isCancelled)
        var current = stat()
        guard lstat(directory.path, &current) == 0, current.st_ino == identity.st_ino, current.st_dev == identity.st_dev,
              try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw PowerError.badInput("The output directory changed during the operation.")
        }
        var published: [(URL, Fingerprint?)] = []
        do {
            for file in files {
                try checkCancellation(isCancelled)
                let output = directory.appendingPathComponent(file.lastPathComponent)
                let fingerprint = Fingerprint.of(file)
                try publish(file, to: output)
                published.append((output, fingerprint))
            }
            return published.map(\.0)
        } catch {
            for (file, fingerprint) in published where fingerprint?.matches(file) == true {
                try? FileManager.default.removeItem(at: file)
            }
            throw error
        }
    }
}
