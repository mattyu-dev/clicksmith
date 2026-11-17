import Darwin
import Foundation

/// Also decodes the snapshot format used before append-only journals.
struct PendingJournalRecord: Codable {
    var transaction: JournalTransaction
    var intent: JournalEntry?
}

private struct JournalLogEvent: Codable {
    enum Kind: String, Codable { case opened, intent, receipt, cancelled }
    var kind: Kind
    var record: PendingJournalRecord? = nil
    var entry: JournalEntry? = nil
}

/// Each intent and receipt is one fsynced line. The separate flock excludes live
/// sessions without rewriting their accumulated entries before every mutation.
final class JournalSession {
    let journal: UndoJournal
    private(set) var record: PendingJournalRecord
    private let descriptor: Int32
    private var identity: (dev_t, ino_t)
    private var queued: [JournalLogEvent] = []
    private var repairOffset: off_t?

    init(journal: UndoJournal, actionID: String, title: String) throws {
        self.journal = journal
        let pending = PendingJournalRecord(transaction: .init(actionID: actionID, title: title, entries: []))
        record = pending
        try FileManager.default.createDirectory(at: journal.pendingDirectory, withIntermediateDirectories: true)
        let fd = try journal.lockPending(pending.transaction.id)
        do { identity = try Self.createLog(journal.pendingFile(pending.transaction.id), record: pending) }
        catch { journal.closePendingLock(fd, id: pending.transaction.id); throw error }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func begin(_ intent: JournalEntry) throws {
        guard record.intent == nil else { throw PowerError.failed("An earlier file operation still needs recovery.") }
        try flush()
        let fd = try openLog()
        defer { close(fd) }
        try append(.init(kind: .intent, entry: intent), to: fd)
        record.intent = intent
    }

    func complete(_ receipt: JournalEntry) {
        record.transaction.entries.append(receipt)
        record.intent = nil
        queued.append(.init(kind: .receipt, entry: receipt))
        try? flush()
    }

    func cancel() {
        record.intent = nil
        queued.append(.init(kind: .cancelled))
        try? flush()
    }

    func finish() throws {
        let file = journal.pendingFile(record.transaction.id)
        var current = stat()
        if lstat(file.path, &current) == 0 {
            guard current.st_dev == identity.0, current.st_ino == identity.1 else {
                throw PowerError.failed("The pending journal was replaced. Its evidence was kept.")
            }
            try FileManager.default.removeItem(at: file)
        } else if errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        journal.unlinkPendingLock(descriptor, id: record.transaction.id)
    }

    private func flush() throws {
        guard !queued.isEmpty else { return }
        let fd = try openLog()
        defer { close(fd) }
        while let event = queued.first {
            try append(event, to: fd)
            queued.removeFirst()
        }
    }

    private func openLog() throws -> Int32 {
        let file = journal.pendingFile(record.transaction.id)
        var fd = open(file.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            // A failed preflight may have lost its metadata path. Recreate a
            // checkpoint from the still-live session, then resume append-only IO.
            identity = try Self.createLog(file, record: record)
            queued.removeAll(keepingCapacity: true)
            repairOffset = nil
            fd = open(file.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var opened = stat(), current = stat()
        guard fstat(fd, &opened) == 0, lstat(file.path, &current) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
              opened.st_dev == identity.0, opened.st_ino == identity.1 else {
            close(fd)
            throw PowerError.failed("The pending journal changed. No further files were changed.")
        }
        if let offset = repairOffset {
            guard ftruncate(fd, offset) == 0, fsync(fd) == 0 else {
                let code = errno; close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            repairOffset = nil
        }
        return fd
    }

    private func append(_ event: JournalLogEvent, to fd: Int32) throws {
        let offset = lseek(fd, 0, SEEK_END)
        guard offset >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do { try Self.write(event, to: fd) }
        catch {
            repairOffset = offset
            if ftruncate(fd, offset) == 0 { repairOffset = nil }
            throw error
        }
    }

    private static func createLog(_ file: URL, record: PendingJournalRecord) throws -> (dev_t, ino_t) {
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        do {
            try write(.init(kind: .opened, record: record), to: fd)
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return (value.st_dev, value.st_ino)
        } catch { unlink(file.path); throw error }
    }

    private static func write(_ event: JournalLogEvent, to fd: Int32) throws {
        let encoder = JSONEncoder.clicksmith
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

public struct JournalRecoveryReport: Sendable {
    public var recovered: [JournalTransaction] = []
    public var problems: [String] = []
    public var hasFindings: Bool { !recovered.isEmpty || !problems.isEmpty }

    public var summary: String { summary(interrupted: []) }

    public func summary(interrupted: [UUID]) -> String {
        let details = recovered.flatMap(\.entries).map(\.to) + problems
            + interrupted.map { RequestInbox.interruptionSummary([$0]) }
        let message = recovered.isEmpty
            ? "Interrupted file operations need inspection. Files were left in place."
            : "Recovered \(recovered.count) interrupted action(s). Files were left in place; recovered changes are available in undo history."
        var lines = [message] + details.prefix(10)
        if details.count > 10 { lines.append("+\(details.count - 10) more") }
        return lines.joined(separator: "\n")
    }
}

extension UndoJournal {
    var pendingDirectory: URL { directory.appendingPathComponent("pending", isDirectory: true) }
    func pendingFile(_ id: UUID) -> URL { pendingDirectory.appendingPathComponent("\(id.uuidString).jsonl") }
    private func lockFile(_ id: UUID) -> URL { pendingDirectory.appendingPathComponent("\(id.uuidString).lock") }
    private var inspectedDirectory: URL { directory.appendingPathComponent("inspected", isDirectory: true) }
    private var retryDirectory: URL { inspectedDirectory.appendingPathComponent("retry", isDirectory: true) }

    func lockPending(_ id: UUID) throws -> Int32 {
        let file = lockFile(id)
        while true {
            let fd = open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
            let found = lstat(file.path, &current), code = errno
            if found == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino { return fd }
            close(fd)
            if found != 0, code != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            // The prior owner retired this inode between open and flock.
        }
    }

    func unlinkPendingLock(_ fd: Int32, id: UUID) {
        var opened = stat(), current = stat()
        let file = lockFile(id)
        if fstat(fd, &opened) == 0, lstat(file.path, &current) == 0,
           opened.st_dev == current.st_dev, opened.st_ino == current.st_ino { unlink(file.path) }
    }

    func closePendingLock(_ fd: Int32, id: UUID) {
        unlinkPendingLock(fd, id: id)
        close(fd)
    }

    static func writeDurably(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    func readPending(_ file: URL) throws -> PendingJournalRecord {
        let data = try Data(contentsOf: file)
        if file.pathExtension == "json" {
            return try JSONDecoder.clicksmith.decode(PendingJournalRecord.self, from: data)
        }
        var record: PendingJournalRecord?
        // An incomplete final line was never a fully written intent or receipt.
        // Its preceding complete intent still explains a rename without a receipt.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for line in lines.dropLast() {
            let event = try JSONDecoder.clicksmith.decode(JournalLogEvent.self, from: Data(line))
            switch event.kind {
            case .opened:
                guard record == nil, let initial = event.record else { throw PowerError.badInput("Invalid journal header.") }
                record = initial
            case .intent:
                guard record != nil, record?.intent == nil, let entry = event.entry else { throw PowerError.badInput("Invalid journal intent.") }
                record?.intent = entry
            case .receipt:
                guard record?.intent != nil, let entry = event.entry else { throw PowerError.badInput("Invalid journal receipt.") }
                record?.transaction.entries.append(entry)
                record?.intent = nil
            case .cancelled:
                guard record != nil else { throw PowerError.badInput("Missing journal header.") }
                record?.intent = nil
            }
        }
        guard let record else { throw PowerError.badInput("Missing journal header.") }
        return record
    }

    private func archive(_ file: URL, retry: Bool) throws {
        let destination = retry ? retryDirectory : inspectedDirectory
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileOps.renameExclusive(file, destination.appendingPathComponent(file.lastPathComponent))
    }

    /// Recover metadata, never replay filesystem operations. Uncertain evidence is
    /// reported once and archived. Failed final saves are quietly retried from the
    /// inspected/retry directory, preserving both retryability and one-time alerts.
    public func recoverPending() -> JournalRecoveryReport {
        var report = JournalRecoveryReport()
        let fm = FileManager.default
        let pending: [URL]
        do { pending = try fm.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil) }
        catch CocoaError.fileReadNoSuchFile { return report }
        catch { report.problems.append("Cannot read pending undo records: \(error.localizedDescription)"); return report }
        let retries = (try? fm.contentsOfDirectory(at: retryDirectory, includingPropertiesForKeys: nil)) ?? []
        let historyIDs = Set(list().map(\.id))
        for file in (pending + retries).sorted(by: { $0.path < $1.path }) where ["json", "jsonl"].contains(file.pathExtension) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            let quiet = file.deletingLastPathComponent().resolvingSymlinksInPath().path == retryDirectory.resolvingSymlinksInPath().path
            let fd: Int32
            do { fd = try lockPending(id) }
            catch let error as POSIXError where error.code == .EWOULDBLOCK { continue }
            catch { if !quiet { report.problems.append("Cannot lock \(file.path): \(error.localizedDescription)") }; continue }
            defer { closePendingLock(fd, id: id) }
            do {
                let pending = try readPending(file)
                guard pending.transaction.id == id else { throw PowerError.badInput("Pending journal ID mismatch: \(file.path)") }
                if historyIDs.contains(id) {
                    if quiet { try archive(file, retry: false) } else { try fm.removeItem(at: file) }
                    continue
                }
                var tx = pending.transaction
                var inspection: [String] = []
                if let intent = pending.intent {
                    let to = URL(fileURLWithPath: intent.to)
                    let from = intent.from.map { URL(fileURLWithPath: $0) }
                    if let bookmark = intent.recoveryBookmark {
                        var stale = false
                        let location = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
                        if let from, intent.fingerprint?.matches(from) == true {
                            // Native Trash did not move the original.
                        } else if let location, intent.fingerprint?.matches(location) == true {
                            var receipt = intent; receipt.to = location.path; receipt.fingerprint = .of(location); receipt.recoveryBookmark = nil
                            tx.entries.append(receipt)
                        } else {
                            inspection.append("Interrupted Trash operation needs inspection: \(intent.from ?? intent.to). Possible location: \(location?.path ?? "System Trash").")
                        }
                    } else if intent.fingerprint?.matches(to) == true {
                        var receipt = intent; receipt.fingerprint = .of(to)
                        tx.entries.append(receipt)
                    } else if let from, intent.fingerprint?.matches(from) == true, !FileOps.entryExists(to) {
                        // The process stopped before the exclusive rename.
                    } else if intent.kind == .created, !FileOps.entryExists(to) {
                        // No publication occurred.
                    } else {
                        inspection.append("Interrupted operation needs inspection: \(intent.from ?? "new output") -> \(intent.to). No files were changed by recovery.")
                        inspection += tx.entries.map { "Recorded location: \($0.to)" }
                    }
                }
                if !inspection.isEmpty {
                    try archive(file, retry: false)
                    if !quiet { report.problems += inspection }
                    continue
                }
                tx.entries = FileOps.collapse(tx.entries)
                if !tx.entries.isEmpty {
                    do { try save(tx) }
                    catch {
                        if !quiet {
                            let saveProblem = error.localizedDescription
                            do {
                                try archive(file, retry: true)
                                report.problems.append("Kept undo record for retry in \(retryDirectory.path): \(saveProblem)")
                            } catch {
                                // A failed relocation must not route a retryable
                                // save into the final-inspection error handler.
                                report.problems.append("Kept pending undo record \(file.path) for retry: \(saveProblem). Could not archive it: \(error.localizedDescription)")
                            }
                        }
                        continue
                    }
                    report.recovered.append(tx)
                }
                if quiet { try archive(file, retry: false) } else { try fm.removeItem(at: file) }
            } catch CocoaError.fileReadNoSuchFile {
                // A just-finished session can disappear after directory enumeration.
            } catch {
                do { try archive(file, retry: false) } catch { /* Keep the original evidence if archival fails. */ }
                if !quiet {
                    report.problems.append("Kept undo record for inspection \(file.path): \(error.localizedDescription)")
                }
            }
        }
        // Clean up legacy lock-only remnants, after checking their data paths
        // under flock. A live session creating its first line remains excluded.
        for file in pending where file.pathExtension == "lock" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let fd = try? lockPending(id) else { continue }
            closePendingLock(fd, id: id)
        }
        return report
    }
}
