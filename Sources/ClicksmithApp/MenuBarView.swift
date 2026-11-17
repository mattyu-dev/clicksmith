import SwiftUI
import ClicksmithCore

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                if job.state == .running {
                    if let f = job.fraction { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
                    if let c = job.current { Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                } else if let m = job.message {
                    Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if job.state == .running {
                Button { job.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).help("Cancel")
            } else if !job.created.isEmpty {
                Button { NSWorkspace.shared.activateFileViewerSelecting(job.created) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder")
            }
        }
    }

    @ViewBuilder var icon: some View {
        switch job.state {
        case .running: Image(systemName: "bolt.fill").foregroundStyle(.tint)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
