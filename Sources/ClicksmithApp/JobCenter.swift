import Foundation
import Observation
import ClicksmithCore

/// One running or finished action, shown in the menu bar.
@MainActor @Observable
final class Job: Identifiable {
    enum State: Equatable { case running, succeeded, failed(String), cancelled }

    let id = UUID()
    let title: String
    let actionID: String
    let started = Date()
    var done = 0
    var total = 0
    var current: String?
    var state: State = .running
    var message: String?
    var created: [URL] = []
    var failures: [ActionResult.Failure] = []
    var rememberFolder: URL?
    var menuChanged = false
    var revealCreated = false
    @ObservationIgnored let cancelFlag = CancelFlag()
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, actionID: String) { self.title = title; self.actionID = actionID }

    var fraction: Double? { total > 0 ? Double(done) / Double(total) : nil }

    func cancel() { cancelFlag.set(); task?.cancel() }
}

/// Thread-safe cancel flag read by Core from any thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Bridges Core progress (any thread) to the Job (main actor).
struct JobProgress: ProgressSink {
    let job: Job
    func update(done: Int, total: Int, current: String?) async {
        await MainActor.run { job.done = done; job.total = total; job.current = current }
    }
}

@MainActor @Observable
final class JobCenter {
    static let shared = JobCenter()
    private(set) var jobs: [Job] = []

    var running: [Job] { jobs.filter { $0.state == .running } }

    func start(title: String, actionID: String, run: @escaping @Sendable (Job, @escaping @Sendable () -> Bool) async -> ActionRunner.Outcome) -> Job {
        let job = Job(title: title, actionID: actionID)
        jobs.append(job)
        // Trim history: finished jobs only, never a running one (review #6).
        while jobs.count > 40, let i = jobs.firstIndex(where: { $0.state != .running }) { jobs.remove(at: i) }
        let flag = job.cancelFlag
        job.task = Task { @MainActor in
            let o = await run(job, { flag.isSet || Task.isCancelled })
            job.created = o.result.created
            job.failures = o.result.failures
            job.rememberFolder = o.result.rememberFolder
            job.menuChanged = o.result.menuChanged
            job.revealCreated = o.result.revealCreated
            job.message = o.result.message ?? o.error?.localizedDescription
            switch o.error {
            case .none where o.journalError != nil:
                job.state = .failed(o.journalError!); job.message = o.journalError      // review #4
            case .none: job.state = o.result.failures.isEmpty ? .succeeded : .failed("\(o.result.failures.count) failed")
            case .cancelled?: job.state = .cancelled
            case let e?: job.state = .failed(e.localizedDescription)
            }
        }
        return job
    }



    /// Short results shown in the progress panel (success fades, errors stay until closed).
    var notices: [Notice] = []
}
