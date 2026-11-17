import Foundation

/// Minimal ISO-BMFF (MP4/MOV/M4A) header editing. Only used on scratch files
/// this engine just wrote, never on a user's original.
enum MediaAtoms {
    /// Seconds from 1904-01-01 (QuickTime epoch) to 1970-01-01.
    static let epochOffset: Double = 2_082_844_800

    struct Box {
        let type: String
        let start: Int
        let header: Int
        let size: Int
        var body: Int { start + header }
        var end: Int { start + size }
    }

    /// Sample tables of very long movies stay far below this.
    static let maximumMovieHeader = 256 * 1024 * 1024

    private static var damaged: PowerError { .failed("The media file structure is damaged.") }

    // Every read and write is bounds-checked: input may be malformed, and a
    // trap cannot be caught. A failed check throws before anything is written.

    static func be32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
        guard o >= 0, o <= b.count - 4 else { throw damaged }
        return b[o..<o + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func be64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
        guard o >= 0, o <= b.count - 8 else { throw damaged }
        return b[o..<o + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) throws {
        guard o >= 0, o <= b.count - 4 else { throw damaged }
        for i in 0..<4 { b[o + i] = UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32(i))) }
    }

    static func put64(_ b: inout [UInt8], _ o: Int, _ v: UInt64) throws {
        guard o >= 0, o <= b.count - 8 else { throw damaged }
        for i in 0..<8 { b[o + i] = UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64(i))) }
    }

    /// Checks that `count` payload bytes at `offset` lie inside `box` and the buffer.
    private static func field(_ b: [UInt8], _ box: Box, _ offset: Int, _ count: Int) throws -> Int {
        // Box bounds were validated against the buffer; compare by subtraction so
        // no parsed value is ever added to another.
        guard offset >= 0, count >= 0, box.start >= 0, box.header >= 0, box.end <= b.count,
              offset <= box.size - box.header - count else { throw damaged }
        return box.body + offset
    }

    static func version(_ b: [UInt8], _ box: Box) throws -> UInt8 { b[try field(b, box, 0, 1)] }
    static func read32(_ b: [UInt8], _ box: Box, _ offset: Int) throws -> UInt32 { try be32(b, try field(b, box, offset, 4)) }
    static func read64(_ b: [UInt8], _ box: Box, _ offset: Int) throws -> UInt64 { try be64(b, try field(b, box, offset, 8)) }
    static func write32(_ b: inout [UInt8], _ box: Box, _ offset: Int, _ v: UInt32) throws { try put32(&b, try field(b, box, offset, 4), v) }
    static func write64(_ b: inout [UInt8], _ box: Box, _ offset: Int, _ v: UInt64) throws { try put64(&b, try field(b, box, offset, 8), v) }

    static func boxes(_ b: [UInt8], in range: Range<Int>) throws -> [Box] {
        guard range.lowerBound >= 0, range.upperBound <= b.count else { throw damaged }
        var result: [Box] = []
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var size = Int(try be32(b, o))
            var header = 8
            if size == 1 {
                guard o + 16 <= range.upperBound, try be64(b, o + 8) <= UInt64(range.upperBound - o) else { throw damaged }
                size = Int(try be64(b, o + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= header, size <= range.upperBound - o else { throw damaged }
            result.append(Box(type: String(decoding: b[o + 4..<o + 8], as: Unicode.ASCII.self), start: o, header: header, size: size))
            o += size
        }
        return result
    }

    static func child(_ b: [UInt8], _ parent: Box, _ type: String) throws -> Box? {
        try boxes(b, in: parent.body..<parent.end).first { $0.type == type }
    }

    // MARK: File access

    private static func topLevel(_ handle: FileHandle, length: Int) throws -> [Box] {
        var result: [Box] = []
        var o = 0
        while o + 8 <= length {
            try handle.seek(toOffset: UInt64(o))
            let header = [UInt8](try handle.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { throw damaged }
            var size = Int(try be32(header, 0))
            var headerSize = 8
            if size == 1 {
                guard header.count == 16, try be64(header, 8) <= UInt64(length - o) else { throw damaged }
                size = Int(try be64(header, 8))
                headerSize = 16
            } else if size == 0 {
                size = length - o
            }
            guard size >= headerSize, size <= length - o else { throw damaged }
            result.append(Box(type: String(decoding: header[4..<8], as: Unicode.ASCII.self), start: o, header: headerSize, size: size))
            o += size
        }
        return result
    }

    /// Reads the movie box. `edit` may change its size only when it is the
    /// last box in the file, so no chunk offset moves.
    private static func editMovie(_ url: URL, _ edit: (inout [UInt8]) throws -> Void) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        guard let moov = try topLevel(handle, length: length).first(where: { $0.type == "moov" }) else { throw damaged }
        guard moov.size <= maximumMovieHeader else { throw PowerError.unsupported("The movie header is too large to edit.") }
        try handle.seek(toOffset: UInt64(moov.start))
        guard let data = try handle.read(upToCount: moov.size), data.count == moov.size else { throw damaged }
        var bytes = [UInt8](data)
        let original = bytes
        try edit(&bytes)
        guard bytes != original else { return }
        if bytes.count != moov.size {
            guard moov.end == length else {
                throw PowerError.unsupported("Cannot resize the movie header before the media data.")
            }
            try handle.truncate(atOffset: UInt64(moov.start))
        }
        try handle.seek(toOffset: UInt64(moov.start))
        try handle.write(contentsOf: bytes)
    }

    private static func readMovie(_ url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = Int(try handle.seekToEnd())
        guard let moov = try topLevel(handle, length: length).first(where: { $0.type == "moov" }) else { throw damaged }
        guard moov.size <= maximumMovieHeader else { throw PowerError.unsupported("The movie header is too large to read.") }
        try handle.seek(toOffset: UInt64(moov.start))
        guard let data = try handle.read(upToCount: moov.size), data.count == moov.size else { throw damaged }
        return [UInt8](data)
    }

    // MARK: Dates

    /// The movie header (mvhd) creation time, or nil when it is unset.
    static func movieCreationDate(_ url: URL) throws -> Date? {
        let b = try readMovie(url)
        guard let moov = try boxes(b, in: 0..<b.count).first, moov.type == "moov",
              let mvhd = try child(b, moov, "mvhd") else { throw damaged }
        let seconds = try version(b, mvhd) == 1 ? try read64(b, mvhd, 4) : UInt64(try read32(b, mvhd, 4))
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) - epochOffset)
    }

    /// Sets creation and modification times in mvhd, every tkhd and every mdhd.
    static func setMovieDates(_ url: URL, to date: Date) throws {
        let seconds = date.timeIntervalSince1970 + epochOffset
        guard seconds.isFinite, seconds >= 0, seconds < Double(UInt64(UInt32.max)) else {
            throw PowerError.badInput("The media date is out of range.")
        }
        let value = UInt64(seconds)
        try editMovie(url) { b in
            guard let moov = try boxes(b, in: 0..<b.count).first, moov.type == "moov" else { throw damaged }
            var headers: [Box] = []
            if let mvhd = try child(b, moov, "mvhd") { headers.append(mvhd) }
            for trak in try boxes(b, in: moov.body..<moov.end) where trak.type == "trak" {
                if let tkhd = try child(b, trak, "tkhd") { headers.append(tkhd) }
                if let mdia = try child(b, trak, "mdia"), let mdhd = try child(b, mdia, "mdhd") { headers.append(mdhd) }
            }
            for box in headers {
                if try version(b, box) == 1 {
                    try write64(&b, box, 4, value)
                    try write64(&b, box, 12, value)
                } else {
                    try write32(&b, box, 4, UInt32(value))
                    try write32(&b, box, 8, UInt32(value))
                }
            }
        }
    }

    // MARK: Audio length

    /// AVAssetWriter gives the last ALAC packet a full packet duration and keeps
    /// the real length only in iTunSMPB. Some decoders (ffmpeg) then drop or pad
    /// samples. Shorten the last stts entry to the real sample count, as
    /// `afconvert` does, and fix the media, track and movie durations.
    static func trimSoundTrack(_ url: URL, validFrames: Int64) throws {
        guard validFrames > 0 else { return }
        try editMovie(url) { b in
            guard let moov = try boxes(b, in: 0..<b.count).first, moov.type == "moov",
                  let mvhd = try child(b, moov, "mvhd") else { throw damaged }
            var sound: (trak: Box, mdia: Box, mdhd: Box, minf: Box, stbl: Box, stts: Box)?
            for trak in try boxes(b, in: moov.body..<moov.end) where trak.type == "trak" {
                guard let mdia = try child(b, trak, "mdia"), let hdlr = try child(b, mdia, "hdlr"),
                      try read32(b, hdlr, 8) == 0x736F_756E, // "soun"
                      let mdhd = try child(b, mdia, "mdhd"), let minf = try child(b, mdia, "minf"),
                      let stbl = try child(b, minf, "stbl"), let stts = try child(b, stbl, "stts") else { continue }
                sound = (trak, mdia, mdhd, minf, stbl, stts)
                break
            }
            guard let sound else { return }
            let stts = sound.stts
            let count = Int(try read32(b, stts, 4))
            guard count > 0, count <= (stts.size - stts.header - 8) / 8 else { throw damaged }
            var total: Int64 = 0
            for i in 0..<count {
                let run = Int64(try read32(b, stts, 8 + i * 8)).multipliedReportingOverflow(by: Int64(try read32(b, stts, 12 + i * 8)))
                guard !run.overflow else { throw damaged }
                let sum = total.addingReportingOverflow(run.partialValue)
                guard !sum.overflow else { throw damaged }
                total = sum.partialValue
            }
            let last = 8 + (count - 1) * 8
            let lastCount = Int64(try read32(b, stts, last))
            let lastDelta = Int64(try read32(b, stts, last + 4))
            let cut = total - validFrames
            guard cut > 0, cut < lastDelta, lastCount > 0 else { return }

            // Durations first: their offsets lie before stts and do not move.
            let mediaScale = Int64(try version(b, sound.mdhd) == 1 ? try read32(b, sound.mdhd, 20) : try read32(b, sound.mdhd, 12))
            let movieScale = Int64(try version(b, mvhd) == 1 ? try read32(b, mvhd, 20) : try read32(b, mvhd, 12))
            guard mediaScale > 0, movieScale > 0 else { throw damaged }
            let scaled = validFrames.multipliedReportingOverflow(by: movieScale)
            let rounded = scaled.partialValue.addingReportingOverflow(mediaScale / 2)
            guard !scaled.overflow, !rounded.overflow else { throw damaged }
            let movieDuration = rounded.partialValue / mediaScale
            try setDuration(&b, sound.mdhd, v0: 16, v1: 24, UInt64(validFrames))
            try setDuration(&b, mvhd, v0: 16, v1: 24, UInt64(movieDuration))
            if let tkhd = try child(b, sound.trak, "tkhd") { try setDuration(&b, tkhd, v0: 20, v1: 28, UInt64(movieDuration)) }
            if let edts = try child(b, sound.trak, "edts"), let elst = try child(b, edts, "elst"),
               try read32(b, elst, 4) == 1 {
                if try version(b, elst) == 1 { try write64(&b, elst, 8, UInt64(movieDuration)) }
                else { try write32(&b, elst, 8, UInt32(clamping: movieDuration)) }
            }

            if lastCount == 1 {
                try write32(&b, stts, last + 4, UInt32(lastDelta - cut))
                return
            }
            try write32(&b, stts, last, UInt32(lastCount - 1))
            guard let entries = UInt32(exactly: count + 1) else { throw damaged }
            try write32(&b, stts, 4, entries)
            var entry = [UInt8](repeating: 0, count: 8)
            try put32(&entry, 0, 1)
            try put32(&entry, 4, UInt32(lastDelta - cut))
            let ancestors = [moov, sound.trak, sound.mdia, sound.minf, sound.stbl, stts]
            for box in ancestors where box.header == 8 {
                guard box.size + 8 <= Int(UInt32.max) else { throw damaged }
            }
            b.insert(contentsOf: entry, at: stts.end)
            for box in ancestors {
                if box.header == 16 { try put64(&b, box.start + 8, UInt64(box.size + 8)) }
                else { try put32(&b, box.start, UInt32(box.size + 8)) }
            }
        }
    }

    private static func setDuration(_ b: inout [UInt8], _ box: Box, v0: Int, v1: Int, _ value: UInt64) throws {
        if try version(b, box) == 1 { try write64(&b, box, v1, value) }
        else { try write32(&b, box, v0, UInt32(clamping: value)) }
    }
}
