import Foundation
import ClicksmithCore

// csx — Clicksmith CLI. Runs every action headless (agents test with it).
struct CLIEnvironment: ActionEnvironment {
    func setClipboard(_ text: String) async {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe(); p.standardInput = pipe
        try? p.run(); pipe.fileHandleForWriting.write(Data(text.utf8)); try? pipe.fileHandleForWriting.close(); p.waitUntilExit()
        print("[clipboard] \(text.count > 200 ? String(text.prefix(200)) + "…" : text)")
    }
    func readClipboard() async -> ClipboardSnapshot {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return ClipboardSnapshot() }
        // Drain while pbpaste is running. Waiting first deadlocks once the pipe fills.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ClipboardSnapshot(string: String(data: data, encoding: .utf8))
    }
    func reveal(_ urls: [URL]) async { print("[reveal] \(urls.map(\.path))") }
    func open(_ urls: [URL], withApplicationAt app: URL?) async throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = (app.map { ["-a", $0.path] } ?? []) + urls.map(\.path)
        try p.run(); p.waitUntilExit()
    }
    func notify(title: String, body: String) async { print("[notify] \(title): \(body)") }
    func chooseFolder(prompt: String) async -> URL? {
        FileHandle.standardError.write(Data("no folder picker in the CLI: pass --opt dest=<folder>\n".utf8)); return nil
    }
}

struct StderrProgress: ProgressSink {
    func update(done: Int, total: Int, current: String?) async {
        FileHandle.standardError.write(Data("[\(done)/\(total)] \(current ?? "done")\n".utf8))
    }
}

func fail(_ s: String, code: Int32 = 1) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(code) }

let usage = """
usage:
  csx list [--json]                      all actions (id, group, title, variants)
  csx run <action-id> [files…] [--opt key=value …] [--dir <target>]
  csx history                            undo history, newest first
  csx undo                               undo the newest action
  csx menu [--write]                     print (or regenerate) menu.json
  csx doctor [--fix] [--app <Clicksmith.app>]   Finder menu health (and repair)
  csx paths | version
"""

let paths = SharedPaths.standard
let settings = ClicksmithSettings.load(paths)
let registry = ActionRegistry.standard()
let journal = UndoJournal(directory: paths.journal)
var args = Array(CommandLine.arguments.dropFirst())

if let command = args.first, ["run", "undo", "history"].contains(command) {
    let recovery = journal.recoverPending()
    if recovery.hasFindings { FileHandle.standardError.write(Data((recovery.summary + "\n").utf8)) }
}

switch args.first {
case "version", nil:
    print("csx \(ClicksmithCore.version)")
case "paths":
    print("root     \(paths.root.path)\nmenu     \(paths.menuFile.path)\nsettings \(paths.settingsFile.path)\ninbox    \(paths.inbox.path)\njournal  \(paths.journal.path)")
case "list":
    if args.contains("--json") {
        print(String(data: try JSONEncoder.clicksmith.encode(registry.descriptors), encoding: .utf8)!)
    } else {
        for d in registry.descriptors {
            let v = d.variants.isEmpty ? "" : "  {" + d.variants.map { $0.options.map { "\($0)=\($1)" }.sorted().joined(separator: ",") }.joined(separator: " | ") + "}"
            let ext = d.extensions.isEmpty ? "" : "  [" + d.extensions.sorted().joined(separator: ",") + "]"
            print("\(d.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(d.group.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(d.title)\(ext)\(v)")
        }
    }
case "run":
    args.removeFirst()
    guard let id = args.first else { fail(usage, code: 2) }
    args.removeFirst()
    var files: [String] = [], opts: [String: String] = [:], dir: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--opt":
            guard i + 1 < args.count, let eq = args[i + 1].firstIndex(of: "=") else { fail("--opt needs key=value", code: 2) }
            opts[String(args[i + 1][..<eq])] = String(args[i + 1][args[i + 1].index(after: eq)...]); i += 2
        case "--dir":
            guard i + 1 < args.count else { fail("--dir needs a path", code: 2) }
            dir = URL(fileURLWithPath: args[i + 1]).standardizedFileURL.path; i += 2
        default:
            files.append(URL(fileURLWithPath: args[i]).standardizedFileURL.path); i += 1
        }
    }
    let runner = ActionRunner(registry: registry, journal: journal, environment: CLIEnvironment(), settings: settings, paths: paths)
    let o = await runner.run(ActionRequest(actionID: id, paths: files, targetDirectory: dir, options: opts, source: .cli), progress: StderrProgress())
    for u in o.result.created { print("created \(u.path)") }
    for u in o.result.changed { print("changed \(u.path)") }
    if let m = o.result.message { print(m) }
    if o.result.menuChanged { try? registry.menuModel(settings: settings, paths: paths).write(to: paths.menuFile) }
    for f in o.result.failures { FileHandle.standardError.write(Data("FAILED \(f.url?.lastPathComponent ?? "-"): \(f.message)\n".utf8)) }
    if let warning = o.journalError { FileHandle.standardError.write(Data("WARNING: \(warning)\n".utf8)) }
    if let e = o.error { fail("ERROR: \(e.localizedDescription)") }
    exit(o.succeeded ? 0 : 1)
case "history":
    let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .medium
    for t in journal.list() { print("\(df.string(from: t.date))  \(t.title)  (\(t.entries.count) change\(t.entries.count == 1 ? "" : "s"))") }
case "undo":
    guard let t = journal.last else { fail("nothing to undo") }
    let r = journal.undo(t)
    print("\(t.title): \(r.summary)")
    for (p, why) in r.skipped { print("  skipped \(p): \(why)") }
case "menu":
    if args.contains("--write") {
        try paths.ensureExists()
        try registry.menuModel(settings: settings, paths: paths).write(to: paths.menuFile)
        print("wrote \(paths.menuFile.path)")
    } else if let data = try? Data(contentsOf: paths.menuFile), let s = String(data: data, encoding: .utf8) {
        print(s)
    } else { fail("no menu.json yet (run: csx menu --write)") }
case "doctor":
    // csx lives in Clicksmith.app/Contents/MacOS → the app is three levels up. Override with --app.
    var app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if let i = args.firstIndex(of: "--app"), i + 1 < args.count { app = URL(fileURLWithPath: args[i + 1]) }
    if app.pathExtension != "app" { app = SharedPaths.realHome().appendingPathComponent("Applications/Clicksmith.app") }
    let doctor = Doctor(paths: paths, appBundle: app)
    let checks = args.contains("--fix")
        ? doctor.fixAll { try registry.menuModel(settings: settings, paths: paths).write(to: paths.menuFile) }
        : doctor.diagnose()
    for c in checks {
        let mark = c.status == .ok ? "OK  " : c.status == .warning ? "WARN" : "FAIL"
        print("\(mark) \(c.title): \(c.detail)\(c.fix.map { "  [fix: \($0.rawValue)]" } ?? "")")
    }
    exit(checks.contains { $0.status == .problem } ? 1 : 0)
default:
    fail(usage, code: 2)
}
