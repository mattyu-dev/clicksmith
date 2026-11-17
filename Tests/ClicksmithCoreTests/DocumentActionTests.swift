import Foundation
import Testing
import PDFKit
@testable import ClicksmithCore

@Suite(.serialized) struct DocumentActionTests {
    func markdown(_ d: URL) throws -> URL { try touch(d, "notes.md", "# Title\n\nHello **world**.\n\n- one\n- two\n") }

    func pdf(_ d: URL, pages: Int = 1) async throws -> URL {
        let md = try touch(d, "src.md", (1...pages).map { "# Page \($0)\n\n" + String(repeating: "Text. ", count: 600) }.joined(separator: "\n\n"))
        var c = context([md]); c.options = ["to": "pdf"]
        return try #require(try await ConvertDocumentAction().run(c).created.first)
    }

    @Test func markdownToWordAndPDF() async throws {
        let d = try tempDir(); let md = try markdown(d)
        for to in ["docx", "pdf", "html", "txt"] {
            var c = context([md]); c.options = ["to": to]
            let out = try #require(try await ConvertDocumentAction().run(c).created.first)
            #expect(out.lastPathComponent == "notes.\(to)")
        }
        let txt = try String(contentsOf: d.appendingPathComponent("notes.txt"), encoding: .utf8)
        #expect(txt.contains("Hello") && txt.contains("world"))
        #expect(PDFDocument(url: d.appendingPathComponent("notes.pdf"))?.string?.contains("Hello") == true)
    }

    @Test func menuOffersOnlyValidTargets() {
        #expect(!DocExts.inputs(for: .pdf).contains("pdf"))
        #expect(DocExts.inputs(for: .txt).contains("pdf"))
        #expect(!DocExts.inputs(for: .docx).contains("docx"))
    }

    @Test func pdfToImagesMakesAFolderAndUndoRemovesIt() async throws {
        let d = try tempDir(); let p = try await pdf(d, pages: 2)
        let j = UndoJournal(directory: try tempDir("j")); let ops = FileOps()
        var c = context([p], ops: ops); c.options = ["format": "png"]
        let folder = try #require(try await PDFToImagesAction().run(c).created.first)
        let pages = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }
        #expect(pages.count == (PDFDocument(url: p)?.pageCount ?? -1))
        let tx = try #require(try ops.commit(to: j, actionID: "pdf.toImages", title: "x"))
        _ = j.undo(tx)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func splitMergeCompressImages() async throws {
        let d = try tempDir(); let p = try await pdf(d, pages: 3)
        let n = PDFDocument(url: p)?.pageCount ?? 0
        let folder = try #require(try await SplitPDFAction().run(context([p])).created.first)
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "pdf" }
        #expect(parts.count == n)
        let merged = try #require(try await MergePDFsAction().run(context(parts)).created.first)
        #expect(merged.lastPathComponent == "Merged.pdf" && PDFDocument(url: merged)?.pageCount == n)
        var c = context([p]); c.options = ["quality": "medium"]
        let r = try await CompressPDFAction().run(c)
        #expect(r.created.first?.lastPathComponent == "src compressed.pdf" && r.message?.contains("→") == true)
        let img = try ImageActionTests().photo(d)
        var ic = context([img]); ic.options = ["page": "a4"]
        let made = try #require(try await ImagesToPDFAction().run(ic).created.first)
        #expect(PDFDocument(url: made)?.pageCount == 1)
    }
}

/// Codex review of T-0014 (2026-11-16).
@Suite(.serialized) struct DocumentReviewFixTests {
    @Test("#2 cancelling Compress PDF keeps the PDFs already made") func cancelKeeps() async throws {
        let d = try tempDir()
        let a = try await DocumentActionTests().pdf(d)
        let b = d.appendingPathComponent("b.pdf"); try FileManager.default.copyItem(at: a, to: b)
        let first = d.appendingPathComponent("src compressed.pdf").path
        // Cancel as soon as the first output exists.
        var c = context([a, b], cancel: { FileManager.default.fileExists(atPath: first) }); c.options = ["quality": "medium"]
        let r = try await CompressPDFAction().run(c)
        #expect(r.cancelled && r.created.count == 1)
    }

    @Test("#4 .htm and .text inputs convert") func aliases() async throws {
        let d = try tempDir()
        let htm = try touch(d, "page.htm", "<h1>Hi</h1><p>there</p>")
        let text = try touch(d, "note.text", "plain words")
        for (f, to) in [(htm, "txt"), (text, "html")] {
            var c = context([f]); c.options = ["to": to]
            #expect(try await ConvertDocumentAction().run(c).created.count == 1)
        }
    }

    @Test("#5 a vCard name with a slash makes a safe file name") func vcardName() async throws {
        let d = try tempDir()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: "BEGIN:VCARD\nVERSION:3.0\nFN:Sales/Support\nEND:VCARD")
        var c = context([], env: env); c.targetDirectory = d
        let out = try #require(try await MakeQRFromClipboardAction().run(c).created.first)
        #expect(out.deletingLastPathComponent().standardizedFileURL == d.standardizedFileURL)
        #expect(!out.lastPathComponent.contains("/"))
    }
}

@Test("QR names stay under the file name byte limit") func qrNameBytes() async throws {
    let d = try tempDir()
    let fam = String(repeating: "👨‍👩‍👧‍👦", count: 40)
    let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: "BEGIN:VCARD\nVERSION:3.0\nFN:\(fam)\nEND:VCARD")
    var c = context([], env: env); c.targetDirectory = d
    let out = try #require(try await MakeQRFromClipboardAction().run(c).created.first)
    #expect(out.lastPathComponent.utf8.count <= 255)
    #expect(MakeQRFromClipboardAction.fit(fam, bytes: 120).utf8.count <= 120)
}
