import Foundation
import ImageIO

/// Batch Rename. In the app it opens the rename window (the app intercepts this id).
/// Headless (CLI/agents): `csx run organize.batchRename files… --opt rules='[{"prefix":{"_0":"2026 "}}]'`.
struct BatchRenameAction: PowerAction {
    let descriptor = ActionDescriptor(id: "organize.batchRename", title: "Batch Rename…", symbol: "character.cursor.ibeam", group: .organize,
                                      summary: "Rename many files with rules and a live preview you can edit.")

    func run(_ c: ActionContext) async throws -> ActionResult {
        guard let json = c.options["rules"] else { throw PowerError.unsupported("Batch Rename opens in the Clicksmith app.") }
        let rules = try JSONDecoder().decode([RenameRule].self, from: Data(json.utf8))
        let plans = RenameSession.plans(RenameSession.items(c.inputs), rules: rules)
        if let bad = plans.first(where: { $0.conflict != nil && $0.conflict != .unchanged }) {
            throw PowerError.badInput("Cannot rename “\(bad.source.lastPathComponent)” to “\(bad.newName)”. \(bad.conflict?.message ?? "")")
        }
        let changed = try RenameSession.apply(plans, files: c.files)
        return ActionResult(changed: changed, message: "Renamed \(changed.count) item\(changed.count == 1 ? "" : "s").")
    }
}

/// Glue between the rename engine, file facts, user edits and the journal.
public enum RenameSession {
    public static func items(_ urls: [URL], now: Date = Date(), timeZone: TimeZone = .current) -> [RenameItem] {
        urls.map { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey])
            return RenameItem(url: u, facts: .init(isDirectory: v?.isDirectory ?? false, created: v?.creationDate,
                                                   modified: v?.contentModificationDate, exifDate: exifDate(u, timeZone: timeZone), now: now,
                                                   timeZone: timeZone))
        }
    }

    /// Rule results, then the user's hand edits (`overrides`: source → new name), then one conflict check over all.
    public static func plans(_ items: [RenameItem], rules: [RenameRule], overrides: [URL: String] = [:]) -> [RenamePlan] {
        let base = RenameEngine.preview(items, rules: rules)
        guard !overrides.isEmpty else { return base }
        let checked = RenameEngine.check(base.map { RenamePlan(source: $0.source, newName: overrides[$0.source] ?? $0.newName) })
        // A rule error (bad regex, missing date…) on a row the user did not edit stays an error.
        return zip(base, checked).map { b, c in
            overrides[b.source] == nil && b.conflict == .invalidName ? RenamePlan(source: c.source, newName: c.newName, conflict: .invalidName) : c
        }
    }

    /// Apply through FileOps (journaled, never replaces). Returns the new URLs of renamed items.
    @discardableResult
    public static func apply(_ plans: [RenamePlan], files: FileOps) throws -> [URL] {
        try RenameEngine.apply(plans) { from, to in _ = try files.moveExact(from, to: to) }
        return plans.filter { $0.conflict == nil }.map { $0.source.deletingLastPathComponent().appendingPathComponent($0.newName) }
    }

    /// EXIF has no zone: read the wall clock in `timeZone`, and print in the same zone, so the day never shifts.
    static func exifDate(_ url: URL, timeZone: TimeZone = .current) -> Date? {
        let imageExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "avif", "webp"]
        guard imageExts.contains(url.pathExtension.lowercased()),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy:MM:dd HH:mm:ss"; f.timeZone = timeZone
        return f.date(from: s)
    }
}
