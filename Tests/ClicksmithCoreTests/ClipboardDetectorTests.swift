import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct ClipboardDetectorTests {
    @Test func jsonObjectIsValidatedAndPreserved() throws {
        let input = #"{"z":2,"account":{"active":true}}"#
        let result = ClipboardDetector.detect(.text(input))
        #expect(result.ext == "json")
        #expect(result.kind == "JSON")
        #expect(result.suggestedName == "z")
        #expect(result.data == Data(input.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        #expect((object["z"] as? Int) == 2)
        #expect((object["account"] as? [String: Bool]) == ["active": true])
    }

    @Test func jsonArrayWinsOverCommaDetection() throws {
        let result = ClipboardDetector.detect(.text("[[1,2],\n[3,4]]"))
        #expect(result.ext == "json")
        #expect(try JSONSerialization.jsonObject(with: result.data) as? [[Int]] == [[1, 2], [3, 4]])
    }

    @Test(arguments: ["true", "null", "42", "5551234567", "\"hello\""])
    func jsonFragmentsStayPlainText(text: String) {
        expectText(text, ext: "txt")
    }

    @Test(arguments: ["{broken}", "[1, nope]", "{\"x\": 1} trailing", "{\"x\": 1,}", "[1,2,]", "{\"x\": 01}", "{\"x\":\"line\nbreak\"}", "[1, /*comment*/ 2]"])
    func invalidJSONStaysText(text: String) {
        expectText(text, ext: "txt")
    }

    @Test func jsonStringContentsDoNotLookLikeTrailingCommas() throws {
        let input = #"{"message":"comma,} and ,] and \"quote\" and \\"}"#
        let result = ClipboardDetector.detect(.text(input))
        #expect(result.ext == "json")
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: String]
        #expect(object?["message"] == "comma,} and ,] and \"quote\" and \\")
    }

    @Test func csvRequiresConsistentRows() {
        expectText("name,score\nAda,10\nGrace,20\n", ext: "csv")
    }

    @Test func tsvPreservesLeadingAndTrailingEmptyFields() {
        expectText("\tname\t\n\tAda\t\n", ext: "tsv")
    }

    @Test func quotedCSVDelimitersAreNotColumns() {
        expectText("name,note\nAda,\"hello, world\"\n", ext: "csv")
    }

    @Test func codeInsideATableCellDoesNotChangeItsFormat() {
        expectText("name,expression\nmap,\"x => x + 1\"\n", ext: "csv")
        expectText("name\texpression\nlog\tconsole.log('hello')\n", ext: "tsv")
    }

    @Test func quotedCSVNewlinesAreNotRows() {
        expectText("name,note\nAda,\"hello\nworld\"\n", ext: "csv")
    }

    @Test func escapedCSVQuotesAreSupported() {
        expectText("name,note\nAda,\"said \"\"hello\"\"\"", ext: "csv")
    }

    @Test func quotedTSVFieldsAreSupported() {
        expectText("name\tnote\nAda\t\"one\ttwo\"", ext: "tsv")
    }

    @Test func windowsCSVIsPreserved() {
        expectText("name,value\r\nexample,1\r\n", ext: "csv")
    }

    @Test func raggedRowsAreNotCSV() {
        expectText("name,value\nexample,1,extra", ext: "txt")
    }

    @Test func singleCommaLineIsNotCSV() {
        expectText("Hello, world", ext: "txt")
    }

    @Test func singleTabLineIsNotTSV() {
        expectText("name\tvalue", ext: "txt")
    }

    @Test(arguments: ["a,b\nc,\"unterminated", "a,b\nc,d\"e", "a,b\nc,\"d\"extra", "a,b\n\nc,d"])
    func malformedTablesStayText(text: String) {
        expectText(text, ext: "txt")
    }

    @Test func urlBecomesAWeblocPropertyList() throws {
        let input = "  https://www.example.com/a?q=1&b=two#part\n"
        let result = ClipboardDetector.detect(.text(input))
        #expect(result.ext == "webloc")
        #expect(result.suggestedName == "www-example-com")
        let plist = try PropertyListSerialization.propertyList(from: result.data, format: nil)
        #expect(plist as? [String: String] == ["URL": input.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    @Test(arguments: ["ftp://example.com/file", "file:///tmp/example.txt", "mailto:hello@example.com", "clicksmith://run/123"])
    func absoluteURLSchemesMakeWeblocs(text: String) {
        #expect(ClipboardDetector.detect(.text(text)).ext == "webloc")
    }

    @Test(arguments: ["example.com", "https://", "https:///missing-host", "https://example.com two words", "Note: this is prose."])
    func proseAndIncompleteURLsStayText(text: String) {
        expectText(text, ext: "txt")
    }

    @Test func explicitHTMLPreservesBytes() {
        let text = "<h1>Hello <em>world</em>!</h1>\r\n<p>é</p>"
        let result = ClipboardDetector.detect(.html(text))
        #expect(result.ext == "html")
        #expect(result.data == Data(text.utf8))
        #expect(result.suggestedName == "hello-world")
    }

    @Test func explicitHTMLDoesNotNeedToLookLikeMarkup() {
        let result = ClipboardDetector.detect(.html("plain HTML pasteboard representation"))
        #expect(result.ext == "html")
    }

    @Test func htmlMarkupInTextIsDetected() {
        expectText("<!doctype html>\n<html><body><h1>Title</h1></body></html>", ext: "html")
        expectText("<div><p>Hello</p></div>", ext: "html")
    }

    @Test func comparisonsAreNotHTML() {
        expectText("a < b and c > d", ext: "txt")
    }

    @Test func markdownHeadingSuppliesASlug() {
        let text = "Intro\n\n## My first heading! ##\n\n# Later heading\n"
        let result = ClipboardDetector.detect(.text(text))
        #expect(result.ext == "md")
        #expect(result.data == Data(text.utf8))
        #expect(result.suggestedName == "my-first-heading")
    }

    @Test func setextMarkdownHeadingSuppliesAName() {
        let result = ClipboardDetector.detect(.text("A title\n=======\n\nBody"))
        #expect(result.ext == "md")
        #expect(result.suggestedName == "a-title")
    }

    @Test func windowsMarkdownHeadingIsDetected() {
        let result = ClipboardDetector.detect(.text("# Windows heading\r\n\r\nBody\r\n"))
        #expect(result.ext == "md")
        #expect(result.suggestedName == "windows-heading")
    }

    @Test(arguments: ["- one\n- two", "1. one\n2. two", "[Example](https://example.com)", "**bold text**", "> A quotation", "```swift\nlet x = 1\n```", "```swift\nfunc greet() {}\n```", "~~~python\nprint('hello')\n~~~"])
    func markdownHeuristicsPreserveContent(text: String) {
        expectText(text, ext: "md")
    }

    @Test func swiftSourceIsDetected() {
        expectText("import Foundation\n\nlet message = \"hello\"\nprint(message)\n", ext: "swift")
        expectText("public struct Point { let x: Int }", ext: "swift")
        expectText("func greet() { print(\"hello\") }", ext: "swift")
    }

    @Test func pythonSourceIsDetected() {
        expectText("def greet(name):\n    return f'Hello {name}'\n", ext: "py")
        expectText("import json\nprint(json.dumps({}))\n", ext: "py")
        expectText("#!/usr/bin/env python3\nprint('hello')\n", ext: "py")
    }

    @Test func javascriptSourceIsDetected() {
        expectText("const greet = (name) => `Hello ${name}`;\n", ext: "js")
        expectText("function greet(name) { return name; }", ext: "js")
        expectText("import thing from 'thing';\nconsole.log(thing);", ext: "js")
    }

    @Test func typescriptWinsOverJavascript() {
        expectText("interface Person { name: string; }\n", ext: "ts")
        expectText("const answer: number = 42;\n", ext: "ts")
        expectText("type User = { name: string };", ext: "ts")
        expectText("const greet = (name: string): string => name;", ext: "ts")
    }

    @Test func shellSourceIsDetected() {
        expectText("#!/bin/sh\nset -eu\necho \"hello\"\n", ext: "sh")
        expectText("#!/usr/bin/env bash\nprintf '%s\\n' hello\n", ext: "sh")
        expectText("#!/usr/bin/env -S zsh -e\necho hello\n", ext: "sh")
    }

    @Test func sqlSourceIsDetectedBeforeCSV() {
        expectText("SELECT id, name\nFROM users, teams\nWHERE users.team_id = teams.id;", ext: "sql")
        expectText("-- query\nselect * from users;", ext: "sql")
    }

    @Test func yamlNeedsMappingEvidence() {
        expectText("name: Clicksmith\nversion: 1\nenabled: true\n", ext: "yaml")
        expectText("server:\n  port: 8080\n  enabled: true\n", ext: "yaml")
        expectText("---\ntitle: Some words\n", ext: "yaml")
    }

    @Test func aProseColonIsNotYAML() {
        expectText("Note: this is just a sentence.", ext: "txt")
        expectText("Note: this is a sentence.\nReminder: this is another sentence.", ext: "txt")
    }

    @Test func ordinaryMultilineProseStaysText() {
        expectText("The plan is ready.\nWe can start tomorrow.\n", ext: "txt")
    }

    @Test func pngRepresentationIsPreserved() {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0xff])
        let result = ClipboardDetector.detect(.image(png))
        #expect(result.ext == "png")
        #expect(result.data == png)
        #expect(result.kind == "PNG image")
    }

    @Test func rtfRepresentationIsPreserved() {
        let rtf = Data(#"{\rtf1\ansi Hello \b world\b0}"#.utf8)
        let result = ClipboardDetector.detect(.rtf(rtf))
        #expect(result.ext == "rtf")
        #expect(result.data == rtf)
    }

    @Test func fileURLsAreListedWithoutReadingFiles() throws {
        let urls = [URL(fileURLWithPath: "/not-a-real-folder/A file.txt"), try #require(URL(string: "https://example.com/a"))]
        let result = ClipboardDetector.detect(.fileURLs(urls))
        #expect(result.ext == "txt")
        #expect(result.kind == "File URLs")
        #expect(String(decoding: result.data, as: UTF8.self) == "file:///not-a-real-folder/A%20file.txt\nhttps://example.com/a")
    }

    @Test func emptyFileURLListHasEmptyText() {
        let result = ClipboardDetector.detect(.fileURLs([]))
        #expect(result.ext == "txt")
        #expect(result.data.isEmpty)
    }

    @Test func emptyTextGetsATimestampName() {
        let result = ClipboardDetector.detect(.text(""))
        #expect(result.ext == "txt")
        #expect(result.data.isEmpty)
        #expect(result.suggestedName.range(of: "^Clipboard [0-9]{4}-[0-9]{2}-[0-9]{2} at [0-9]{2}\\.[0-9]{2}$", options: .regularExpression) != nil)
    }

    @Test func unsafeHeadingBecomesASafeShortFilename() {
        let result = ClipboardDetector.detect(.text("# ../../\\Unsafe: \"title\" *? | " + String(repeating: "long ", count: 30)))
        #expect(result.suggestedName.hasPrefix("unsafe-title-long"))
        #expect(result.suggestedName.count <= 40)
        #expect(!result.suggestedName.hasSuffix("-"))
        #expect(result.suggestedName.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")) == nil)
    }

    @Test func slugKeepsUnicodeLettersAndFoldsAccents() {
        let result = ClipboardDetector.detect(.text("# Été à 東京"))
        #expect(result.suggestedName == "ete-a-東京")
    }

    @Test func unusableTitleFallsBackToTimestamp() {
        let result = ClipboardDetector.detect(.text("# !!! 🎉 ///"))
        #expect(result.suggestedName.hasPrefix("Clipboard "))
        #expect(result.suggestedName.count <= 40)
    }

    @Test func jsonKeysCannotEscapeTheOutputDirectory() {
        let result = ClipboardDetector.detect(.text(#"{"../../escape/name":1}"#))
        #expect(result.suggestedName == "escape-name")
    }

    @Test func detectionCanRunConcurrently() async {
        let extensions = await withTaskGroup(of: String.self) { group in
            for _ in 0..<16 {
                group.addTask { ClipboardDetector.detect(.text("# Concurrent heading")).ext }
            }
            var results: [String] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(extensions.count == 16)
        #expect(extensions.allSatisfy { $0 == "md" })
    }

    private func expectText(_ text: String, ext: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = ClipboardDetector.detect(.text(text))
        #expect(result.ext == ext, "Detected \(result.kind) for \(text)", sourceLocation: sourceLocation)
        #expect(result.data == Data(text.utf8), sourceLocation: sourceLocation)
    }
}
