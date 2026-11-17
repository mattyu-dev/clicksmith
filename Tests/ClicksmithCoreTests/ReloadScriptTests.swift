import Foundation
import Testing

/// T-0019 (Codex #2, #5): scripts/reload-finder-menu.sh with fake pluginkit/pgrep/pkill/killall/sleep.
/// PATH starts with the fake tools, so no real tool that changes Finder can run.
@Suite(.serialized) struct ReloadScriptTests {
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../scripts/reload-finder-menu.sh").standardizedFileURL

    struct Rig {
        let dir: URL
        var log: URL { dir.appendingPathComponent("calls.log") }
        var pids: URL { dir.appendingPathComponent("pids") }
        var heartbeat: URL { dir.appendingPathComponent("hb.json") }
        var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    /// newPID: pid that `pluginkit -e use` starts (writes heartbeat). sleepBody: fake sleep script.
    func rig(oldPID: String = "200", newPID: String?, sleepBody: String = "/bin/sleep 0.05", dir given: URL? = nil) throws -> Rig {
        let dir = try given ?? tempDir("reload")
        let bin = dir.appendingPathComponent("bin"); try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let r = Rig(dir: dir)
        try "\(oldPID)\n".write(to: r.pids, atomically: true, encoding: .utf8)
        try #"{"loaded":"2026-11-17T10:00:00Z","pid":"\#(oldPID)"}"#.write(to: r.heartbeat, atomically: true, encoding: .utf8)
        let use = newPID.map { """
            if [ "$1 $2" = "-e use" ] && ! grep -qx \($0) "\(r.pids.path)"; then
              echo \($0) >> "\(r.pids.path)"
              printf '{"loaded":"2026-11-17T10:00:00Z","pid":"\($0)"}' > "\(r.heartbeat.path)"
            fi
            """ } ?? ""
        let tools: [String: String] = [
            "pluginkit": "echo \"pluginkit $*\" >> \"\(r.log.path)\"\n\(use)",
            "pgrep": "if [ \"$1\" = -x ]; then echo 500; exit 0; fi\n[ -s \"\(r.pids.path)\" ] || exit 1\ncat \"\(r.pids.path)\"",
            "pkill": "echo \"pkill $*\" >> \"\(r.log.path)\"\n: > \"\(r.pids.path)\"",
            "killall": "echo \"killall $*\" >> \"\(r.log.path)\"",
            "sleep": sleepBody,
        ]
        for (name, body) in tools {
            let f = bin.appendingPathComponent(name)
            try "#!/bin/bash\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        return r
    }

    func start(_ r: Rig, _ args: [String] = []) throws -> (Process, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.script.path] + args
        p.environment = ["PATH": r.dir.appendingPathComponent("bin").path + ":/usr/bin:/bin",
                         "CLICKSMITH_HEARTBEAT": r.heartbeat.path, "RELOAD_WAIT": "1", "HOME": r.dir.path]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try p.run()
        return (p, out)
    }

    func run(_ r: Rig, _ args: [String] = []) throws -> (Int32, String) {
        let (p, out) = try start(r, args)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func newPidIsOK() throws {
        let r = try rig(newPID: "201")
        let (code, out) = try run(r)
        #expect(code == 0 && out.contains("RELOAD OK") && out.contains("heartbeat 201 2026-11-17T10:00:00Z\n"), "\(out)")
        #expect(r.calls.first == "pluginkit -e ignore -i dev.clicksmith.app.finder")
        #expect(r.calls.last == "pluginkit -e use -i dev.clicksmith.app.finder")
        #expect(!r.calls.contains { $0.hasPrefix("killall") || $0.hasPrefix("pkill") })
    }

    @Test("Codex #5: same pid again (even with a new heartbeat) is not OK") func samePidIsWarn() throws {
        let r = try rig(newPID: nil)
        try #"{"loaded":"2026-11-17T10:00:05Z","pid":"200"}"#.write(to: r.heartbeat, atomically: true, encoding: .utf8)
        let (_, out) = try run(r)
        #expect(out.contains("RELOAD WARN") && !out.contains("RELOAD OK"), "\(out)")
    }

    @Test("round 2 #4: a dialog copy's heartbeat is not OK") func dialogHeartbeatIsWarn() throws {
        // During the pause an Open/Save dialog copy (pid 201) starts and writes the heartbeat.
        let dir = try tempDir("dlg")
        let pids = dir.appendingPathComponent("pids").path, hb = dir.appendingPathComponent("hb.json").path
        let r = try rig(newPID: nil, sleepBody: """
            grep -qx 201 "\(pids)" || echo 201 >> "\(pids)"
            printf '{"host":"com.apple.appkit.xpc.openAndSavePanelService","loaded":"2026-11-17T10:00:05Z","pid":"201"}' > "\(hb)"
            """, dir: dir)
        let (_, out) = try run(r)
        #expect(out.contains("extension 200→200,201"), "dialog copy runs: \(out)")
        #expect(out.contains("RELOAD WARN"), "\(out)")
    }

    @Test("Codex #2: a failing step still turns the extension back on") func failureRestores() throws {
        let r = try rig(newPID: "201", sleepBody: "exit 1")
        let (code, out) = try run(r)
        #expect(code != 0 && !out.contains("RELOAD OK"), "\(out)")
        #expect(r.calls == ["pluginkit -e ignore -i dev.clicksmith.app.finder", "pluginkit -e use -i dev.clicksmith.app.finder"], "\(r.calls)")
    }

    @Test("Codex #2: interrupted during the pause → extension turned back on") func interruptRestores() throws {
        let r = try rig(newPID: "201", sleepBody: "/bin/sleep 1")
        let (p, out) = try start(r)
        for _ in 0..<50 where !r.calls.contains(where: { $0.contains("ignore") }) { Thread.sleep(forTimeInterval: 0.02) }
        p.terminate()   // SIGTERM while it sleeps with the extension disabled
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Bounded wait: waitUntilExit() from a test thread hung once under load after the script had exited.
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try #require(!p.isRunning, "script did not exit")
        #expect(p.terminationStatus != 0 && !text.contains("RELOAD"), "\(text)")
        #expect(r.calls.first == "pluginkit -e ignore -i dev.clicksmith.app.finder")
        #expect(r.calls.last == "pluginkit -e use -i dev.clicksmith.app.finder", "\(r.calls)")
    }

    @Test("Codex #3: restart path stops our extension before Finder, then turns it back on") func restartOrder() throws {
        let r = try rig(newPID: "201")
        let (_, out) = try run(r, ["--restart-finder"])
        let c = r.calls
        #expect(c.first == "pluginkit -e ignore -i dev.clicksmith.app.finder", "\(c)")
        let pk = c.firstIndex { $0.hasPrefix("pkill") }, ka = c.firstIndex { $0.hasPrefix("killall") }
        #expect(pk != nil && ka != nil && pk! < ka!, "\(c)")
        #expect(c.last == "pluginkit -e use -i dev.clicksmith.app.finder")
        #expect(out.contains("RELOAD OK"), "\(out)")
    }

    @Test("Codex #3: an extension that does not stop → Finder is not restarted") func unstoppable() throws {
        let r = try rig(newPID: nil)
        let pkill = r.dir.appendingPathComponent("bin/pkill")
        try "#!/bin/bash\necho \"pkill $*\" >> \"\(r.log.path)\"\n".write(to: pkill, atomically: true, encoding: .utf8)   // never kills
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pkill.path)
        let (code, out) = try run(r, ["--restart-finder"])
        #expect(code != 0 && out.contains("NOT restarted"), "\(out)")
        #expect(!r.calls.contains { $0.hasPrefix("killall") })
        #expect(r.calls.contains("pkill -9 -f ClicksmithFinder.appex/Contents/MacOS/ClicksmithFinder"))
        #expect(r.calls.last == "pluginkit -e use -i dev.clicksmith.app.finder")
    }
}
