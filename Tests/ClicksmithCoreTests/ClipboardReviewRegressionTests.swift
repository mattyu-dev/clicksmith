import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct ClipboardReviewRegressionTests {
    // Review 2: serializing parsed numbers or dictionaries would corrupt these bytes.
    @Test(arguments: [
        #"{"price":19.99,"quantity":1.0}"#,
        #"{"z":1,"a":2,"z":3}"#,
        " \r\n[1.0, 19.99, 1e+09, -0.0]\t\n",
        #"{"escaped":"\u00e9\/path","large":12345678901234567890}"#,
    ])
    func review02JSONBytesAreUnchanged(_ input: String) {
        expect(input, ext: "json")
    }

    // Review 3: identifiers, phone numbers and scalar text are ordinary clipboard text.
    @Test(arguments: ["42", "5551234567", "\"hello\"", "true", "null"])
    func review03JSONScalarsStayText(_ input: String) {
        expect(input, ext: "txt")
    }

    // Review 4: a delimiter on two prose lines is insufficient CSV evidence.
    @Test(arguments: ["Hi John,\nThanks, Alex", "I like apples, pears\nand also grapes, figs"])
    func review04CommaProseStaysText(_ input: String) {
        expect(input, ext: "txt")
    }

    @Test func review04RealSmallAndLargerTablesRemainCSV() {
        expect("name,amount\nAlex,19.99", ext: "csv")
        expect("first,last\nAlex,Smith", ext: "csv")
        expect("one phrase,second phrase\nanother phrase,more words\nlast phrase,final words", ext: "csv")
        expect("one phrase,two words,three words\nfour words,five words,six words", ext: "csv")
    }

    // Review 5: SELECT and FROM in a sentence must not override plain text.
    @Test func review05SQLRequiresStructure() {
        expect("Select all the photos from the trip and send them to me.", ext: "txt")
        expect("select id from photos;", ext: "sql")
        expect("select id from photos where active = true", ext: "sql")
        expect("SELECT id FROM photos", ext: "sql")
    }

    // Review 6: HTML fragments inside README files and JSX do not determine the format.
    @Test func review06ReadmeAndJSXKeepTheirFormats() {
        expect("<p align=\"center\"><img src=\"logo.png\"></p>\n\n# Clicksmith\n\nWelcome.", ext: "md")
        expect("<p>Intro</p>\n- first item\n- second item", ext: "md")
        expect("const App = () => <div>Hello</div>;", ext: "js")
        expect("const App: string = '<div>Hello</div>';", ext: "ts")
        expect("<div>Hello</div>", ext: "html")
    }

    // Review 7: an arrow in prose is not a JavaScript function.
    @Test func review07ProseArrowsStayText() {
        expect("Revenue => up 10%", ext: "txt")
        expect("x => x + 1", ext: "js")
        expect("(name) => { return name; }", ext: "js")
    }

    // Review 8: a class declaration needs naming or indentation evidence.
    @Test func review08ClassScheduleStaysText() {
        expect("class schedule: Monday", ext: "txt")
        expect("class Person:\n    pass", ext: "py")
        expect("class person:\n    pass", ext: "py")
    }

    // Review 9: numeric contact values alone are not YAML-specific signals.
    @Test func review09ContactCardsStayText() {
        expect("Name: Alex\nPhone: 5551234", ext: "txt")
        expect("Name: Alex\nPhone: 5551234\nCity: Paris", ext: "txt")
        expect("name: Clicksmith\nversion: 1", ext: "txt")
        expect("---\nname: Clicksmith\nversion: 1", ext: "yaml")
        expect("name: Clicksmith\nenabled: true", ext: "yaml")
    }

    // Review 10: copied terminal commands may include the prompt.
    @Test func review10TerminalPromptsAreShell() {
        expect("$ brew install ripgrep", ext: "sh")
        expect("$ brew update\n$ brew upgrade", ext: "sh")
    }

    // Review 11: HTML's title supplies a useful name when there is no heading.
    @Test func review11HTMLTitleNamesTheFile() {
        let html = "<!doctype html><html><head><title>Clicksmith guide</title></head><body><p>Hello</p></body></html>"
        for content in [ClipboardContent.text(html), .html(html)] {
            let result = ClipboardDetector.detect(content)
            #expect(result.ext == "html")
            #expect(result.suggestedName == "clicksmith-guide")
            #expect(result.data == Data(html.utf8))
        }
        let heading = ClipboardDetector.detect(.html("<title>Title</title><h1>Heading</h1>"))
        #expect(heading.suggestedName == "heading")
    }

    private func expect(_ input: String, ext: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = ClipboardDetector.detect(.text(input))
        #expect(result.ext == ext, "Detected \(result.kind) for \(input)", sourceLocation: sourceLocation)
        #expect(result.data == Data(input.utf8), sourceLocation: sourceLocation)
    }
}
