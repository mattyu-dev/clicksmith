import AppKit
import SwiftUI
import ClicksmithCore

/// One editable rule in the window. Maps to the engine's RenameRule.
struct RuleDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case replace = "Find & Replace", prefix = "Add Prefix", suffix = "Add Suffix", changeCase = "Change Case",
             sequence = "Number", datePrefix = "Date Prefix", regex = "Regex", trim = "Clean Spaces",
             remove = "Remove Characters", ext = "Extension", insert = "Insert Text", truncate = "Shorten"
        var id: String { rawValue }
    }
    let id = UUID()
    var kind: Kind
    var a = ""            // text / find / pattern / characters
    var b = ""            // replacement / template / date format
    var flag = false      // case sensitive
    var number = 1        // start / position / max length
    var step = 1
    var padding = 2
    var caseStyle: RenameRule.CaseStyle = .lower
    var dateSource: RenameRule.DateSource = .exifTaken
    var extChoice = "lower"
    var atEnd = false

    init(_ kind: Kind) {
        self.kind = kind
        if kind == .datePrefix { b = "yyyy-MM-dd " }
        if kind == .regex { b = "$1" }
        if kind == .truncate { number = 40 }
        if kind == .insert { number = 0 }
    }

    var rules: [RenameRule] {
        switch kind {
        case .replace: return a.isEmpty ? [] : [.replace(find: a, with: b, caseSensitive: flag)]
        case .prefix: return a.isEmpty ? [] : [.prefix(a)]
        case .suffix: return a.isEmpty ? [] : [.suffix(a)]
        case .changeCase: return [.changeCase(caseStyle)]
        case .sequence: return [.sequence(start: number, step: max(1, step), padding: padding, position: atEnd ? .suffix : .prefix, separator: a.isEmpty ? " " : a)]
        case .datePrefix: return [.datePrefix(source: dateSource, format: b)]
        case .regex: return a.isEmpty ? [] : [.regex(pattern: a, template: b)]
        case .trim: return [.trimWhitespace, .collapseWhitespace]
        case .remove: return a.isEmpty ? [] : [.removeCharacters(set: a)]
        case .ext:
            switch extChoice {
            case "upper": return [.extension(.upper)]
            case "remove": return [.extension(.remove)]
            case "set": return a.isEmpty ? [] : [.extension(.set(a))]
            default: return [.extension(.lower)]
            }
        case .insert: return a.isEmpty ? [] : [.insert(text: a, at: number)]
        case .truncate: return [.truncate(maxLength: max(1, number))]
        }
    }
}

@MainActor @Observable
final class RenameModel {
    let items: [RenameItem]
    var drafts: [RuleDraft] = [RuleDraft(.replace)]
    var overrides: [URL: String] = [:]
    var error: String?
    var done = false
    /// Renames done but not yet saved for undo (journal write failed). Kept so the user can retry.
    @ObservationIgnored var unsaved: FileOps?
    var needsSave = false

    init(urls: [URL]) {
        items = RenameSession.items(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
    }

    var plans: [RenamePlan] { RenameSession.plans(items, rules: drafts.flatMap(\.rules), overrides: overrides) }
    var blocking: [RenamePlan] { plans.filter { $0.conflict != nil && $0.conflict != .unchanged } }
    var changeCount: Int { plans.filter { $0.conflict == nil }.count }

    func apply(model: AppModel) {
        let ops = FileOps()
        var renameError: Error?
        do { try RenameSession.apply(plans, files: ops) } catch { renameError = error }
        save(ops, model: model, title: renameError == nil ? "Batch Rename" : "Batch Rename (partial)")
        if let renameError { error = renameError.localizedDescription }
        else if !needsSave { done = true }
    }

    /// Never drop undo records: if saving fails, keep them and offer Retry.
    func save(_ ops: FileOps, model: AppModel, title: String) {
        do {
            try ops.commit(to: model.journal, actionID: "organize.batchRename", title: title)
            unsaved = nil; needsSave = false
        } catch {
            unsaved = ops; needsSave = true
            self.error = "Renamed, but undo could not be saved: \(error.localizedDescription)"
        }
        model.refreshUndo()
    }

    func retrySave(model: AppModel) {
        guard let ops = unsaved else { return }
        save(ops, model: model, title: "Batch Rename")
        if !needsSave { error = nil; done = true }
    }
}

struct RenameView: View {
    @Bindable var m: RenameModel
    let app: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                rulesPane.frame(width: 330)
                Divider()
                previewPane
            }
            Divider()
            HStack {
                if let e = m.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2) }
                else if !m.blocking.isEmpty { Label("\(m.blocking.count) name\(m.blocking.count == 1 ? "" : "s") to fix", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red) }
                else { Text("\(m.changeCount) of \(m.items.count) will change").foregroundStyle(.secondary) }
                Spacer()
                if m.needsSave { Button("Retry Saving Undo") { m.retrySave(model: app); if m.done { close() } } }
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction).disabled(m.needsSave)
                Button("Rename \(m.changeCount)") { m.apply(model: app); if m.done { close() } }
                    .disabled(m.needsSave)   // never start a new rename while the last one's undo is unsaved
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.changeCount == 0 || !m.blocking.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    var rulesPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Menu {
                    ForEach(RuleDraft.Kind.allCases) { k in Button(k.rawValue) { m.drafts.append(RuleDraft(k)) } }
                } label: { Label("Add Rule", systemImage: "plus") }
                .fixedSize()
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($m.drafts) { $d in
                        RuleEditor(draft: $d) { m.drafts.removeAll { $0.id == d.id } }
                    }
                }
            }
            Text("Rules run top to bottom. Double-click a new name to edit it by hand.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    var previewPane: some View {
        List(m.plans, id: \.source) { p in
            HStack(spacing: 8) {
                Text(p.source.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                TextField("", text: Binding(get: { p.newName }, set: { m.overrides[p.source] = $0 }))
                    .textFieldStyle(.plain)
                    .foregroundStyle(p.conflict == nil ? .primary : p.conflict == .unchanged ? .secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let c = p.conflict, c != .unchanged {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).help(c.rawValue)
                }
            }
        }
    }
}

struct RuleEditor: View {
    @Binding var draft: RuleDraft
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $draft.kind) { ForEach(RuleDraft.Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize()
                Spacer()
                Button(action: remove) { Image(systemName: "minus.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            fields
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder var fields: some View {
        switch draft.kind {
        case .replace:
            TextField("Find", text: $draft.a); TextField("Replace with", text: $draft.b)
            Toggle("Match case", isOn: $draft.flag)
        case .prefix, .suffix: TextField("Text", text: $draft.a)
        case .changeCase:
            Picker("Case", selection: $draft.caseStyle) { ForEach(RenameRule.CaseStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
        case .sequence:
            Stepper("Start at \(draft.number)", value: $draft.number, in: 0...999_999)
            Stepper("Step \(draft.step)", value: $draft.step, in: 1...1000)
            Stepper("Digits \(draft.padding)", value: $draft.padding, in: 1...8)
            TextField("Separator", text: $draft.a)
            Toggle("At the end", isOn: $draft.atEnd)
        case .datePrefix:
            Picker("Date", selection: $draft.dateSource) {
                Text("Photo taken").tag(RenameRule.DateSource.exifTaken); Text("Created").tag(RenameRule.DateSource.created)
                Text("Modified").tag(RenameRule.DateSource.modified); Text("Today").tag(RenameRule.DateSource.now)
            }
            TextField("Format", text: $draft.b)
        case .regex: TextField("Pattern", text: $draft.a); TextField("Replace with ($1…)", text: $draft.b)
        case .trim: Text("Trim and collapse spaces.").font(.caption).foregroundStyle(.secondary)
        case .remove: TextField("Characters to remove", text: $draft.a)
        case .ext:
            Picker("Extension", selection: $draft.extChoice) {
                Text("lowercase").tag("lower"); Text("UPPERCASE").tag("upper"); Text("Set…").tag("set"); Text("Remove").tag("remove")
            }
            if draft.extChoice == "set" { TextField("New extension", text: $draft.a) }
        case .insert: TextField("Text", text: $draft.a); Stepper("At position \(draft.number)", value: $draft.number, in: 0...255)
        case .truncate: Stepper("Max \(draft.number) characters", value: $draft.number, in: 1...255)
        }
    }
}

@MainActor
enum RenameWindowController {
    private static var windows: [NSWindow] = []
    private static var models: [ObjectIdentifier: RenameModel] = [:]
    private static var guards: [ObjectIdentifier: CloseGuard] = [:]

    /// Refuses ⌘W / the close button while undo records are unsaved.
    final class CloseGuard: NSObject, NSWindowDelegate {
        let model: RenameModel
        init(_ model: RenameModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model.needsSave { NSSound.beep(); return false }
            return true
        }
    }

    /// A rename window whose undo records are not saved yet: quitting would lose them.
    static var unsavedWindow: NSWindow? {
        windows.first { models[ObjectIdentifier($0)]?.needsSave == true }
    }

    static func open(_ urls: [URL], app: AppModel) {
        let model = RenameModel(urls: urls)
        var window: NSWindow!
        let view = RenameView(m: model, app: app) { window.close() }
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window?.identifier = NSUserInterfaceItemIdentifier("clicksmith.user")
        window.title = "Batch Rename — \(urls.count) item\(urls.count == 1 ? "" : "s")"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 540))
        window.center()
        windows.append(window)
        let id = ObjectIdentifier(window)
        models[id] = model
        let closeGuard = CloseGuard(model); guards[id] = closeGuard; window.delegate = closeGuard
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { ObjectIdentifier($0) == id }; models[id] = nil; guards[id] = nil }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
