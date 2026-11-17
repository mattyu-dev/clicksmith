import CoreGraphics
import Darwin
import Foundation
import PDFKit
import Testing
@testable import ClicksmithCore

@Suite struct CoreSafetyUndoTests {
    @Test(arguments: [false, true])
    func changedTrashKeepsBothCopies(replaced: Bool) throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let original = directory.appendingPathComponent("original")
        let trash = try touch(directory, "fake-trash", "original")
        let copy = try touch(directory, "destination", "original")
        let group = UUID()
        let transaction = JournalTransaction(actionID: "move", title: "Move", entries: [
            .init(kind: .created, to: copy.path, fingerprint: .of(copy), group: group),
            .init(kind: .trashed, from: original.path, to: trash.path, fingerprint: .of(trash), group: group)
        ])
        let journal = UndoJournal(directory: storage)
        try journal.save(transaction)
        if replaced {
            let date = try FileManager.default.attributesOfItem(atPath: trash.path)[.modificationDate]
            let replacement = try touch(directory, "replacement", "new data")
            if let date { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: replacement.path) }
            _ = try FileManager.default.replaceItemAt(trash, withItemAt: replacement)
        } else { try Data("changed by user".utf8).write(to: trash) }
        let report = journal.undo(transaction)
        #expect(report.reverted.isEmpty)
        #expect(!FileOps.entryExists(original))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "original")
        #expect(try String(contentsOf: trash, encoding: .utf8) == (replaced ? "new data" : "changed by user"))
        #expect(journal.last?.entries.count == 2, "Keep the pair retryable, including the destination copy")
    }

    @Test func unchangedTrashRestoresNormally() throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let original = directory.appendingPathComponent("original")
        let trash = try touch(directory, "fake-trash", "original")
        let tx = JournalTransaction(actionID: "trash", title: "Trash", entries: [
            .init(kind: .trashed, from: original.path, to: trash.path, fingerprint: .of(trash))
        ])
        let journal = UndoJournal(directory: storage)
        try journal.save(tx)
        #expect(journal.undo(tx).skipped.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(journal.list().isEmpty)
    }

    @Test(arguments: [String(repeating: "a", count: 255), "a." + String(repeating: "x", count: 253),
                      String(repeating: "界", count: 85), "." + String(repeating: "a", count: 254)])
    func undoAcceptsMaximumLengthNames(name: String) throws {
        let directory = try tempDir(), storage = try tempDir("journal")
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: storage) }
        let original = try touch(directory, "original.txt", "preserved")
        let ops = FileOps(), journal = UndoJournal(directory: storage)
        let renamed = try ops.rename(original, to: name)
        let temporary = FileOps.temporaryName(for: renamed)
        #expect(temporary.utf8.count <= 255)
        #expect(!temporary.hasPrefix("."))
        let tx = try #require(try ops.commit(to: journal, actionID: "rename", title: "Rename"))
        #expect(journal.undo(tx).skipped.isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "preserved")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["original.txt"])
    }
}

@Suite struct CoreSafetyDocumentTests {
    @Test(arguments: [false, true])
    func rollbackKeepsChangedPublishedOutput(replaced: Bool) throws {
        let directory = try tempDir(), output = directory.appendingPathComponent("outputs")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let first = output.appendingPathComponent("first")
        #expect(throws: PowerError.self) {
            try DocumentIO.batch(output, isCancelled: {
                guard FileOps.entryExists(first) else { return false }
                try? Data("user work".utf8).write(to: first, options: replaced ? .atomic : [])
                return true
            }) { stage in
                [try touch(stage, "first", "encoded"), try touch(stage, "second", "encoded")]
            }
        }
        #expect(try String(contentsOf: first, encoding: .utf8) == "user work")
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["first"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["outputs"])
    }

    @Test func rollbackRemovesOnlyUnchangedOutputs() throws {
        let directory = try tempDir(), output = directory.appendingPathComponent("outputs")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        #expect(throws: PowerError.self) {
            try DocumentIO.batch(output, isCancelled: { FileOps.entryExists(output.appendingPathComponent("first")) }) { stage in
                [try touch(stage, "first"), try touch(stage, "second")]
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }
}

@Suite struct CoreSafetyRasterTests {
    @Test(arguments: [0, 90, 180, 270])
    func pdfPixelsFillRotatedCropAtRequestedResolution(rotation: Int) throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("page.pdf")
        var box = CGRect(x: 10, y: 20, width: 240, height: 160)
        let context = try #require(CGContext(file as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(box)
        context.endPDFPage(); context.closePDF()
        let document = try #require(PDFDocument(url: file))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 30, y: 40, width: 120, height: 60), for: .cropBox)
        page.rotation = rotation
        let ref = try #require(page.pageRef)
        let image = try ImageEngine.pdfImage(ref, maxPixelSize: 600)
        let vision = try VisionIO.render(page, dpi: 216)
        let natural = try ImageEngine.pdfImage(ref, maxPixelSize: nil)
        let rotated = rotation == 90 || rotation == 270
        #expect(image.width == (rotated ? 300 : 600) && image.height == (rotated ? 600 : 300))
        #expect(vision.width == (rotated ? 180 : 360) && vision.height == (rotated ? 360 : 180))
        #expect(natural.width == (rotated ? 167 : 334) && natural.height == (rotated ? 334 : 167))
        for raster in [image, vision, natural] {
            let pixels = try #require(CGContext(data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8,
                                               bytesPerRow: raster.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            pixels.draw(raster, in: CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
            let bytes = try #require(pixels.data).assumingMemoryBound(to: UInt8.self)
            var red = 0
            for pixel in 0..<(raster.width * raster.height) {
                if bytes[pixel * 4] > 240 && bytes[pixel * 4 + 1] < 15 && bytes[pixel * 4 + 2] < 15 { red += 1 }
            }
            #expect(Double(red) / Double(raster.width * raster.height) > 0.99, "The drawn page must fill the bitmap, including at more than 72 DPI")
        }
    }

    @Test func imagePublicationMovesCompleteFileAndPreservesRacingDestination() throws {
        let directory = try tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.png")
        let scratch = try touch(directory, "scratch", "complete")
        try ImageEngine.publish(scratch, to: output)
        #expect(!FileOps.entryExists(scratch), "Publication is a rename, with no hard-link requirement")
        #expect(try String(contentsOf: output, encoding: .utf8) == "complete")
        let race = directory.appendingPathComponent("race.png")
        #expect(throws: ImageEngineError.self) {
            try ImageEngine.produce(output: race, format: .png) { scratch in
                try Data("encoded".utf8).write(to: scratch)
                try Data("user file".utf8).write(to: race)
            }
        }
        #expect(try String(contentsOf: race, encoding: .utf8) == "user file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["output.png", "race.png"])
    }
}
