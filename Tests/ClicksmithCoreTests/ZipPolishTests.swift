import Foundation
import Testing
@testable import ClicksmithCore

/// Regressions from the T-0016 end-to-end test (2026-11-16).
@Suite struct ZipPolishTests {
    let fm = FileManager.default

    func folder(_ parent: URL, _ path: String) throws -> URL {
        let u = parent.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func zipCLI(_ args: [String], cwd: URL) throws {
        try Shell.run("/usr/bin/zip", args, cwd: cwd)
    }

    // MARK: 1. UTF-8 flag + junk at every depth

    @Test("1: zip sets the UTF-8 flag and drops junk at every depth") func zipUTF8AndDeepJunk() async throws {
        let d = try tempDir()
        let proj = try folder(d, "Proj")
        let sub = try folder(proj, "sub")
        try touch(proj, "café.txt", "a"); try touch(proj, "😀.txt", "b"); try touch(sub, "ok.txt", "ok")
        try touch(proj, ".DS_Store"); try touch(sub, ".DS_Store"); try touch(sub, "._ok.txt"); try touch(sub, "Icon\r")
        try touch(try folder(sub, "__MACOSX"), "x"); try touch(try folder(proj, "__MACOSX"), "y")
        try touch(try folder(sub, ".Spotlight-V100"), "s"); try touch(try folder(proj, ".Trashes"), "t")

        let r = try await ZipAction().run(context([proj]))
        let zip = try #require(r.created.first)
        let entries = try ZipDirectory.read(zip)
        let names = Set(entries.map(\.name))
        #expect(names == ["Proj/", "Proj/sub/", "Proj/sub/ok.txt", "Proj/café.txt", "Proj/😀.txt"])
        #expect(entries.allSatisfy { $0.hasUTF8Flag })
        // Local headers carry the flag too (Windows Explorer reads them).
        let raw = try Data(contentsOf: zip)
        for e in entries {
            let o = Int(e.localOffset)
            #expect(raw[o + 7] & 0x08 != 0, "bit 11 in local header of \(e.name)")
        }
        // Archive stays valid: unzip -t passes.
        try Shell.run("/usr/bin/unzip", ["-tq", zip.path])
    }

    @Test("1: a file named -m stays safe and the zip gets the flag") func zipDashFileFlagged() async throws {
        let d = try tempDir()
        let dash = try touch(d, "-m", "dash"); let e = try touch(d, "é.txt", "keep")
        let r = try await ZipAction().run(context([dash, e]))
        let zip = try #require(r.created.first)
        #expect(fm.fileExists(atPath: dash.path) && fm.fileExists(atPath: e.path))
        let entries = try ZipDirectory.read(zip)
        #expect(Set(entries.map(\.name)) == ["-m", "é.txt"])
        #expect(entries.allSatisfy { $0.hasUTF8Flag })
    }

    // MARK: 2. Extract Here layout

    @Test("2: one top folder goes next to the zip, no double nesting") func unzipSingleFolder() async throws {
        let d = try tempDir()
        let proj = try folder(d, "Proj"); try touch(proj, "a.txt", "A")
        let zip = try #require(try await ZipAction().run(context([proj])).created.first)
        let ops = FileOps()
        let out = try #require(try await UnzipAction().run(context([zip], ops: ops)).created.first)
        #expect(out.lastPathComponent == "Proj 2")   // "Proj" is taken by the original
        #expect(try String(contentsOf: out.appendingPathComponent("a.txt"), encoding: .utf8) == "A")
        #expect(!fm.fileExists(atPath: out.appendingPathComponent("Proj").path))
        #expect(ops.recorded.map(\.kind) == [.created])
    }

    @Test("2: a single-file zip gives the file, not a folder") func unzipSingleFile() async throws {
        let d = try tempDir()
        let f = try touch(d, "note.txt", "hello")
        let zip = try #require(try await ZipAction().run(context([f])).created.first)
        let out = try #require(try await UnzipAction().run(context([zip])).created.first)
        #expect(out.lastPathComponent == "note 2.txt")
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello")
        try fm.removeItem(at: f); try fm.removeItem(at: out)
        let again = try #require(try await UnzipAction().run(context([zip])).created.first)
        #expect(again.lastPathComponent == "note.txt")
    }

    @Test("2: several top items go into a folder named after the zip") func unzipManyItems() async throws {
        let d = try tempDir()
        let a = try touch(d, "a.txt"), b = try touch(d, "b.txt")
        let zip = try #require(try await ZipAction().run(context([a, b])).created.first)
        #expect(zip.lastPathComponent == "Archive.zip")
        let out = try #require(try await UnzipAction().run(context([zip])).created.first)
        #expect(out.lastPathComponent == "Archive")
        #expect(names(out) == ["a.txt", "b.txt"])
    }

    @Test("2: zip-slip paths are refused before extraction") func unzipRefusesTraversal() async throws {
        #expect(!ZipDirectory.isSafe("../evil.txt"))
        #expect(!ZipDirectory.isSafe("a/../../evil.txt"))
        #expect(!ZipDirectory.isSafe("/etc/evil"))
        #expect(!ZipDirectory.isSafe("..\\evil"))
        #expect(!ZipDirectory.isSafe("C:evil"))
        #expect(ZipDirectory.isSafe("Proj/..data/ok.txt"))
        #expect(ZipDirectory.isSafe("café/😀.txt"))

        let d = try tempDir()
        let zip = d.appendingPathComponent("evil.zip")
        try ZipFixture.write(zip, names: ["../evil.txt"])
        await #expect(throws: PowerError.badInput("This archive has paths that point outside its folder. Nothing was extracted.")) {
            _ = try await UnzipAction().process(zip, context([zip]))
        }
        #expect(!fm.fileExists(atPath: d.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    // MARK: 3. Password-protected

    @Test("3: encrypted zip fails with a clear message") func unzipEncrypted() async throws {
        let d = try tempDir(); try touch(d, "secret.txt", "s")
        try zipCLI(["-q", "-P", "pw", "locked.zip", "secret.txt"], cwd: d)
        let zip = d.appendingPathComponent("locked.zip")
        #expect(try ZipDirectory.read(zip).allSatisfy { $0.isEncrypted })
        await #expect(throws: PowerError.badInput("This archive is password protected. Open it with Archive Utility.")) {
            _ = try await UnzipAction().process(zip, context([zip]))
        }
        #expect(names(d) == ["locked.zip", "secret.txt"])
    }

    @Test("3: a damaged zip fails with a clear message") func unzipDamaged() async throws {
        let z = try touch(try tempDir(), "bad.zip", "not a zip at all, sorry")
        await #expect(throws: ZipDirectory.damaged) { _ = try await UnzipAction().process(z, context([z])) }
    }

    // MARK: 4. Checksum and folders

    @Test("4: checksum of only a folder fails") func checksumFolderOnly() async throws {
        let d = try tempDir(); let f = try folder(d, "dir")
        let env = FakeEnvironment()
        await #expect(throws: PowerError.badInput("Select files, not folders.")) {
            _ = try await ChecksumAction().run(context([URL(fileURLWithPath: f.path)], env: env))
        }
        #expect(env.clipboard == nil)
    }

    @Test("4: checksum skips folders in a mixed selection and says so") func checksumMixed() async throws {
        let d = try tempDir(); let f = try folder(d, "dir"); let a = try touch(d, "abc.txt", "abc")
        let env = FakeEnvironment()
        let r = try await ChecksumAction().run(context([a, URL(fileURLWithPath: f.path)], env: env))
        #expect(env.clipboard == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(r.message == "Copied SHA256 for 1 file. Skipped 1 folder.")
    }

    // MARK: Codex review of cbd437c

    @Test("R1: an EOCD signature inside the comment does not hide the real one") func eocdInComment() async throws {
        let d = try tempDir(); let zip = d.appendingPathComponent("c.zip")
        let fake = Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0x41, count: 18)
        try ZipFixture.write(zip, names: ["ok.txt"], comment: Data("note ".utf8) + fake)
        #expect(try ZipDirectory.read(zip).map(\.name) == ["ok.txt"])
        let out = try #require(try await UnzipAction().process(zip, context([zip])).first)
        #expect(out.lastPathComponent == "ok.txt")
        // A candidate whose central directory does not start with PK\u{1}\u{2} is rejected too.
        let empty = d.appendingPathComponent("e.zip")   // a real empty archive is only its end record
        try (Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: empty)
        #expect(try ZipDirectory.read(empty).isEmpty)
        let junk = d.appendingPathComponent("j.zip")
        try (Data("garbage".utf8) + Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 18)).write(to: junk)
        #expect(throws: ZipDirectory.damaged) { _ = try ZipDirectory.read(junk) }
        let bad = d.appendingPathComponent("b.zip")
        try (Data(repeating: 0x41, count: 64) + Data([0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0, 46, 0, 0, 0, 0, 0, 0, 0, 0, 0])).write(to: bad)
        #expect(throws: ZipDirectory.damaged) { _ = try ZipDirectory.read(bad) }
    }

    /// Fake end record placed in the comment of a real one-entry archive, with the comment length fixed up
    /// so the fake one also "ends at EOF".
    func zipWithFakeEOCD(_ url: URL, fake: (_ cdOffset: UInt32, _ cdSize: UInt32) -> [UInt8]) throws {
        try ZipFixture.write(url, names: ["ok.txt"])
        var raw = [UInt8](try Data(contentsOf: url))
        let e = raw.count - 22
        let cdSize = UInt32(raw[e + 12]) | UInt32(raw[e + 13]) << 8, cdOffset = UInt32(raw[e + 16]) | UInt32(raw[e + 17]) << 8
        let bytes = fake(cdOffset, cdSize)
        raw[e + 20] = UInt8(bytes.count & 0xFF); raw[e + 21] = UInt8(bytes.count >> 8)
        try Data(raw + bytes).write(to: url)
    }

    func le(_ v: UInt32, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(v >> (8 * $0) & 0xFF) } }

    @Test("R1b: a fake end record that lies about the entry count is skipped") func eocdFakeCountMismatch() async throws {
        let zip = try tempDir().appendingPathComponent("c.zip")
        try zipWithFakeEOCD(zip) { off, size in
            [0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0] + le(2, 2) + le(2, 2) + le(size, 4) + le(off, 4) + le(0, 2)
        }
        #expect(try ZipDirectory.read(zip).map(\.name) == ["ok.txt"])
        let out = try #require(try await UnzipAction().process(zip, context([zip])).first)
        #expect(out.lastPathComponent == "ok.txt")
    }

    @Test("R1b: an all-zero fake end record does not make the archive look empty") func eocdFakeAllZero() async throws {
        let zip = try tempDir().appendingPathComponent("z.zip")
        try zipWithFakeEOCD(zip) { _, _ in [0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18) }
        #expect(try ZipDirectory.read(zip).map(\.name) == ["ok.txt"])
    }

    @Test("R2: a lone symlink is extracted inside a folder, and undo works") func unzipSingleSymlinkUndo() async throws {
        let d = try tempDir()
        let link = d.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "nowhere")
        let zip = try #require(try await ZipAction().run(context([link])).created.first)
        let j = UndoJournal(directory: try tempDir("j"))
        let runner = ActionRunner(registry: ActionRegistry([UnzipAction()]), journal: j, environment: FakeEnvironment(), settings: .init())
        let o = try await runner.run(ActionRequest(actionID: "tools.unzip", paths: [zip.path], source: .cli))
        let out = try #require(o.result.created.first)
        #expect(out.lastPathComponent == "link 2")
        #expect(try fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("link").path) == "nowhere")
        let rep = j.undo(try #require(o.transaction))
        #expect(rep.reverted.count == 1)
        #expect(!fm.fileExists(atPath: out.path))
    }

    @Test("R3: selected top-level junk is excluded too") func zipRootJunk() async throws {
        let d = try tempDir()
        let a = try touch(d, "a.txt"), ds = try touch(d, ".DS_Store"), dbl = try touch(d, "._a.txt"), icon = try touch(d, "Icon\r")
        let mac = try folder(d, "__MACOSX"); try touch(mac, "m")
        let tr = try folder(d, ".Trashes"); try touch(tr, "t")
        let r = try await ZipAction().run(context([a, ds, dbl, icon, mac, tr]))
        let zip = try #require(r.created.first)
        #expect(try ZipDirectory.read(zip).map(\.name) == ["a.txt"])
        // Nested level still excluded, and normal names that only contain junk words survive.
        let p = try folder(d, "P"); try touch(p, ".DS_Store"); try touch(p, "my.DS_Store.txt"); try touch(try folder(p, "__MACOSX"), "x")
        let z2 = try #require(try await ZipAction().run(context([p])).created.first)
        #expect(Set(try ZipDirectory.read(z2).map(\.name)) == ["P/", "P/my.DS_Store.txt"])
    }
}

/// Writes a stored (uncompressed) zip with arbitrary entry names, for hostile-archive tests.
enum ZipFixture {
    static func write(_ url: URL, names: [String], content: Data = Data("x".utf8), comment: Data = Data()) throws {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
        func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8(v >> (8 * $0) & 0xFF) }) }
        let crc = crc32(content)
        for n in names {
            let name = Data(n.utf8), offset = UInt32(out.count)
            out += le32(0x0403_4b50) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0) + le32(crc)
            out += le32(UInt32(content.count)) + le32(UInt32(content.count)) + le16(name.count) + le16(0) + name + content
            central += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0) + le32(crc)
            central += le32(UInt32(content.count)) + le32(UInt32(content.count)) + le16(name.count) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(names.count) + le16(names.count)
        out += le32(UInt32(central.count)) + le32(cdOffset) + le16(comment.count) + comment
        try out.write(to: url)
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d {
            c ^= UInt32(b)
            for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
        }
        return ~c
    }
}
