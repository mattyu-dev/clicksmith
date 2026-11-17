import Foundation

/// Minimal ZIP central-directory reader and flag patcher. Reads headers only, never file data.
/// Used to: set the UTF-8 name flag (bit 11) after /usr/bin/zip, detect encryption (bit 0),
/// and check entry paths (zip-slip) before extraction.
enum ZipDirectory {
    struct Entry: Sendable, Equatable {
        var rawName: [UInt8]
        var flags: UInt16
        /// Offset of the central header in the file.
        var centralOffset: UInt64
        /// Offset of the local header in the file.
        var localOffset: UInt64

        var isEncrypted: Bool { flags & 0x0001 != 0 }
        var hasUTF8Flag: Bool { flags & 0x0800 != 0 }
        /// Name as text: UTF-8 when valid, else Latin-1 (only used for checks and layout).
        var name: String { String(bytes: rawName, encoding: .utf8) ?? String(decoding: rawName.map { UInt16($0) }, as: UTF16.self) }
    }

    static let damaged = PowerError.badInput("This archive is damaged or is not a zip archive.")

    // MARK: Read

    static func read(_ url: URL) throws -> [Entry] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return try read(h)
    }

    static func read(_ h: FileHandle) throws -> [Entry] {
        let size = try h.seekToEnd()
        guard size >= 22 else { throw damaged }
        let tailLen = min(size, 22 + 65_535)
        let tailStart = size - tailLen
        let tail = try bytes(h, at: tailStart, count: Int(tailLen))
        // End Of Central Directory: scan backwards and take the first candidate that validates.
        // A comment may itself contain "PK\u{5}\u{6}", so a bare signature match is not enough.
        var i = tail.count - 22
        while i >= 0 {
            // Accept a candidate only if ALL its declared entries parse and fill exactly the declared size.
            if tail[i] == 0x50, tail[i + 1] == 0x4b, tail[i + 2] == 0x05, tail[i + 3] == 0x06,
               let found = try? locateCentral(h, tail: tail, eocd: i, eocdPos: tailStart + UInt64(i)),
               let list = try? entries(h, cdOffset: found.offset, cdSize: found.size, count: found.count) {
                return list
            }
            i -= 1
        }
        throw damaged
    }

    /// Validates one EOCD candidate: comment ends exactly at EOF, central directory inside the file,
    /// and it starts with a central header (or is empty).
    private static func locateCentral(_ h: FileHandle, tail: [UInt8], eocd: Int, eocdPos: UInt64) throws -> (offset: UInt64, size: UInt64, count: UInt64) {
        guard eocd + 22 + Int(try u16(tail, eocd + 20)) == tail.count else { throw damaged }
        var dirEnd = eocdPos   // the central directory ends where the (zip64) end record starts
        var count = UInt64(try u16(tail, eocd + 10))
        var cdSize = UInt64(try u32(tail, eocd + 12))
        var cdOffset = UInt64(try u32(tail, eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // Zip64: locator sits right before the EOCD.
            guard eocdPos >= 20 else { throw damaged }
            let loc = try bytes(h, at: eocdPos - 20, count: 20)
            guard try u32(loc, 0) == 0x0706_4b50 else { throw damaged }
            let z64 = try u64(loc, 8)
            guard z64 < eocdPos else { throw damaged }
            let rec = try bytes(h, at: z64, count: 56)
            guard try u32(rec, 0) == 0x0606_4b50 else { throw damaged }
            count = try u64(rec, 32); cdSize = try u64(rec, 40); cdOffset = try u64(rec, 48)
            dirEnd = z64
        }
        guard cdOffset <= dirEnd, cdSize == dirEnd - cdOffset, cdOffset <= eocdPos, cdSize <= eocdPos - cdOffset, cdSize < 1 << 30, count <= cdSize / 46 + 1 else { throw damaged }
        if count == 0 { guard cdSize == 0 else { throw damaged } } else {
            guard cdSize >= 46, try u32(try bytes(h, at: cdOffset, count: 4), 0) == 0x0201_4b50 else { throw damaged }
        }
        return (cdOffset, cdSize, count)
    }

    private static func entries(_ h: FileHandle, cdOffset: UInt64, cdSize: UInt64, count: UInt64) throws -> [Entry] {
        let cd = try bytes(h, at: cdOffset, count: Int(cdSize))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var p = 0
        for _ in 0..<count {
            guard try u32(cd, p) == 0x0201_4b50 else { throw damaged }
            let flags = try u16(cd, p + 8)
            let csize = try u32(cd, p + 20), usize = try u32(cd, p + 24)
            let nameLen = Int(try u16(cd, p + 28)), extraLen = Int(try u16(cd, p + 30)), commentLen = Int(try u16(cd, p + 32))
            var local = UInt64(try u32(cd, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen + extraLen + commentLen <= cd.count else { throw damaged }
            let name = Array(cd[nameStart..<nameStart + nameLen])
            if local == 0xFFFF_FFFF {
                // Zip64 extra (id 1): usize, csize, local offset — each present only when its field is 0xFFFFFFFF.
                var e = nameStart + nameLen
                let end = e + extraLen
                while e + 4 <= end {
                    let id = try u16(cd, e), len = Int(try u16(cd, e + 2))
                    if id == 0x0001 {
                        var f = e + 4
                        if usize == 0xFFFF_FFFF { f += 8 }
                        if csize == 0xFFFF_FFFF { f += 8 }
                        guard f + 8 <= e + 4 + len else { throw damaged }
                        local = try u64(cd, f)
                        break
                    }
                    e += 4 + len
                }
            }
            entries.append(Entry(rawName: name, flags: flags, centralOffset: cdOffset + UInt64(p), localOffset: local))
            p = nameStart + nameLen + extraLen + commentLen
        }
        guard p == cd.count else { throw damaged }
        return entries
    }

    // MARK: Patch

    /// Set general purpose bit 11 (names are UTF-8) on every entry whose name is valid UTF-8,
    /// in both the central and the local header. Sizes and CRCs do not change.
    static func markUTF8(_ url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        for e in try read(h) where !e.hasUTF8Flag && String(bytes: e.rawName, encoding: .utf8) != nil {
            let local = try bytes(h, at: e.localOffset, count: 8)
            guard try u32(local, 0) == 0x0403_4b50 else { throw damaged }
            let flags = e.flags | 0x0800
            let le = Data([UInt8(flags & 0xFF), UInt8(flags >> 8)])
            try h.seek(toOffset: e.centralOffset + 8); try h.write(contentsOf: le)
            let lflags = (UInt16(local[6]) | UInt16(local[7]) << 8) | 0x0800
            try h.seek(toOffset: e.localOffset + 6); try h.write(contentsOf: Data([UInt8(lflags & 0xFF), UInt8(lflags >> 8)]))
        }
        try h.synchronize()
    }

    // MARK: Paths

    /// False for absolute paths, drive letters, and any ".." component (zip-slip).
    static func isSafe(_ name: String) -> Bool {
        if name.hasPrefix("/") || name.hasPrefix("\\") { return false }
        if name.count >= 2, name.dropFirst().first == ":" { return false }
        let parts = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !parts.contains("..")
    }

    /// Junk that never belongs in an archive sent to someone else.
    static func isJunk(_ component: String) -> Bool {
        component == ".DS_Store" || component == "__MACOSX" || component.hasPrefix("._") || component == ".Spotlight-V100"
            || component == ".Trashes" || component == ".fseventsd" || component == "Icon\r"
    }

    // MARK: Bytes

    private static func bytes(_ h: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
        try h.seek(toOffset: offset)
        let d = try h.read(upToCount: count) ?? Data()
        guard d.count == count else { throw damaged }
        return [UInt8](d)
    }

    private static func u16(_ b: [UInt8], _ o: Int) throws -> UInt16 {
        guard o >= 0, o + 2 <= b.count else { throw damaged }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { throw damaged }
        return (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) }
    }

    private static func u64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
        guard o >= 0, o + 8 <= b.count else { throw damaged }
        return (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) }
    }
}
