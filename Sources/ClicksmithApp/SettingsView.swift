import SwiftUI
import ClicksmithCore

struct SettingsView: View {
    @Environment(AppModel.self) var model
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            FinderMenuSettings().tabItem { Label("Finder Menu", systemImage: "contextualmenu.and.cursorarrow") }.tag("menu")
            DoctorSettings().tabItem { Label("Doctor", systemImage: "stethoscope") }.tag("doctor")
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .frame(width: 560, height: 460)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Show new files in Finder when an action finishes", isOn: $model.settings.revealOutputs)
            Section("Favourite folders (Copy To / Move To)") {
                ForEach(model.settings.favoriteFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.settings.favoriteFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        for u in panel.urls where !model.settings.favoriteFolders.contains(u.path) { model.settings.favoriteFolders.append(u.path) }
                    }
                }
                if !model.settings.recentFolders.isEmpty {
                    Button("Clear Recent Folders") { model.settings.recentFolders = [] }
                }
            }
            Section("Code editor") {
                Picker("Open in Editor uses", selection: $model.settings.preferredEditor) {
                    Text("First installed").tag(String?.none)
                    ForEach(Editors.installed(), id: \.bundleID) { e in Text(e.name).tag(Optional(e.bundleID)) }
                }
            }
            LabeledContent("Undo history") {
                Text("Last 50 actions. Undo never deletes files you changed since.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct FinderMenuSettings: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Menu title", text: $model.settings.menuTitle)
                Toggle("Show actions directly in the right-click menu (no submenu)", isOn: $model.settings.flattenMenu)
                Toggle("Group actions in submenus", isOn: $model.settings.groupSubmenus)
            }
            ForEach(ActionGroup.allCases, id: \.self) { group in
                let items = model.registry.descriptors.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.title) {
                        ForEach(items) { d in
                            Toggle(isOn: binding(for: d)) {
                                Label { VStack(alignment: .leading) {
                                    Text(d.title)
                                    if !d.summary.isEmpty { Text(d.summary).font(.caption).foregroundStyle(.secondary) }
                                } } icon: { Image(systemName: d.symbol) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    func binding(for d: ActionDescriptor) -> Binding<Bool> {
        Binding {
            model.settings.isVisible(d)
        } set: { on in
            if on { model.settings.hiddenActions.remove(d.id); if d.hiddenByDefault { model.settings.shownActions.insert(d.id) } }
            else { model.settings.hiddenActions.insert(d.id); model.settings.shownActions.remove(d.id) }
        }
    }
}

struct DoctorSettings: View {
    @Environment(AppModel.self) var model
    @ViewState private var checks: [DoctorCheck] = []
    @ViewState private var working = false

    var body: some View {
        Form {
            if checks.contains(where: { $0.status == .problem }) {
                Section("Turn on the Clicksmith Finder menu") {
                    Text("1. Press Fix below. Clicksmith turns the menu on and reloads it (Finder keeps running).\n2. If the menu still does not show: open System Settings ▸ General ▸ Login Items & Extensions ▸ Finder Extensions, and turn on Clicksmith Menu.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
                    }
                }
            }
            Section {
                ForEach(checks) { c in
                    HStack(alignment: .top) {
                        Image(systemName: c.status == .ok ? "checkmark.circle.fill" : c.status == .warning ? "exclamationmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(c.status == .ok ? .green : c.status == .warning ? .orange : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Finder menu health")
            } footer: {
                Text("If the right-click menu does not show, press Fix. Clicksmith re-registers the extension, turns it on and reloads the Finder menu. Finder restarts only if the reload does not work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check Again") { refresh() }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Fix Problems") { fix() }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !checks.contains { $0.fix != nil })
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    func refresh() { checks = model.doctor.diagnose() }

    func fix() {
        working = true
        let doctor = model.doctor
        // Menu writes go through AppModel on the main actor, from current settings (review #7).
        if checks.contains(where: { $0.fix == .rewriteMenu }) { try? model.writeMenuFile() }
        Task.detached {
            let result = doctor.fixAll()
            await MainActor.run { checks = result; working = false }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Clicksmith").font(.title.bold())
            Text("Version \(ClicksmithCore.version)").foregroundStyle(.secondary)
            Text("Right-click superpowers for Finder. Local only: no network, no tracking.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
