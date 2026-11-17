import Testing
@testable import ClicksmithCore

@Test func coreHasVersion() { #expect(!ClicksmithCore.version.isEmpty) }
