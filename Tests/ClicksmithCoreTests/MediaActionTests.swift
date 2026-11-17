import Foundation
import Testing
@testable import ClicksmithCore

@Suite(.serialized) struct MediaActionTests {
    @Test func convertVideoWritesMP4NextToSource() async throws {
        let f = try await MediaFixture.make()
        var c = context([f.video]); c.options = ["preset": VideoPreset.h264_720.rawValue]
        let r = try await ConvertVideoAction().run(c)
        let out = try #require(r.created.first)
        #expect(out.pathExtension == "mp4" && out.deletingLastPathComponent() == f.video.deletingLastPathComponent())
        #expect(try await MediaEngine.info(out).hasVideo)
        #expect(c.files.recorded.count == 1)
    }

    @Test func extractAudioFromVideo() async throws {
        let f = try await MediaFixture.make()
        var c = context([f.video]); c.options = ["format": AudioFormat.aac.rawValue]
        let out = try #require(try await ConvertAudioAction().run(c).created.first)
        let info = try await MediaEngine.info(out)
        #expect(out.pathExtension == "m4a" && info.hasAudio && !info.hasVideo)
    }

    @Test func compressAndGIF() async throws {
        let f = try await MediaFixture.make()
        // The fixture is far below 10 MB: refuse, write nothing (T-0015).
        var c = context([f.video]); c.options = ["mb": "10"]
        let refused = try await CompressMediaAction().run(c)
        #expect(refused.created.isEmpty && refused.failures.first?.message.contains("already under 10 MB") == true)
        #expect(names(f.directory) == ["colors.mov", "tone.wav"])
        let gif = try #require(try await MakeGIFAction().run(context([f.video])).created.first)
        #expect(gif.pathExtension == "gif")
    }

    @Test func menuOffersOnlyWritableAudio() throws {
        let p = SharedPaths(root: try tempDir("root"))
        var on = ClicksmithSettings(); on.shownActions = ["media.convertAudio"]   // off by default (Quick Action exists)
        let menu = "\(ActionRegistry(BuiltInActions.all()).menuModel(settings: on, paths: p).items)"
        for f in MediaEngine.writableAudioFormats() { #expect(menu.contains(f.title)) }
        #expect(menu.contains("For Discord (10 MB)") && menu.contains("Make GIF"))
    }
}

@Test("Codex review: huge size option is refused, no crash") func compressHugeSize() async throws {
    let d = try tempDir(); let f = try touch(d, "a.mp4")
    for bad in ["9223372036855", "0", "-5", "abc"] {
        var c = context([f]); c.options = ["mb": bad]
        await #expect(throws: PowerError.self) { _ = try await CompressMediaAction().process(f, c) }
    }
    #expect(names(d) == ["a.mp4"])
}
