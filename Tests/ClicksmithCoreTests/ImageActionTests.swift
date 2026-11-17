import Foundation
import Testing
import ImageIO
@testable import ClicksmithCore

@Suite(.serialized) struct ImageActionTests {
    /// A real JPEG with GPS, made by ImageIO.
    func photo(_ d: URL) throws -> URL {
        let url = d.appendingPathComponent("photo.jpg")
        let ctx = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
            [kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 48.85, kCGImagePropertyGPSLatitudeRef as String: "N"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func convertToPNG() async throws {
        let d = try tempDir(); let p = try photo(d)
        var c = context([p]); c.options = ["format": "png"]
        let out = try #require(try await ConvertImageAction().run(c).created.first)
        #expect(out.lastPathComponent == "photo.png")
        #expect(try ImageEngine.info(out).pixelWidth == 400)
    }

    @Test func sameFormatGetsSuffix() async throws {
        let d = try tempDir(); let p = try photo(d)
        var c = context([p]); c.options = ["format": "jpeg"]
        let out = try #require(try await ConvertImageAction().run(c).created.first)
        #expect(out.lastPathComponent == "photo converted.jpg")
    }

    @Test func resizeKeepsFormatAndShrinks() async throws {
        let d = try tempDir(); let p = try photo(d)
        var c = context([p]); c.options = ["px": "200"]
        let out = try #require(try await ResizeImageAction().run(c).created.first)
        #expect(out.pathExtension == "jpg")
        let i = try ImageEngine.info(out)
        #expect(max(i.pixelWidth, i.pixelHeight) == 200)
    }

    @Test func iconAndStrip() async throws {
        let d = try tempDir(); let p = try photo(d)
        var c = context([p]); c.options = ["format": "icns"]
        #expect(try await MakeIconAction().run(c).created.first?.pathExtension == "icns")
        let clean = try #require(try await StripMetadataAction().run(context([p])).created.first)
        let props = CGImageSourceCopyPropertiesAtIndex(try #require(CGImageSourceCreateWithURL(clean as CFURL, nil)), 0, nil) as? [String: Any]
        #expect(props?[kCGImagePropertyGPSDictionary as String] == nil)
        #expect(try Data(contentsOf: p).count > 0, "original untouched")
    }

    @Test func badOptionsAreRefused() async throws {
        let d = try tempDir(); let p = try photo(d)
        for (a, o) in [(ResizeImageAction() as any PowerAction, ["px": "999999"]), (ConvertImageAction(), ["format": "nope"])] {
            var c = context([p]); c.options = o
            let r = try await a.run(c)
            #expect(r.created.isEmpty && !r.failures.isEmpty)
        }
    }
}

@Suite struct ImageWiringReviewTests {
    @Test("#2 a PNG named .jpg is resized as PNG with a .png name") func realFormat() async throws {
        let d = try tempDir()
        let src = try await { () async throws -> URL in
            let f = try ImageActionTests().photo(d)
            var c = context([f]); c.options = ["format": "png"]
            return try #require(try await ConvertImageAction().run(c).created.first)
        }()
        let lying = d.appendingPathComponent("fake.jpg")
        try FileManager.default.moveItem(at: src, to: lying)
        #expect(ImageExts.format(of: lying) == .png)
        var c = context([lying]); c.options = ["px": "100"]
        let out = try #require(try await ResizeImageAction().run(c).created.first)
        #expect(out.pathExtension == "png")
    }

    @Test("#3 resize / strip are offered only for formats we can write") func writableOnly() {
        #expect(ImageExts.sameFormatWritable.contains("jpg") && ImageExts.sameFormatWritable.contains("png"))
        #expect(!ImageExts.sameFormatWritable.contains("psd") && !ImageExts.sameFormatWritable.contains("cr2"))
        #expect(ResizeImageAction().descriptor.extensions == ImageExts.sameFormatWritable)
    }
}

/// End-to-end test findings (2026-11-16).
@Suite struct E2EFixTests {
    @Test("PDFs are not offered to image resize / strip / convert") func noPDF() {
        #expect(!ResizeImageAction().descriptor.extensions.contains("pdf"))
        #expect(!StripMetadataAction().descriptor.extensions.contains("pdf"))
        #expect(!ConvertImageAction().descriptor.extensions.contains("pdf"))
    }

    @Test("resize refuses to 'shrink' an image that is already small") func noUpscale() async throws {
        let d = try tempDir(); let p = try ImageActionTests().photo(d)   // 400×300
        var c = context([p]); c.options = ["px": "1920"]
        let r = try await ResizeImageAction().run(c)
        #expect(r.created.isEmpty && r.failures.first?.message.contains("already") == true)
    }

    @Test("Wi-Fi QR file name never holds the password") func wifiName() async throws {
        let d = try tempDir()
        let env = FakeEnvironment(); env.clipboardIn = ClipboardSnapshot(string: "WIFI:T:WPA;S:Home;P:hunter2pass;;")
        var c = context([], env: env); c.targetDirectory = d
        let out = try #require(try await MakeQRFromClipboardAction().run(c).created.first)
        #expect(out.lastPathComponent == "QR Wi-Fi Home.png")
    }

    @Test("user messages hide technical detail") func cleanMessages() {
        #expect(PowerError.failed("The image could not be read.", detail: "invalidInput(file:///x)").localizedDescription == "The image could not be read.")
    }
}
