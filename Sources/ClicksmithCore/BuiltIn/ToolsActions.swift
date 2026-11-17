import Foundation
import CryptoKit

// MARK: - Checksums

struct ChecksumAction: PowerAction {
    let descriptor = ActionDescriptor(
        id: "tools.checksum", title: "Copy Checksum", symbol: "number", group: .copy,
        summary: "Hash files and copy the result.",
        variants: [
            ActionVariant("SHA-256", options: ["algorithm": "sha256"]),
            ActionVariant("SHA-1", options: ["algorithm": "sha1"]),
            ActionVariant("MD5", options: ["algorithm": "md5"]),
        ], isLongRunning: true)

    func run(_ c: ActionContext) async throws -> ActionResult {
        let algo = c.option("algorithm", default: "sha256")
        var lines: [String] = []
        var skipped = 0
        for (i, url) in c.inputs.enumerated() {
            try c.checkCancelled()
            await c.progress.update(done: i, total: c.inputs.count, current: url.lastPathComponent)
            var isDir: ObjCBool = false
            // Follows symlinks; hasDirectoryPath only looks at a trailing slash.
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { skipped += 1; continue }
            lines.append("\(try Self.hash(url, algorithm: algo, cancel: c.isCancelled))  \(url.lastPathComponent)")
        }
        guard !lines.isEmpty else { throw PowerError.badInput("Select files, not folders.") }
        await c.environment.setClipboard(lines.count == 1 ? String(lines[0].prefix { $0 != " " }) : lines.joined(separator: "\n"))
        var message = "Copied \(algo.uppercased()) for \(lines.count) file\(lines.count == 1 ? "" : "s")."
        if skipped > 0 { message += " Skipped \(skipped) folder\(skipped == 1 ? "" : "s")." }
        return ActionResult(message: message)
    }

    static func hash(_ url: URL, algorithm: String, cancel: @Sendable () -> Bool = { false }) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        func digest<H: HashFunction>(_ hasher: inout H) throws -> String {
            while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
                if cancel() { throw PowerError.cancelled }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case "sha256": var x = SHA256(); return try digest(&x)
        case "sha1": var x = Insecure.SHA1(); return try digest(&x)
        case "md5": var x = Insecure.MD5(); return try digest(&x)
        case "sha512": var x = SHA512(); return try digest(&x)
        default: throw PowerError.badInput("Unknown hash “\(algorithm)”.")
        }
    }
}

// MARK: - Archives

struct ZipAction: PowerAction {
    let descriptor = ActionDescriptor(id: "tools.zip", title: "Zip (No Junk Files)", symbol: "doc.zipper", group: .tools,
                                      summary: "Zip without .DS_Store and __MACOSX, ready to send anywhere.", isLongRunning: true)

    /// zip -x patterns, each at the root ("X", "X/*") and nested ("*/X", "*/X/*"); zip's "*" also matches "/".
    /// zip strips the "./" input prefix before matching, so root items need their own patterns.
    static let junkPatterns: [String] = {
        let files = [".DS_Store", "._*", "Icon\r"]
        let folders = ["__MACOSX", ".Spotlight-V100", ".Trashes", ".fseventsd"]
        return files.flatMap { [$0, "*/" + $0] } + folders.flatMap { [$0, $0 + "/*", "*/" + $0, "*/" + $0 + "/*"] }
    }()

    func run(_ c: ActionContext) async throws -> ActionResult {
        let dir = c.inputs[0].deletingLastPathComponent()
        guard c.inputs.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL }) else {
            throw PowerError.badInput("Zip items from one folder at a time.")
        }
        let base = c.inputs.count == 1 ? OutputNamer.base(for: c.inputs[0]) : "Archive"
        let out = try c.files.produce(base: base, ext: "zip", in: dir) { dest in
            // Run from the parent so archive paths are relative.
            var args = ["-r", "-y", "-q", dest.path]
            // "./" prefix: a file named "-m" must never become a zip option (move mode deletes originals).
            args += c.inputs.map { "./" + $0.lastPathComponent }
            args += Self.junkPatterns.flatMap { ["-x", $0] }
            try Shell.run("/usr/bin/zip", args, cwd: dir, cancel: c.isCancelled)
            // macOS zip 3.0 has no UNICODE_SUPPORT: names are UTF-8 bytes but bit 11 is unset,
            // so Windows and Python decode them as CP437. Set the flag in place (scratch file only).
            try ZipDirectory.markUTF8(dest)
        }
        return ActionResult(created: [out], message: "Created \(out.lastPathComponent).")
    }
}

struct UnzipAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "tools.unzip", title: "Extract Here", symbol: "archivebox", group: .tools,
                                      extensions: ["zip"], isLongRunning: true)

    /// Like Archive Utility: one top-level item goes next to the zip; several go into a folder named after the zip.
    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        let entries = try ZipDirectory.read(url)
        if entries.contains(where: \.isEncrypted) {
            throw PowerError.badInput("This archive is password protected. Open it with Archive Utility.")
        }
        guard entries.allSatisfy({ ZipDirectory.isSafe($0.name) }) else {
            throw PowerError.badInput("This archive has paths that point outside its folder. Nothing was extracted.")
        }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let scratch: URL
        do {
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dir, create: true)
        } catch {
            scratch = fm.temporaryDirectory.appendingPathComponent("Clicksmith-\(UUID().uuidString)")
        }
        defer { try? fm.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("extract", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, root.path], cancel: c.isCancelled)

        let top = try fm.contentsOfDirectory(atPath: root.path).filter { !ZipDirectory.isJunk($0) }
        guard !top.isEmpty else { throw PowerError.badInput("This archive is empty.") }
        let single = top.count == 1 ? root.appendingPathComponent(top[0]) : nil
        // A lone symlink stays inside a real folder: undo checks paths with fileExists, which follows links.
        if let item = single, (try? fm.destinationOfSymbolicLink(atPath: item.path)) == nil {
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: item.path, isDirectory: &isDir)
            let (base, ext) = isDir.boolValue ? (top[0], "") : (item.deletingPathExtension().lastPathComponent, item.pathExtension)
            return [try c.files.place(item, in: dir, base: base, ext: ext)]
        }
        return [try c.files.place(root, in: dir, base: OutputNamer.base(for: url), ext: "")]
    }
}

// MARK: - Open

struct OpenTerminalAction: PowerAction {
    let descriptor = ActionDescriptor(id: "open.terminal", title: "Open in Terminal", symbol: "terminal", group: .open,
                                      extensions: ["/"], contexts: [.items, .container], minCount: 0)
    func run(_ c: ActionContext) async throws -> ActionResult {
        let folder: URL = c.inputs.first.map { $0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent() } ?? c.targetDirectory
        let terminal = TerminalApps.preferred()
        try await c.environment.open([folder], withApplicationAt: terminal)
        return .none
    }
}

enum TerminalApps {
    static let candidates = ["/Applications/Ghostty.app", "/Applications/iTerm.app", "/Applications/Warp.app",
                             "/System/Applications/Utilities/Terminal.app"]
    static func preferred() -> URL {
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates.last!
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Process helper

enum Shell {
    /// Run a tool; throws with stderr on failure. stderr is drained concurrently (no pipe deadlock).
    /// Cancel terminates the child, then kills it if it does not exit within 2 s.
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil, cancel: @Sendable () -> Bool = { false }) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        let box = ErrBox()
        err.fileHandleForReading.readabilityHandler = { h in box.append(h.availableData) }
        try p.run()
        while p.isRunning {
            if cancel() {
                p.terminate()
                let deadline = Date().addingTimeInterval(2)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                p.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                throw PowerError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        box.append(err.fileHandleForReading.readDataToEndOfFile())
        guard p.terminationStatus == 0 else {
            throw PowerError.failed("\(URL(fileURLWithPath: tool).lastPathComponent) failed", detail: box.text)
        }
    }

    /// Keeps the last 16 KB of stderr.
    final class ErrBox: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func append(_ d: Data) { guard !d.isEmpty else { return }; lock.withLock { data.append(d); if data.count > 16_384 { data = data.suffix(16_384) } } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
    }
}
