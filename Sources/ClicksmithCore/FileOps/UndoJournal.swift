import Foundation
import CryptoKit

enum CryptoKitSHA {
    static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

/// Identity of a file at the time we touched it. Undo only reverts files that still match,
/// so edits the user made after the action are never thrown away.
public struct Fingerprint: Codable, Sendable, Equatable {
    public var size: Int64
    public var modified: Double
    public var isDirectory: Bool
    /// File identity: a replaced file (atomic save) gets a new inode.
    public var inode: UInt64?
    public var device: Int32? = nil
    /// Directories: hash of every entry (path, size, mtime) inside, so added/changed files block undo.
    public var treeHash: String?

    public static func of(_ url: URL) -> Fingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        return Fingerprint(size: isDir ? 0 : Int64(st.st_size), modified: mtime(st), isDirectory: isDir,
                           inode: UInt64(st.st_ino), device: st.st_dev, treeHash: isDir ? tree(url) : nil)
    }

    func matches(_ url: URL) -> Bool {
        guard let now = Fingerprint.of(url), now.isDirectory == isDirectory else { return false }
        if let inode, now.inode != inode { return false }
        if let device, now.device != device { return false }
        if isDirectory { return treeHash != nil && now.treeHash == treeHash }
        return now.size == size && now.modified == modified
    }

    static func mtime(_ st: stat) -> Double { Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9 }

    /// Ignores Finder's .DS_Store churn. Limits work on huge trees (nil = never matches → undo skips: safe side).
    static func tree(_ root: URL, limit: Int = 200_000) -> String? {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return nil }
        var lines: [String] = []
        while let rel = e.nextObject() as? String {
            if (rel as NSString).lastPathComponent == ".DS_Store" { continue }
            if lines.count >= limit { return nil }
            var st = stat()
            guard lstat(root.path + "/" + rel, &st) == 0 else { return nil }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            lines.append("\(rel)|\(isDir ? 0 : st.st_size)|\(isDir ? 0 : mtime(st))|\(st.st_ino)")
        }
        lines.sort()
        return CryptoKitSHA.hash(Data(lines.joined(separator: "\n").utf8))
    }
}

public struct JournalEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case created, moved, trashed }
    public var kind: Kind
    public var from: String?
    public var to: String
    public var fingerprint: Fingerprint?
    /// Entries of one logical step (cross-disk move = copy + trash). Undo restores all or none.
    public var group: UUID? = nil
    /// Native Trash chooses its final name internally. A pre-move bookmark lets
    /// crash recovery locate it without guessing a different volume's Trash path.
    public var recoveryBookmark: Data? = nil
}

public struct JournalTransaction: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var actionID: String
    public var title: String
    public var date: Date
    public var entries: [JournalEntry]

    public init(id: UUID = UUID(), actionID: String, title: String, date: Date = Date(), entries: [JournalEntry]) {
        self.id = id; self.actionID = actionID; self.title = title; self.date = date; self.entries = entries
    }
}

public struct UndoReport: Sendable, Equatable {
    public var reverted: [String] = []
    /// Path + reason. Skipped files are left exactly as they are.
    public var skipped: [(String, String)] = []

    public static func == (a: UndoReport, b: UndoReport) -> Bool {
        a.reverted == b.reverted && a.skipped.map(\.0) == b.skipped.map(\.0) && a.skipped.map(\.1) == b.skipped.map(\.1)
    }

    public var summary: String {
        var s = "Undid \(reverted.count) change\(reverted.count == 1 ? "" : "s")."
        if !skipped.isEmpty { s += " Left \(skipped.count) untouched (changed since)." }
        return s
    }
}

/// Multi-level undo history stored as one JSON file per transaction.
public struct UndoJournal: Sendable {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 50) { self.directory = directory; self.limit = limit }

    public func save(_ tx: JournalTransaction) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "%.6f-%@.json", tx.date.timeIntervalSinceReferenceDate, tx.id.uuidString)
        try Self.writeDurably(JSONEncoder.clicksmith.encode(tx), to: directory.appendingPathComponent(name))
        prune()
    }

    /// Newest first.
    public func list() -> [JournalTransaction] {
        files().reversed().compactMap { try? JSONDecoder.clicksmith.decode(JournalTransaction.self, from: Data(contentsOf: $0)) }
    }

    public var last: JournalTransaction? { list().first }

    /// Revert one transaction (newest change first) and drop it from history.
    @discardableResult
    public func undo(_ tx: JournalTransaction) -> UndoReport {
        var report = UndoReport()
        var failedGroups = Set<UUID>()
        var retryGroups = Set<UUID>()   // failed only because a name is taken: keep the pair for a later undo
        var unresolved: [JournalEntry] = []
        var pendingMoves: [JournalEntry] = []   // newest first
        let ops: FileOps
        do { ops = try FileOps(journal: self, actionID: "undo." + tx.actionID, title: "Interrupted undo: " + tx.title) }
        catch {
            report.skipped.append((directory.path, "Cannot save undo recovery record: \(error.localizedDescription)"))
            return report
        }
        for e in tx.entries.reversed() {
            let to = URL(fileURLWithPath: e.to)
            switch e.kind {
            case .created:
                // Cross-disk move: never remove the only surviving copy (review T-0011 #1).
                if let g = e.group, failedGroups.contains(g) {
                    report.skipped.append((e.to, "kept: the original could not be restored"))
                    if retryGroups.contains(g) { unresolved.insert(e, at: 0) }
                    continue
                }
                guard FileOps.entryExists(to) else { report.skipped.append((e.to, "already gone")); continue }
                guard e.fingerprint?.matches(to) ?? false else { report.skipped.append((e.to, "modified since")); continue }
                do { try ops.trash(to); report.reverted.append(e.to) }
                catch { report.skipped.append((e.to, error.localizedDescription)); unresolved.insert(e, at: 0) }
            case .moved where e.group == nil:
                pendingMoves.append(e)
            case .moved, .trashed:
                guard let fromPath = e.from else { continue }
                let from = URL(fileURLWithPath: fromPath)
                guard FileOps.entryExists(to) else {
                    report.skipped.append((e.to, e.kind == .trashed ? "no longer in the Trash" : "no longer there"))
                    if let g = e.group { failedGroups.insert(g) }
                    continue
                }
                guard e.fingerprint?.matches(to) == true else {
                    report.skipped.append((e.to, "modified since"))
                    if let g = e.group {
                        failedGroups.insert(g); retryGroups.insert(g); unresolved.insert(e, at: 0)
                    }
                    continue
                }
                do {
                    try ops.moveExact(to, to: from)
                    report.reverted.append(fromPath)
                } catch {
                    report.skipped.append((fromPath, "original name is taken"))
                    if let g = e.group { failedGroups.insert(g); retryGroups.insert(g); unresolved.insert(e, at: 0) }
                }
            }
        }
        undoMoves(pendingMoves, using: ops, &report, &unresolved)
        do {
            // Save the remaining entries under the same ID before dropping history.
            // A failed save leaves both the old transaction and the crash record retryable.
            if unresolved.isEmpty { remove(tx.id) }
            else {
                var rest = tx; rest.entries = unresolved
                try save(rest)
            }
            try ops.finishWithoutHistory()
        } catch {
            report.skipped.append((directory.path, "Kept undo recovery record for retry: \(error.localizedDescription)"))
        }
        return report
    }

    /// Two phases, so swaps (a↔b) and cycles undo cleanly: every current file goes to a visible
    /// temp name first, then each temp goes to its original name. Failures roll back to the current name.
    private func undoMoves(_ moves: [JournalEntry], using ops: FileOps, _ report: inout UndoReport, _ unresolved: inout [JournalEntry]) {
        var staged: [(JournalEntry, URL)] = []
        for e in moves {
            let to = URL(fileURLWithPath: e.to)
            guard e.from != nil, FileOps.entryExists(to) else { report.skipped.append((e.to, "no longer there")); continue }
            guard e.fingerprint?.matches(to) ?? false else { report.skipped.append((e.to, "modified since")); continue }
            let tmpName = FileOps.temporaryName(for: to)
            let tmp = to.deletingLastPathComponent().appendingPathComponent(tmpName)
            do { try ops.moveExact(to, to: tmp); staged.append((e, tmp)) }
            catch { report.skipped.append((e.to, error.localizedDescription)); unresolved.insert(e, at: 0) }
        }
        for (e, tmp) in staged {
            guard let fromPath = e.from else { continue }
            let from = URL(fileURLWithPath: fromPath)
            do {
                guard e.fingerprint?.matches(tmp) == true else { throw PowerError.failed("The staged file changed during undo.") }
                try ops.moveExact(tmp, to: from)
                report.reverted.append(fromPath)
            } catch {
                // Put it back where it was; keep the record so a later undo can retry.
                var rest = e
                do { try ops.moveExact(tmp, to: URL(fileURLWithPath: e.to)) }
                catch {
                    rest.to = tmp.path
                    report.skipped.append((tmp.path, "Kept staged file here; its previous name is taken."))
                }
                report.skipped.append((fromPath, "original name is taken or staged file changed"))
                unresolved.insert(rest, at: 0)
            }
        }
    }

    public func remove(_ id: UUID) {
        for f in files() where f.lastPathComponent.contains(id.uuidString) { try? FileManager.default.removeItem(at: f) }
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune() {
        let f = files()
        guard f.count > limit else { return }
        for old in f.prefix(f.count - limit) { try? FileManager.default.removeItem(at: old) }
    }
}
