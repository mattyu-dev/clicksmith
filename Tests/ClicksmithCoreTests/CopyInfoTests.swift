import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ClicksmithCore

/// T-0016 item 5: Copy Info shows pixel size, page count and duration.
@Suite struct CopyInfoTests {
    func png(_ dir: URL, width: Int, height: Int) throws -> URL {
        let url = dir.appendingPathComponent("pic.png")
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    func pdf(_ dir: URL, pages: Int) throws -> URL {
        let url = dir.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 72, height: 72)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { ctx.beginPDFPage(nil); ctx.endPDFPage() }
        ctx.closePDF()
        return url
    }

    @Test func imageHasDimensions() async throws {
        let f = try png(try tempDir(), width: 37, height: 21)
        let env = FakeEnvironment()
        _ = try await CopyInfoAction().run(context([f], env: env))
        let text = try #require(env.clipboard)
        #expect(text.contains("Name: pic.png"))
        #expect(text.contains("Dimensions: 37 × 21"))
    }

    @Test func pdfHasPageCount() async throws {
        let f = try pdf(try tempDir(), pages: 3)
        #expect(await FileInfo.describe(f).contains("Pages: 3"))
    }

    @Test func audioHasDuration() async throws {
        let f = try MediaFixture.makeAudio(in: try tempDir())   // 2 s tone
        let text = await FileInfo.describe(f)
        #expect(text.contains("Duration: 0:02"))
        #expect(!text.contains("Dimensions"))
    }

    @Test func plainFilesAndFoldersHaveNoExtraLines() async throws {
        let d = try tempDir(); let t = try touch(d, "a.txt", "hi")
        let text = await FileInfo.describe(t)
        #expect(!text.contains("Dimensions") && !text.contains("Pages") && !text.contains("Duration"))
        #expect(await !FileInfo.describe(d).contains("Dimensions"))
        // A broken image does not crash or lie.
        let fake = try touch(d, "fake.png", "not png")
        #expect(await !FileInfo.describe(fake).contains("Dimensions"))
    }

    @Test func durationFormat() {
        #expect(FileInfo.formatDuration(2.4) == "0:02")
        #expect(FileInfo.formatDuration(125) == "2:05")
        #expect(FileInfo.formatDuration(3_725) == "1:02:05")
    }
}
