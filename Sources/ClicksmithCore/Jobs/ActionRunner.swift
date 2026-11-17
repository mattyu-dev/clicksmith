import Foundation

/// Runs one ActionRequest: resolve the action, check inputs, run, journal for undo.
public struct ActionRunner: Sendable {
    public let registry: ActionRegistry
    public let journal: UndoJournal
    public let environment: ActionEnvironment
    public let settings: ClicksmithSettings
    public let paths: SharedPaths

    public init(registry: ActionRegistry, journal: UndoJournal, environment: ActionEnvironment, settings: ClicksmithSettings, paths: SharedPaths = .standard) {
        self.registry = registry; self.journal = journal; self.environment = environment; self.settings = settings; self.paths = paths
    }

    public struct Outcome: Sendable {
        public var result: ActionResult
        public var transaction: JournalTransaction?
        public var error: PowerError?
        /// Files changed but the undo record could not be saved.
        public var journalError: String?
        public var succeeded: Bool { error == nil && journalError == nil && result.failures.isEmpty }
    }

    public func run(_ request: ActionRequest, progress: ProgressSink = NoProgress(),
                    isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }) async -> Outcome {
        let inbox = RequestInbox(paths: paths)
        let claimed = inbox.isClaimed(request.id)
        do { try inbox.markStarted(request) }
        catch {
            return Outcome(result: .none, transaction: nil, error: .failed("Could not start this request.", detail: error.localizedDescription))
        }
        var outcome = await runStarted(request, progress: progress, isCancelled: isCancelled)
        if claimed {
            do { try inbox.acknowledge(request.id) }
            catch {
                let warning = "The action ended, but its request could not be acknowledged: \(error.localizedDescription)"
                outcome.journalError = [outcome.journalError, warning].compactMap { $0 }.joined(separator: "\n")
            }
        }
        return outcome
    }

    private func runStarted(_ request: ActionRequest, progress: ProgressSink,
                            isCancelled: @escaping @Sendable () -> Bool) async -> Outcome {
        guard let action = registry.action(request.actionID) else {
            return Outcome(result: .none, transaction: nil, error: .unknownAction(request.actionID))
        }
        let urls = request.urls
        if let problem = Self.validate(action.descriptor, urls) {
            return Outcome(result: .none, transaction: nil, error: .badInput(problem))
        }
        let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            return Outcome(result: .none, transaction: nil, error: .badInput("Not found: \(missing.map(\.lastPathComponent).joined(separator: ", "))"))
        }
        let ops: FileOps
        do { ops = try FileOps(journal: journal, actionID: action.descriptor.id, title: action.descriptor.title) }
        catch {
            return Outcome(result: .none, transaction: nil, error: nil,
                           journalError: "The action did not start because its undo recovery record could not be saved: \(error.localizedDescription)")
        }
        let ctx = ActionContext(
            inputs: urls,
            targetDirectory: request.targetDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) },
            options: request.options, files: ops, environment: environment, progress: progress,
            settings: settings, paths: paths, isCancelled: isCancelled)
        var outcome = Outcome(result: .none, transaction: nil, error: nil)
        do {
            outcome.result = try await action.run(ctx)
            if outcome.result.cancelled { outcome.error = .cancelled }
        } catch let e as PowerError {
            outcome.error = e
        } catch is CancellationError {
            outcome.error = .cancelled
        } catch {
            outcome.error = .failed(action.descriptor.title + " failed.", detail: error.localizedDescription)
        }
        // Journal whatever happened, even on error/cancel, so partial work stays undoable.
        do {
            outcome.transaction = try ops.commit(to: journal, actionID: action.descriptor.id, title: action.descriptor.title)
        } catch {
            outcome.journalError = "The action ended, but its undo journal could not be finalized. Pending recovery records were kept for retry: \(error.localizedDescription)"
        }
        return outcome
    }

    /// Same rules the Finder menu uses, enforced again here (CLI and IPC can send anything).
    static func validate(_ d: ActionDescriptor, _ urls: [URL]) -> String? {
        if urls.count < d.minCount { return "\(d.title) needs at least \(d.minCount) item\(d.minCount == 1 ? "" : "s")." }
        if let max = d.maxCount, urls.count > max { return "\(d.title) takes at most \(max) item\(max == 1 ? "" : "s")." }
        guard !d.extensions.isEmpty else { return nil }
        let bad = urls.filter { u in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            return isDir.boolValue ? !d.extensions.contains("/") : !d.extensions.contains(u.pathExtension.lowercased())
        }
        return bad.isEmpty ? nil : "\(d.title) does not work on \(bad.map(\.lastPathComponent).joined(separator: ", "))."
    }
}
