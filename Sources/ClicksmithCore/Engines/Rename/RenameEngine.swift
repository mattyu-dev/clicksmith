import Foundation

public enum RenameEngine {
    public static func preview(_ items: [RenameItem], rules: [RenameRule]) -> [RenamePlan] {
        validate(items.enumerated().map { transform($0.element, index: $0.offset, rules: rules) })
    }

    /// The callback must move without overwriting, and throw without moving on failure.
    /// All temporary and rollback moves also pass through it for journaling.
    public static func apply(_ plans: [RenamePlan], using move: (URL, URL) throws -> Void) throws {
        for plan in plans {
            if let conflict = plan.conflict, conflict != .unchanged {
                throw PowerError.badInput("Cannot rename \(plan.source.lastPathComponent). " + conflict.message)
            }
            guard plan.source.isFileURL else {
                throw PowerError.badInput("Only local file URLs can be renamed.")
            }
        }
        let checked = validate(plans.map { RenamePlan(source: $0.source, newName: $0.newName) })
        for plan in checked {
            if let conflict = plan.conflict, conflict != .unchanged {
                throw PowerError.badInput("Cannot rename \(plan.source.lastPathComponent). " + conflict.message)
            }
            guard entryExists(plan.source) else {
                throw PowerError.failed("The file \(plan.source.lastPathComponent) no longer exists.", detail: plan.source.path)
            }
        }
        let changed = checked.filter { $0.conflict != .unchanged }
        // Moving a selected directory would invalidate a selected descendant's location.
        let sourcePaths = checked.map { key($0.source) }
        for plan in changed {
            let path = key(plan.source.resolvingSymlinksInPath()) + "/"
            if sourcePaths.contains(where: { $0.utf8.starts(with: path.utf8) }) {
                throw PowerError.badInput("Rename a directory and its children in separate batches.")
            }
        }
        var reserved = Set(checked.flatMap { [key($0.source), key(destination($0))] })
        var moves: [Move] = []
        for plan in changed {
            var temporary: URL
            repeat {
                temporary = plan.source.deletingLastPathComponent()
                    .appendingPathComponent(temporaryName(for: plan.source))
            } while reserved.contains(key(temporary)) || entryExists(temporary)
            reserved.insert(key(temporary))
            moves.append(Move(source: plan.source, destination: destination(plan), temporary: temporary))
        }

        var attemptedSource: URL?
        var attemptedDestination: URL?
        do {
            for index in moves.indices {
                attemptedSource = moves[index].source
                attemptedDestination = moves[index].temporary
                try move(moves[index].source, moves[index].temporary)
                moves[index].location = .temporary
            }
            for index in moves.indices {
                attemptedSource = moves[index].temporary
                attemptedDestination = moves[index].destination
                try move(moves[index].temporary, moves[index].destination)
                moves[index].location = .destination
            }
        } catch {
            let failures = rollback(&moves, using: move)
            // These values are assigned before every throwing callback invocation.
            if let source = attemptedSource, let destination = attemptedDestination {
                let message = "Could not move \(source.lastPathComponent) to \(destination.lastPathComponent)."
                    + (failures.isEmpty ? "" : " Some files could not be restored.")
                let detail = ["\(source.path) -> \(destination.path)", String(reflecting: error), error.localizedDescription] + failures
                throw PowerError.failed(message, detail: detail.joined(separator: "\n"))
            }
            throw PowerError.failed("The rename failed.", detail: error.localizedDescription)
        }
    }

    private struct Move {
        enum Location { case original, temporary, destination }
        let source: URL
        let destination: URL
        let temporary: URL
        var location: Location = .original
    }

    private static func rollback(_ moves: inout [Move], using move: (URL, URL) throws -> Void) -> [String] {
        var failures: [String] = []
        // Free every committed destination before restoring any source. This also handles cycles.
        for index in moves.indices.reversed() where moves[index].location == .destination {
            do {
                try move(moves[index].destination, moves[index].temporary)
                moves[index].location = .temporary
            } catch {
                failures.append("Rollback failed: \(moves[index].destination.path) -> \(moves[index].temporary.path): \(error.localizedDescription)")
            }
        }
        for index in moves.indices.reversed() where moves[index].location == .temporary {
            do {
                try move(moves[index].temporary, moves[index].source)
                moves[index].location = .original
            } catch {
                failures.append("Rollback failed: \(moves[index].temporary.path) -> \(moves[index].source.path): \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// Re-check hand-edited plans (Batch Rename lets users edit names in the preview). Added by Claude for T-0012.
    public static func check(_ plans: [RenamePlan]) -> [RenamePlan] {
        validate(plans.map { RenamePlan(source: $0.source, newName: $0.newName) })
    }

    private static func validate(_ plans: [RenamePlan]) -> [RenamePlan] {
        let sourceKeys = plans.map { key($0.source) }
        let targetKeys = plans.map { key(destination($0)) }
        let sourceCounts = sourceKeys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        let targetCounts = targetKeys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        var conflicts = plans.map(\.conflict)
        var occupied: Set<String> = []
        var scanned: Set<URL> = []
        var unreadable: Set<URL> = []
        for index in plans.indices {
            let plan = plans[index]
            let directory = canonicalURL(plan.source).deletingLastPathComponent().standardizedFileURL
            if scanned.insert(directory).inserted {
                do {
                    let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    occupied.formUnion(entries.map(key))
                } catch {
                    // A nonexistent parent is useful for pure rule previews. Other read errors fail closed.
                    if FileManager.default.fileExists(atPath: directory.path) { unreadable.insert(directory) }
                }
            }
            if conflicts[index] == .invalidName || !plan.source.isFileURL
                || !validName(plan.newName, original: plan.source.lastPathComponent) || unreadable.contains(directory) {
                conflicts[index] = .invalidName
            } else if sourceCounts[sourceKeys[index], default: 0] > 1 || targetCounts[targetKeys[index], default: 0] > 1 {
                conflicts[index] = .duplicateInBatch
            } else if plan.source.lastPathComponent.utf8.elementsEqual(plan.newName.utf8) {
                conflicts[index] = .unchanged
            }
        }
        // An occupied target is available only if that source can itself leave successfully.
        var updated = true
        while updated {
            updated = false
            let moving = Set(plans.indices.filter { conflicts[$0] == nil }.map { sourceKeys[$0] })
            for index in plans.indices where conflicts[index] == nil {
                if occupied.contains(targetKeys[index]), targetKeys[index] != sourceKeys[index], !moving.contains(targetKeys[index]) {
                    conflicts[index] = .existsOnDisk
                    updated = true
                }
            }
        }
        return plans.indices.map { RenamePlan(source: plans[$0].source, newName: plans[$0].newName, conflict: conflicts[$0]) }
    }

    private static func destination(_ plan: RenamePlan) -> URL {
        plan.source.deletingLastPathComponent().appendingPathComponent(plan.newName)
    }

    private static func temporaryName(for source: URL) -> String {
        let original = source.lastPathComponent
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        var stem = isDirectory ? original : (original as NSString).deletingPathExtension
        let ext = isDirectory ? "" : (original as NSString).pathExtension
        // A stranded temporary file must also be visible when the original was hidden.
        stem = String(String.UnicodeScalarView(stem.unicodeScalars.drop(while: { $0 == "." })))
        if stem.isEmpty { stem = isDirectory ? "folder" : "file" }
        let suffix = ".clicksmith-tmp-" + UUID().uuidString.prefix(8).lowercased()
        let budget = maximumNameBytes - suffix.utf8.count
        let firstScalarBytes = stem.unicodeScalars.first.map { String($0).utf8.count } ?? 1
        // Keep the extension where possible, reserving space for a visible stem.
        let keptExtension = utf8Prefix(ext, limit: max(0, budget - firstScalarBytes - 1))
        let extensionPart = keptExtension.isEmpty ? "" : "." + keptExtension
        return utf8Prefix(stem, limit: budget - extensionPart.utf8.count) + suffix + extensionPart
    }

    private static func utf8Prefix(_ text: String, limit: Int) -> String {
        var result = ""
        var count = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            guard count + fragment.utf8.count <= limit else { break }
            result += fragment
            count += fragment.utf8.count
        }
        return result
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    private static func key(_ url: URL) -> String {
        let canonical = canonicalURL(url)
        let directory = canonical.deletingLastPathComponent()
        let caseSensitive = (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        let path = canonical.path.precomposedStringWithCanonicalMapping
        return caseSensitive ? path : path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func entryExists(_ url: URL) -> Bool {
        // attributesOfItem also sees dangling symlinks, which fileExists misses.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
