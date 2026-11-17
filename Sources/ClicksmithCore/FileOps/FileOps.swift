import Foundation

/// Finder-style unique names: "photo.jpg", "photo 2.jpg", "photo 3.jpg"…
public enum OutputNamer {
    public static func fileName(base: String, ext: String, index: Int) -> String {
        let b = index <= 1 ? base : "\(base) \(index)"
        return ext.isEmpty ? b : "\(b).\(ext)"
    }

    /// Base name for an output derived from `input` ("IMG_1.heic" + suffix "small" → "IMG_1 small").
    public static func base(for input: URL, suffix: String? = nil) -> String {
        let b = input.hasDirectoryPath ? input.lastPathComponent : input.deletingPathExtension().lastPathComponent
        guard let suffix, !suffix.isEmpty else { return b }
        return "\(b) \(suffix)"
    }

    /// First free URL in `dir`. Only a hint: `FileOps.place` re-checks atomically.
    public static func firstFree(in dir: URL, base: String, ext: String, fileManager: FileManager = .default) -> URL {
        var i = 1
        while true {
            let u = dir.appendingPathComponent(fileName(base: base, ext: ext, index: i))
            if !fileManager.fileExists(atPath: u.path) { return u }
            i += 1
        }
    }
}

/// The only way actions touch the file system. Never overwrites. Records every change for undo.
public final class FileOps: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var entries: [JournalEntry] = []
    private let fm = FileManager.default
    private var session: JournalSession?
    private var persistence: (journal: UndoJournal, actionID: String, title: String)?

    public init() {}

    /// Open a write-ahead journal before an action can move any originals.
    public init(journal: UndoJournal, actionID: String, title: String) throws {
        persistence = (journal, actionID, title)
        session = try JournalSession(journal: journal, actionID: actionID, title: title)
    }

    public var recorded: [JournalEntry] { lock.withLock { entries } }

    /// Serialize mutation + intent + receipt. A failed preflight changes no files.
    /// A failed receipt save remains retryable in memory and through the prior intent.
    private func mutate(_ intent: JournalEntry, _ operation: () throws -> Void) throws {
        try mutateResult(intent) { try operation(); return URL(fileURLWithPath: intent.to) }
    }

    private func mutateResult(_ intent: JournalEntry, uncertainOnFailure: Bool = false, _ operation: () throws -> URL) throws {
        try lock.withLock {
            if session == nil, let persistence {
                session = try JournalSession(journal: persistence.journal, actionID: persistence.actionID, title: persistence.title)
            }
            if let session {
                guard session.record.intent == nil else {
                    throw PowerError.failed("An earlier file operation needs recovery before more files can be changed.")
                }
                try session.begin(intent)
            }
            let output: URL
            do { output = try operation() }
            catch {
                let originalUnchanged = intent.from.map { intent.fingerprint?.matches(URL(fileURLWithPath: $0)) == true } ?? false
                if !uncertainOnFailure || originalUnchanged { session?.cancel() }
                throw error
            }
            var receipt = intent
            receipt.to = output.path
            receipt.fingerprint = .of(output)
            receipt.recoveryBookmark = nil
            entries.append(receipt)
            session?.complete(receipt)
        }
    }

    // MARK: Create

    /// Give `writer` a scratch URL with the right extension, then move the result next to the input
    /// (or into `directory`) under a unique name. Returns the final URL.
    @discardableResult
    public func produce(base: String, ext: String, in directory: URL, _ writer: (URL) throws -> Void) throws -> URL {
        let scratchDir = try scratchDirectory(near: directory)
        defer { try? fm.removeItem(at: scratchDir) }
        let scratch = scratchDir.appendingPathComponent(ext.isEmpty ? "output" : "output.\(ext)")
        try writer(scratch)
        guard fm.fileExists(atPath: scratch.path) else { throw PowerError.failed("No output was written.") }
        return try place(scratch, in: directory, base: base, ext: ext)
    }

    /// Async twin of `produce` for engines that encode with async APIs (AVFoundation).
    @discardableResult
    public func produce(base: String, ext: String, in directory: URL, async writer: (URL) async throws -> Void) async throws -> URL {
        let scratchDir = try scratchDirectory(near: directory)
        defer { try? fm.removeItem(at: scratchDir) }
        let scratch = scratchDir.appendingPathComponent(ext.isEmpty ? "output" : "output.\(ext)")
        try await writer(scratch)
        guard fm.fileExists(atPath: scratch.path) else { throw PowerError.failed("No output was written.") }
        return try place(scratch, in: directory, base: base, ext: ext)
    }

    /// Convenience: output derived from an input file name.
    @discardableResult
    public func produce(from input: URL, ext: String, suffix: String? = nil, in directory: URL? = nil, _ writer: (URL) throws -> Void) throws -> URL {
        try produce(base: OutputNamer.base(for: input, suffix: suffix), ext: ext, in: directory ?? input.deletingLastPathComponent(), writer)
    }

    @discardableResult
    public func write(_ data: Data, base: String, ext: String, in directory: URL) throws -> URL {
        try produce(base: base, ext: ext, in: directory) { try data.write(to: $0) }
    }

    /// Move a finished file into `directory` with the first free name. Atomic: never replaces.
    public func place(_ file: URL, in directory: URL, base: String, ext: String) throws -> URL {
        var i = 1
        while i < 10_000 {
            let dest = directory.appendingPathComponent(OutputNamer.fileName(base: base, ext: ext, index: i))
            do {
                try mutate(.init(kind: .created, from: nil, to: dest.path, fingerprint: .of(file))) {
                    try moveNoReplace(file, to: dest, sourceIsOwned: true)
                }
                return dest
            } catch let e as POSIXError where e.code == .EEXIST {
                i += 1
            }
        }
        throw PowerError.failed("Could not find a free file name in \(directory.path).")
    }

    // MARK: Change

    /// Rename in place. Fails if the new name is taken by another file. Case-only renames work.
    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            throw PowerError.badInput("“\(newName)” is not a valid file name.")
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        return try moveExact(url, to: dest)
    }

    /// Move to an exact destination. Never replaces another file.
    @discardableResult
    public func moveExact(_ url: URL, to dest: URL) throws -> URL {
        if url.standardizedFileURL.path == dest.standardizedFileURL.path { return url }
        return try lock.withLock {
            if Self.sameFile(url, dest) {
                let temporary = url.deletingLastPathComponent().appendingPathComponent(Self.temporaryName(for: url))
                try moveExact(url, to: temporary)
                do {
                    try mutate(.init(kind: .moved, from: temporary.path, to: dest.path, fingerprint: .of(temporary))) {
                        try Self.renameExclusive(temporary, dest)
                    }
                    return dest
                }
                catch { try? moveExact(temporary, to: url); throw error }
            }
            try mutate(.init(kind: .moved, from: url.path, to: dest.path, fingerprint: .of(url))) {
                try moveNoReplace(url, to: dest)
            }
            return dest
        }
    }

    /// Move into a folder, picking a free name if needed.
    @discardableResult
    public func move(_ url: URL, into directory: URL) throws -> URL {
        let (base, ext) = Self.split(url)
        var i = 1
        while i < 10_000 {
            let dest = directory.appendingPathComponent(OutputNamer.fileName(base: base, ext: ext, index: i))
            do { return try moveExact(url, to: dest) } catch let e as POSIXError where e.code == .EEXIST { i += 1 }
        }
        throw PowerError.failed("Could not find a free file name in \(directory.path).")
    }

    /// Move into a folder. Same disk: atomic rename. Other disk: copy, check the source did not
    /// change during the copy, then put the source in the Trash (recoverable, never deleted).
    /// Never throws after the copy exists: the copy is always reported (review T-0011 #6).
    public struct TransferOutcome: Sendable, Equatable {
        public var destination: URL
        /// false: the copy exists but the original stayed in place (see `problem`).
        public var originalRemoved: Bool
        public var problem: String?
        public var cancelled = false
    }

    public func transfer(_ url: URL, into directory: URL, isCancelled: () -> Bool = { false }) throws -> TransferOutcome {
        do {
            return TransferOutcome(destination: try move(url, into: directory), originalRemoved: true, problem: nil)
        } catch PowerError.unsupported {
            let before = Fingerprint.of(url)
            let group = UUID()   // links copy + trash so undo restores both or neither
            let dest = try copy(url, into: directory, group: group)
            if isCancelled() {
                return TransferOutcome(destination: dest, originalRemoved: false, problem: "Cancelled after copying. Original left in place.", cancelled: true)
            }
            guard let before, before.matches(url) else {
                return TransferOutcome(destination: dest, originalRemoved: false,
                                       problem: "“\(url.lastPathComponent)” changed while copying. Copied it, but left the original in place.")
            }
            do { try trash(url, group: group) } catch {
                return TransferOutcome(destination: dest, originalRemoved: false, problem: "Copied, but could not move the original to the Trash: \(error.localizedDescription)")
            }
            return TransferOutcome(destination: dest, originalRemoved: true, problem: nil)
        }
    }

    /// Copy into a folder with a free name.
    @discardableResult
    public func copy(_ url: URL, into directory: URL, group: UUID? = nil) throws -> URL {
        let (base, ext) = Self.split(url)
        var i = 1
        while i < 10_000 {
            let dest = directory.appendingPathComponent(OutputNamer.fileName(base: base, ext: ext, index: i))
            if fm.fileExists(atPath: dest.path) { i += 1; continue }
            do {
                try mutate(.init(kind: .created, from: url.path, to: dest.path, fingerprint: nil, group: group)) {
                    try fm.copyItem(at: url, to: dest)   // fails if dest appeared meanwhile
                }
            } catch CocoaError.fileWriteFileExists {
                i += 1; continue
            }
            return dest
        }
        throw PowerError.failed("Could not find a free file name in \(directory.path).")
    }

    /// Move to the Trash (recoverable). Returns the URL inside the Trash.
    @discardableResult
    public func trash(_ url: URL, group: UUID? = nil) throws -> URL {
        var intent = JournalEntry(kind: .trashed, from: url.path, to: url.path, fingerprint: .of(url), group: group)
        if persistence != nil {
            // Keep native Trash semantics on external disks. URLForDirectory's
            // appropriateFor parameter only chooses a volume for replacement dirs.
            intent.recoveryBookmark = try url.bookmarkData(options: .suitableForBookmarkFile,
                                                          includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        var target = url
        try mutateResult(intent, uncertainOnFailure: true) {
            var out: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &out)
            guard let result = out as URL? else { throw PowerError.failed("The Trash did not return the file's new location.") }
            target = result
            return result
        }
        return target
    }

    /// Finish: store the recorded changes as one undoable transaction.
    @discardableResult
    public func commit(to journal: UndoJournal, actionID: String, title: String) throws -> JournalTransaction? {
        try lock.withLock {
            guard session?.record.intent == nil else {
                throw PowerError.failed("An interrupted file operation is still pending. Its recovery record was kept.")
            }
            let e = Self.collapse(entries)
            guard !e.isEmpty else {
                try session?.finish()
                session = nil; entries.removeAll()
                return nil
            }
            var tx = session?.record.transaction ?? JournalTransaction(actionID: actionID, title: title, entries: [])
            tx.entries = e
            try journal.save(tx)
            try session?.finish()
            session = nil; entries.removeAll()
            return tx
        }
    }

    /// An undo operation has its own crash record, but no new history on success.
    func finishWithoutHistory() throws {
        try lock.withLock {
            guard session?.record.intent == nil else { throw PowerError.failed("A file operation still needs recovery. Its record was kept.") }
            try session?.finish(); session = nil; entries.removeAll()
        }
    }

    /// a→tmp, tmp→b becomes a→b: staging moves (batch rename, case-only) undo as one logical rename.
    static func collapse(_ entries: [JournalEntry]) -> [JournalEntry] {
        var out: [JournalEntry] = []
        for e in entries {
            if e.kind == .moved || e.kind == .trashed,
               let i = out.lastIndex(where: { $0.kind == .moved && $0.to == e.from && $0.group == e.group }) {
                var merged = out[i]; merged.kind = e.kind; merged.to = e.to; merged.fingerprint = e.fingerprint
                out.remove(at: i)
                if merged.from != merged.to { out.append(merged) }
            } else {
                out.append(e)
            }
        }
        return out
    }

    // MARK: Low level

    static func entryExists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }

    /// Visible, byte-budgeted names, including hidden originals and long extensions.
    /// Same budgeting as RenameEngine, kept here so undo does not depend on that engine.
    static func temporaryName(for source: URL, purpose: String = "undo") -> String {
        var attributes = stat()
        let isDirectory = lstat(source.path, &attributes) == 0 && attributes.st_mode & S_IFMT == S_IFDIR
        let original = source.lastPathComponent
        var stem = isDirectory ? original : (original as NSString).deletingPathExtension
        let ext = isDirectory ? "" : (original as NSString).pathExtension
        stem = String(String.UnicodeScalarView(stem.unicodeScalars.drop(while: { $0 == "." })))
        if stem.isEmpty { stem = isDirectory ? "folder" : "file" }
        let suffix = ".clicksmith-\(purpose)-" + UUID().uuidString.prefix(8).lowercased()
        let budget = 255 - suffix.utf8.count
        let firstBytes = stem.unicodeScalars.first.map { String($0).utf8.count } ?? 1
        let keptExtension = utf8Prefix(ext, limit: max(0, budget - firstBytes - 1))
        let extensionPart = keptExtension.isEmpty ? "" : "." + keptExtension
        return utf8Prefix(stem, limit: budget - extensionPart.utf8.count) + suffix + extensionPart
    }

    private static func utf8Prefix(_ text: String, limit: Int) -> String {
        var result = "", count = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            guard count + fragment.utf8.count <= limit else { break }
            result += fragment; count += fragment.utf8.count
        }
        return result
    }

    static func split(_ url: URL) -> (String, String) {
        if url.hasDirectoryPath { return (url.lastPathComponent, "") }
        return (url.deletingPathExtension().lastPathComponent, url.pathExtension)
    }

    private func scratchDirectory(near dir: URL) throws -> URL {
        // Same volume as the destination so the final move is an atomic rename.
        if let d = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true) { return d }
        let d = fm.temporaryDirectory.appendingPathComponent("Clicksmith-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Move without ever replacing anything (RENAME_EXCL).
    /// - Case-only renames are staged and journaled by moveExact.
    /// - Cross-volume (EXDEV): only for files we own (scratch outputs). User files fail closed for now,
    ///   because copy+delete can lose a file saved by another app in between.
    func moveNoReplace(_ src: URL, to dest: URL, sourceIsOwned: Bool = false) throws {
        do {
            try Self.renameExclusive(src, dest)
        } catch let e as POSIXError where e.code == .EXDEV {
            guard sourceIsOwned else {
                throw PowerError.unsupported("Moving between disks is not supported yet. Nothing was changed.")
            }
            do { try fm.copyItem(at: src, to: dest) } catch CocoaError.fileWriteFileExists { throw POSIXError(.EEXIST) }
            try? fm.removeItem(at: src)
        }
    }

    static func renameExclusive(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}
