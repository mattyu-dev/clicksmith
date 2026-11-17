import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct TemplateLibraryTests {
    @Test func libraryIncludesRequiredTemplatesAndUniqueIDs() {
        let templates = TemplateLibrary.builtIn
        let required: Set<String> = [
            "text", "markdown", "rtf", "html", "css", "javascript", "typescript", "python", "swift", "shell",
            "json", "yaml", "csv", "xml", "svg", "docx", "gitignore", "readme", "makefile", "env",
        ]
        #expect(templates.count >= 20)
        #expect(Set(templates.map(\.id)).count == templates.count)
        #expect(required.isSubset(of: Set(templates.map(\.id))))
        #expect(templates.allSatisfy { !$0.name.isEmpty && !$0.symbol.isEmpty })
        #expect(templates.allSatisfy { !$0.name.contains("/") && !$0.ext.contains(".") })
    }

    @Test func templatesRoundTripThroughCodable() throws {
        let encoded = try JSONEncoder().encode(TemplateLibrary.builtIn)
        let decoded = try JSONDecoder().decode([FileTemplate].self, from: encoded)
        #expect(decoded.count == TemplateLibrary.builtIn.count)
        for (original, copy) in zip(TemplateLibrary.builtIn, decoded) {
            #expect(copy.id == original.id)
            #expect(copy.name == original.name)
            #expect(copy.ext == original.ext)
            #expect(copy.contents == original.contents)
            #expect(copy.symbol == original.symbol)
            #expect(copy.isExecutable == original.isExecutable)
        }
    }

    @Test func specialFilenamesDoNotAcquireExtensions() throws {
        #expect(try template("gitignore").name == ".gitignore")
        #expect(try template("env").name == ".env")
        #expect(try template("makefile").name == "Makefile")
        for id in ["gitignore", "env", "makefile"] { #expect(try template(id).ext.isEmpty) }
        #expect(try template("readme").name == "README")
        #expect(try template("readme").ext == "md")
    }

    @Test func shellTemplateRequestsExecutablePermissionAndHasValidSyntax() throws {
        let shell = try template("shell")
        #expect(shell.isExecutable)
        #expect(TemplateLibrary.builtIn.filter(\.isExecutable).map(\.id) == ["shell"])
        #expect(String(decoding: shell.contents, as: UTF8.self).hasPrefix("#!/bin/sh\n"))
        try withTemporaryFile(shell) { url in
            let result = try run("/bin/sh", ["-n", url.path])
            #expect(result.status == 0, Comment(rawValue: result.output))
        }
    }

    @Test func jsonTemplateContainsValidJSON() throws {
        let json = try template("json")
        #expect(try JSONSerialization.jsonObject(with: json.contents) as? [String: String] == [:])
    }

    @Test func docxIsAValidEmptyWordDocument() throws {
        try withTemporaryFile(template("docx")) { url in
            let zip = try run("/usr/bin/unzip", ["-t", url.path])
            #expect(zip.status == 0, Comment(rawValue: zip.output))
            #expect(zip.output.contains("word/document.xml"))
            let info = try run("/usr/bin/textutil", ["-info", url.path])
            #expect(info.status == 0, Comment(rawValue: info.output))
            #expect(info.output.contains("Type:"), Comment(rawValue: info.output))
            let text = try run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
            #expect(text.status == 0, Comment(rawValue: text.output))
            #expect(text.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func rtfTemplateIsReadableByTextutil() throws {
        try withTemporaryFile(template("rtf")) { url in
            let result = try run("/usr/bin/textutil", ["-info", url.path])
            #expect(result.status == 0, Comment(rawValue: result.output))
        }
    }

    @Test func fileTemplatePublicInitializerPreservesSuppliedMetadata() throws {
        let custom = FileTemplate(id: "custom", name: "Custom", ext: "txt", contents: Data("é".utf8), symbol: "doc")
        let copy = try JSONDecoder().decode(FileTemplate.self, from: JSONEncoder().encode(custom))
        #expect(copy.id == "custom")
        #expect(copy.contents == Data("é".utf8))
        #expect(!copy.isExecutable)
    }

    private func template(_ id: String) throws -> FileTemplate {
        try #require(TemplateLibrary.builtIn.first { $0.id == id })
    }

    private func withTemporaryFile(_ template: FileTemplate, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clicksmith-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(template.name).appendingPathExtension(template.ext)
        try template.contents.write(to: url)
        try body(url)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
