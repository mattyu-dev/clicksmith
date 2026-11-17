import AVFoundation
import AudioToolbox
import Foundation

/// AVFoundation omits some native audio tags, including WAVE's ICRD. Read those
/// chunks as well, and recover text previously preserved in a PCM comment chunk.
enum MediaMetadata {
    static func writerItems(_ asset: AVAsset, fileType: AVFileType = .mov) async throws -> [AVMetadataItem] {
        let original = try await asset.load(.metadata)
        var items = original.filter { $0.keySpace != .audioFile }
        if original.contains(where: { $0.keySpace == .audioFile }) {
            let values = try await text(asset)
            if !values.isEmpty {
                let preserved = AVMutableMetadataItem()
                preserved.keySpace = .quickTimeMetadata
                preserved.key = "org.clicksmith.sourceMetadata" as NSString
                preserved.value = String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), as: UTF8.self) as NSString
                items.append(preserved)
                if let date = values["recorded date"], !items.contains(where: { $0.identifier == .quickTimeMetadataCreationDate }) {
                    let creation = AVMutableMetadataItem()
                    creation.identifier = .quickTimeMetadataCreationDate
                    creation.value = date as NSString
                    items.append(creation)
                }
            }
        }
        // A source with only a movie-header date (no metadata tag) would lose its
        // date, because the writer stamps a new header. Keep it as a tag.
        if !items.contains(where: isCreationDate), let date = try await sourceDate(asset) {
            let creation = AVMutableMetadataItem()
            creation.identifier = .quickTimeMetadataCreationDate
            creation.value = iso8601(date) as NSString
            items.append(creation)
        }
        return containerItems(items, fileType: fileType)
    }

    static func isCreationDate(_ item: AVMetadataItem) -> Bool {
        item.commonKey == .commonKeyCreationDate || [AVMetadataIdentifier.quickTimeMetadataCreationDate,
            .quickTimeUserDataCreationDate, .commonIdentifierCreationDate, .isoUserDataDate, .iTunesMetadataReleaseDate].contains(item.identifier)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The date the source was recorded: a metadata date tag first, then the
    /// QuickTime movie header (AVAsset.creationDate falls back to it). Nil when
    /// unset or implausible (before 1971).
    static func sourceDate(_ asset: AVAsset) async throws -> Date? {
        var candidates = try await asset.load(.metadata).filter(isCreationDate)
        if let creation = try await asset.load(.creationDate) { candidates.append(creation) }
        for item in candidates {
            var date = try await item.load(.dateValue)
            if date == nil, let text = try await item.load(.stringValue) { date = parseDate(text) }
            if let date, date.timeIntervalSince1970 > 365 * 86_400 { return date }
        }
        return nil
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone], [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    /// MP4/M4A do not retain QuickTime mdta date/location tags. Write their
    /// supported user-data equivalents, ©day and ©xyz, with the original value.
    /// The MP4 writer stores these as ISO 'date' and 'loci' boxes. 'loci' is
    /// 16.16 fixed point and always has an altitude, so "+48.8566+002.3522/"
    /// reads back as "+48.8566+002.3522+000.000/" (same coordinates).
    static func containerItems(_ items: [AVMetadataItem], fileType: AVFileType) -> [AVMetadataItem] {
        guard fileType == .mp4 || fileType == .m4a else { return items }
        return items.map { item in
            let target: AVMetadataIdentifier?
            switch item.identifier {
            case .quickTimeMetadataCreationDate, .commonIdentifierCreationDate:
                target = .quickTimeUserDataCreationDate
            case .quickTimeMetadataLocationISO6709, .commonIdentifierLocation:
                target = .quickTimeUserDataLocationISO6709
            default: target = nil
            }
            guard let target, let copy = item.mutableCopy() as? AVMutableMetadataItem else { return item }
            // User-data keys are boxed FourCCs. Avoid the identifier setter, which
            // passes ©day/©xyz as unboxed pointers in this SDK/runtime combination.
            copy.key = nil
            copy.keySpace = .quickTimeUserData
            copy.key = NSNumber(value: target == .quickTimeUserDataCreationDate ? UInt32(0xA9646179) : UInt32(0xA978797A))
            copy.dataType = kCMMetadataBaseDataType_UTF8 as String
            return copy
        }
    }

    static func text(_ asset: AVAsset) async throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try await asset.load(.metadata) {
            guard let value = try await item.load(.stringValue) else { continue }
            let key = item.identifier?.rawValue ?? item.commonKey?.rawValue ?? ""
            let decoded = key.removingPercentEncoding ?? key
            if ["approximate duration in seconds", "nominal bit rate", "channel layout", "source bit depth"].contains(where: decoded.hasSuffix) { continue }
            if decoded.hasSuffix("comments") || decoded == "mdta/org.clicksmith.sourceMetadata",
               let preserved = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: String] {
                result.merge(preserved) { _, new in new }
                continue
            }
            if !key.isEmpty { result[key] = value }
            if item.commonKey == .commonKeyCreationDate || item.identifier == .quickTimeMetadataCreationDate {
                result["recorded date"] = value
            }
        }
        guard let asset = asset as? AVURLAsset else { return result }
        var file: AudioFileID?
        guard AudioFileOpenURL(asset.url as CFURL, .readPermission, 0, &file) == noErr, let file else { return result }
        defer { AudioFileClose(file) }
        for data in try chunks(0x4C495354, file: file) where data.starts(with: Data("INFO".utf8)) {
            let bytes = [UInt8](data)
            var offset = 4
            while offset + 8 <= bytes.count {
                let key = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
                let size = Int(bytes[offset + 4..<offset + 8].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) })
                offset += 8
                guard size <= bytes.count - offset else { throw PowerError.badInput("The audio metadata is damaged.") }
                let value = Data(bytes[offset..<offset + size].prefix { $0 != 0 })
                switch key {
                case "ICRD": result["recorded date"] = String(decoding: value, as: UTF8.self)
                case "ICMT": mergeComment(value, into: &result)
                case "INAM": result["title"] = String(decoding: value, as: UTF8.self)
                case "IART": result["artist"] = String(decoding: value, as: UTF8.self)
                case "ICOP": result["copyright"] = String(decoding: value, as: UTF8.self)
                default: break
                }
                offset += size + size % 2
            }
        }
        for data in try chunks(0x414E4E4F, file: file) { mergeComment(data, into: &result) }
        for data in try chunks(0x696E666F, file: file) {
            let bytes = [UInt8](data)
            guard bytes.count >= 4 else { continue }
            let count = Int(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            let strings = bytes.dropFirst(4).split(separator: 0, omittingEmptySubsequences: false)
            guard count <= strings.count / 2 else { throw PowerError.badInput("The audio metadata is damaged.") }
            for index in 0..<count {
                result[String(decoding: strings[index * 2], as: UTF8.self)] = String(decoding: strings[index * 2 + 1], as: UTF8.self)
            }
        }
        return result
    }

    private static func mergeComment(_ data: Data, into result: inout [String: String]) {
        if let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            result.merge(values) { _, new in new }
        } else {
            result["comments"] = String(decoding: data, as: UTF8.self)
        }
    }

    private static func chunks(_ identifier: UInt32, file: AudioFileID) throws -> [Data] {
        var count: UInt32 = 0
        guard AudioFileCountUserData(file, identifier, &count) == noErr else { return [] }
        var result: [Data] = []
        var total = 0
        for index in 0..<count {
            var size: UInt32 = 0
            try MediaIO.check(AudioFileGetUserDataSize(file, identifier, index, &size), "Cannot read audio metadata.")
            total += Int(size)
            guard total <= 16 * 1024 * 1024 else { throw PowerError.unsupported("The audio metadata is too large to preserve.") }
            if size == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: Int(size))
            try MediaIO.check(AudioFileGetUserData(file, identifier, index, &size, &bytes), "Cannot read audio metadata.")
            result.append(Data(bytes.prefix(Int(size))))
        }
        return result
    }
}
