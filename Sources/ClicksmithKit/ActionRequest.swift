import Foundation
import Darwin

/// One click in Finder → one request file in the inbox (ADR-0003).
public struct ActionRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var actionID: String
    public var paths: [String]
    /// Folder the user right-clicked in (container) or the parent of the selection.
    public var targetDirectory: String?
    public var options: [String: String]
    public var created: Date
    public var source: Source

    public enum Source: String, Codable, Sendable { case finder, cli, palette, shortClick, service }

    public init(id: UUID = UUID(), actionID: String, paths: [String], targetDirectory: String? = nil, options: [String: String] = [:], created: Date = Date(), source: Source) {
        self.id = id; self.actionID = actionID; self.paths = paths; self.targetDirectory = targetDirectory
        self.options = options; self.created = created; self.source = source
    }

    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    /// URL that wakes the app for this request.
    public func wakeURL(scheme: String = SharedPaths.urlScheme) -> URL {
        URL(string: "\(scheme)://run/\(id.uuidString)")!
    }

    /// Requests that open a window (Settings, Batch Rename without rules, the "Choose Folder…" picker of
    /// Copy To/Move To). Their wake activates the app, or the window opens behind Finder. All other
    /// wakes keep Finder in front (T-0019). A favourite-folder Copy To/Move To opens nothing.
    public var needsFocus: Bool {
        switch actionID {
        case "app.open": true
        case "organize.batchRename": options["rules"] == nil
        case "organize.copyTo", "organize.moveTo": options["dest"] == nil || options["dest"] == "?choose"
        default: false
        }
    }

    /// Parse `clicksmith://run/<uuid>`.
    public static func requestID(from url: URL) -> UUID? {
        guard url.scheme == SharedPaths.urlScheme, url.host == "run" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

/// File-based queue shared by extension (producer) and app (consumer).
public struct RequestInbox: Sendable {
    public let paths: SharedPaths
    public init(paths: SharedPaths) { self.paths = paths }

    private var claimedDirectory: URL { paths.inbox.appendingPathComponent("claimed", isDirectory: true) }
    private var expiredDirectory: URL { paths.inbox.appendingPathComponent("expired", isDirectory: true) }
    private var inspectedDirectory: URL { paths.inbox.appendingPathComponent("inspected", isDirectory: true) }
    private func claimFile(_ id: UUID) -> URL { claimedDirectory.appendingPathComponent("\(id.uuidString).json") }
    private func marker(_ id: UUID) -> URL { claimedDirectory.appendingPathComponent("\(id.uuidString).started") }
    private func lease(_ id: UUID) -> URL { claimedDirectory.appendingPathComponent("\(id.uuidString).lock") }

    @discardableResult
    public func submit(_ request: ActionRequest) throws -> URL {
        try FileManager.default.createDirectory(at: claimedDirectory, withIntermediateDirectories: true)
        let fd = try RequestClaimLeases.openLock(lease(request.id))
        defer { RequestClaimLeases.closeLock(fd, at: lease(request.id)) }
        guard !Self.exists(claimFile(request.id)), !Self.exists(marker(request.id)), !hasArchivedEvidence(request.id) else {
            throw RequestInboxError.alreadyStarted
        }
        let url = paths.requestFile(request.id)
        let stage = paths.inbox.appendingPathComponent(".submit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try JSONEncoder.clicksmith.encode(request).write(to: stage, options: .withoutOverwriting)
        try Self.renameExclusive(stage, url)
        return url
    }

    /// IDs still at their original path. The extension's wake retry uses that path.
    public func pending() -> [UUID] { Self.ids(in: paths.inbox) }

    /// Atomically claim a request. Keep its bytes until the consumer acknowledges it.
    public func take(_ id: UUID) -> ActionRequest? {
        do {
            try FileManager.default.createDirectory(at: claimedDirectory, withIntermediateDirectories: true)
            guard RequestClaimLeases.shared.acquire(lease(id)) else { return nil }
            do {
                guard !Self.exists(marker(id)), !hasArchivedEvidence(id) else { throw RequestInboxError.alreadyStarted }
                try Self.renameExclusive(paths.requestFile(id), claimFile(id))
                let request = try readClaim(id)
                return request
            } catch {
                RequestClaimLeases.shared.release(lease(id))
                return nil
            }
        } catch { return nil }
    }

    /// Persist before executing any operation. A started request is never replayed,
    /// even if the process dies before acknowledgement. Direct CLI requests have no claim.
    public func markStarted(_ request: ActionRequest) throws {
        try RequestClaimLeases.shared.start(lease(request.id)) { ownsLease in
            guard Self.exists(claimFile(request.id)) else {
                if ownsLease || request.source == .finder { throw RequestInboxError.notClaimed }
                return
            }
            guard ownsLease, try readClaim(request.id) == request else { throw RequestInboxError.notClaimed }
            let fd = open(marker(request.id).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                if errno == EEXIST { throw RequestInboxError.alreadyStarted }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { close(fd) }
            // The marker's existence is the durable state. Keep it even if fsync fails.
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// Call after the run, including handled errors. Remove request before marker.
    public func acknowledge(_ id: UUID) throws {
        guard RequestClaimLeases.shared.owns(lease(id)) else { throw RequestInboxError.notClaimed }
        defer { RequestClaimLeases.shared.release(lease(id)) }
        if Self.exists(claimFile(id)) { try FileManager.default.removeItem(at: claimFile(id)) }
        if Self.exists(marker(id)) { try FileManager.default.removeItem(at: marker(id)) }
    }

    public func isClaimed(_ id: UUID) -> Bool { Self.exists(claimFile(id)) }

    /// Pending requests and unstarted crash claims expire at the same age. A crash
    /// claim recovers only before its started marker exists. Live leases exclude
    /// concurrent drains and URL wakes.
    public func drain(maxAge: TimeInterval = 600, now: Date = Date()) -> [ActionRequest] {
        var out: [ActionRequest] = []
        // Recover first, so newly taken requests are not returned twice in this drain.
        for id in Self.ids(in: claimedDirectory) where !Self.exists(marker(id)) {
            guard RequestClaimLeases.shared.acquire(lease(id)) else { continue }
            guard !Self.exists(marker(id)), !hasArchivedEvidence(id) else {
                RequestClaimLeases.shared.release(lease(id))
                continue
            }
            do {
                let request = try readClaim(id)
                if now.timeIntervalSince(request.created) <= maxAge { out.append(request) }
                else { try expire(id) }
            }
            catch { RequestClaimLeases.shared.release(lease(id)) }
        }
        for id in pending() {
            guard let request = take(id) else { continue }
            if now.timeIntervalSince(request.created) <= maxAge { out.append(request) }
            else {
                do { try expire(id) }
                catch { RequestClaimLeases.shared.release(lease(id)) }
            }
        }
        // Garbage at the producer path is app-owned, never a claimed operation.
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.inbox, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) == nil {
            try? FileManager.default.removeItem(at: file)
        }
        return out.sorted { $0.created < $1.created }
    }

    /// Report abandoned started or expired requests once. Move their evidence out of
    /// the runnable queue before returning. This runs before the startup drain.
    public func interrupted() -> [UUID] {
        var reported = Set<UUID>()
        for id in Self.ids(in: expiredDirectory, extensions: ["json", "started"]) {
            guard RequestClaimLeases.shared.acquire(lease(id)) else { continue }
            defer { RequestClaimLeases.shared.release(lease(id)) }
            do {
                if try archive(id, from: expiredDirectory, to: inspectedDirectory) { reported.insert(id) }
            } catch { /* Keep pending evidence for a later inspection attempt. */ }
        }
        let now = Date()
        for id in Self.ids(in: claimedDirectory, extensions: ["json", "started", "lock"]) {
            guard RequestClaimLeases.shared.acquire(lease(id)) else { continue }
            defer { RequestClaimLeases.shared.release(lease(id)) }
            let started = Self.exists(marker(id))
            let expired = (try? readClaim(id)).map { now.timeIntervalSince($0.created) > 600 } ?? false
            guard started || expired else { continue }
            do {
                if try archive(id, from: claimedDirectory, to: inspectedDirectory) { reported.insert(id) }
            } catch { /* Preserve unarchived requests and markers. Never replay started work. */ }
        }
        return reported.sorted { $0.uuidString < $1.uuidString }
    }

    /// Keep startup alerts bounded even if many clicks were interrupted while offline.
    public static func interruptionSummary(_ ids: [UUID], limit: Int = 10) -> String {
        let count = min(max(limit, 0), 10)
        var lines = ids.prefix(count).map {
            "Request \($0.uuidString) was interrupted or expired. It was kept for inspection and will not run again."
        }
        if ids.count > count { lines.append("+\(ids.count - count) more") }
        return lines.joined(separator: "\n")
    }

    private func hasArchivedEvidence(_ id: UUID) -> Bool {
        [expiredDirectory, inspectedDirectory].contains { directory in
            ["json", "started"].contains { ext in
                Self.exists(directory.appendingPathComponent("\(id.uuidString).\(ext)"))
            }
        }
    }

    private func expire(_ id: UUID) throws {
        _ = try archive(id, from: claimedDirectory, to: expiredDirectory)
        RequestClaimLeases.shared.release(lease(id))
    }

    /// Move the request before its marker. A crash between those renames must not
    /// leave a runnable claim whose started marker has already moved away.
    private func archive(_ id: UUID, from source: URL, to destination: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var moved = false
        for ext in ["json", "started"] {
            let from = source.appendingPathComponent("\(id.uuidString).\(ext)")
            guard Self.exists(from) else { continue }
            try Self.renameExclusive(from, destination.appendingPathComponent(from.lastPathComponent))
            moved = true
        }
        return moved
    }

    private func readClaim(_ id: UUID) throws -> ActionRequest {
        let request = try JSONDecoder.clicksmith.decode(ActionRequest.self, from: Data(contentsOf: claimFile(id)))
        guard request.id == id else { throw RequestInboxError.notClaimed }
        return request
    }

    private static func ids(in directory: URL, extensions: Set<String> = ["json"]) -> [UUID] {
        let ids = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension) }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        return Array(Set(ids))
    }

    private static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    private static func renameExclusive(_ from: URL, _ to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public enum RequestInboxError: Error, LocalizedError {
    case notClaimed, alreadyStarted
    public var errorDescription: String? {
        switch self {
        case .notClaimed: "This request is not claimed by this process."
        case .alreadyStarted: "This request has already started and will not be replayed."
        }
    }
}

/// Shared across inbox values in one process. flock releases ownership on exit.
/// Retire lock paths while holding flock. New owners validate the opened inode
/// against the path after locking, so an unlinked old inode cannot admit a second owner.
private final class RequestClaimLeases: @unchecked Sendable {
    static let shared = RequestClaimLeases()
    private let lock = NSLock()
    private struct Lease { let fd: Int32; var started = false }
    private var descriptors: [String: Lease] = [:]

    static func openLock(_ url: URL) throws -> Int32 {
        while true {
            let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno; close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            var opened = stat(), current = stat()
            guard fstat(fd, &opened) == 0 else {
                let code = errno; close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let found = lstat(url.path, &current)
            if found == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino { return fd }
            let code = errno
            close(fd)
            if found != 0, code != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            // The last owner unlinked the file between open and flock. Retry its current path.
        }
    }

    static func closeLock(_ fd: Int32, at url: URL) {
        var opened = stat(), current = stat()
        if fstat(fd, &opened) == 0, lstat(url.path, &current) == 0,
           opened.st_dev == current.st_dev, opened.st_ino == current.st_ino {
            _ = unlink(url.path)
        }
        close(fd)
    }

    func acquire(_ url: URL) -> Bool {
        lock.withLock {
            guard descriptors[url.path] == nil, let fd = try? Self.openLock(url) else { return false }
            descriptors[url.path] = Lease(fd: fd)
            return true
        }
    }

    func owns(_ url: URL) -> Bool { lock.withLock { descriptors[url.path] != nil } }

    /// A successful start belongs to its live executor. A duplicate call must not
    /// release that executor's lease. Every failure during the first start retires it.
    func start(_ url: URL, operation: (Bool) throws -> Void) throws {
        try lock.withLock {
            guard var lease = descriptors[url.path] else { return try operation(false) }
            guard !lease.started else { throw RequestInboxError.alreadyStarted }
            do {
                try operation(true)
                lease.started = true
                descriptors[url.path] = lease
            } catch {
                descriptors.removeValue(forKey: url.path)
                Self.closeLock(lease.fd, at: url)
                throw error
            }
        }
    }

    func release(_ url: URL) {
        lock.withLock {
            if let lease = descriptors.removeValue(forKey: url.path) { Self.closeLock(lease.fd, at: url) }
        }
    }
}
