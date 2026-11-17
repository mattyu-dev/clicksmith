import Darwin
import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct CLISafetyTests {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    private func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 20) throws -> (Int32, String) {
        let directory = try tempDir("process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = root
        process.standardOutput = output; process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let timedOut = process.isRunning
        if timedOut { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let transcript = try String(contentsOf: log, encoding: .utf8)
        #expect(!timedOut, "Timed out: \(executable.path) \(transcript)")
        return (process.terminationStatus, transcript)
    }

    @Test(arguments: ["0", "1"])
    func checkSummaryIncludesNativeSkipMessages(exitCode: String) throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let swift = directory.appendingPathComponent("swift")
        try Data("""
        #!/bin/sh
        if [ "$1" = build ]; then exit 0; fi
        echo 'SKIP native heic: encoder unavailable'
        echo 'SKIP native avif: encoder timed out'
        echo 'Test run with 3 tests passed.'
        exit "$CLICKSMITH_TEST_EXIT"
        """.utf8).write(to: swift)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        var environment = ProcessInfo.processInfo.environment
        environment["CLICKSMITH_CHECK_LOG"] = nil
        environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["CLICKSMITH_TEST_EXIT"] = exitCode
        let (status, transcript) = try run(URL(fileURLWithPath: "/bin/bash"), [root.appendingPathComponent("scripts/check.sh").path], environment: environment)
        #expect(status == Int32(exitCode))
        #expect(transcript.contains("SKIPPED: 2"))
        #expect(transcript.contains("SKIP native heic: encoder unavailable"))
        #expect(transcript.contains("SKIP native avif: encoder timed out"))
        #expect(transcript.contains("2 skipped"))
        #expect(transcript.contains(exitCode == "0" ? "CHECK PASS:" : "CHECK FAIL:"))
    }

    @Test func actualCLIReportsJournalFailureAndDrainsLargeClipboardProducer() throws {
        let directory = try tempDir(), destination = directory.appendingPathComponent("outputs")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let scratch = ProcessInfo.processInfo.environment["CLICKSMITH_CHECK_SCRATCH_PATH"].map { URL(fileURLWithPath: $0, relativeTo: root) }
            ?? root.appendingPathComponent(".build")
        let debug = scratch.appendingPathComponent("debug")
        let executable = debug.appendingPathComponent("csx")
        var environment = ProcessInfo.processInfo.environment
        let appRoot = directory.appendingPathComponent("root")
        environment["CLICKSMITH_ROOT"] = appRoot.path
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: false)
        try touch(appRoot, "journal", "blocker")
        let (failure, warning) = try run(executable, ["run", "create.newFile", "--dir", destination.path], environment: environment)
        #expect(failure != 0)
        #expect(warning.contains("WARNING:"), "\(warning)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try FileManager.default.removeItem(at: appRoot.appendingPathComponent("journal"))

        // Compile the actual CLI source against this build's Core/Kit objects.
        // Substitute only pbpaste's path, so this test never changes the user's clipboard.
        let producer = directory.appendingPathComponent("clipboard-producer")
        try Data("#!/bin/sh\n/usr/bin/head -c 1048576 /dev/zero\n".utf8).write(to: producer)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: producer.path)
        let original = try String(contentsOf: root.appendingPathComponent("Sources/csx/main.swift"), encoding: .utf8)
        #expect(original.contains("/usr/bin/pbpaste"))
        let source = directory.appendingPathComponent("main.swift")
        try Data(original.replacingOccurrences(of: "/usr/bin/pbpaste", with: producer.path).utf8).write(to: source)
        let fixture = directory.appendingPathComponent("csx-fixture")
        var objects: [String] = []
        for module in ["ClicksmithCore", "ClicksmithKit"] {
            let aggregate = debug.appendingPathComponent("\(module).o")
            if FileManager.default.fileExists(atPath: aggregate.path) { objects.append(aggregate.path) }
            else {
                objects += try FileManager.default.contentsOfDirectory(at: debug.appendingPathComponent("\(module).build"), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "o" }.map(\.path)
            }
        }
        let modules = FileManager.default.fileExists(atPath: debug.appendingPathComponent("Modules").path) ? debug.appendingPathComponent("Modules") : debug
        let (compiled, details) = try run(URL(fileURLWithPath: "/usr/bin/xcrun"),
                                        ["swiftc", "-swift-version", "6", "-I", modules.path, "-module-cache-path", directory.appendingPathComponent("cache").path,
                                         source.path] + objects + ["-o", fixture.path], environment: environment, timeout: 45)
        #expect(compiled == 0, "\(details)")
        guard compiled == 0 else { return }
        let (status, transcript) = try run(fixture, ["run", "create.fromClipboard", "--dir", destination.path], environment: environment)
        #expect(status == 0, "\(transcript)")
        let outputs = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(outputs.count == 1)
        #expect(try Data(contentsOf: #require(outputs.first)).count == 1_048_576)
    }
}
