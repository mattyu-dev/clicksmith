import Foundation
import Testing
@testable import ClicksmithCore

@Suite struct ClipboardDetectionPerformanceTests {
    // Review 1: many opening tags without a closing tag must not cause backtracking
    // across the entire paste. Checking bytes also catches accidental output truncation.
    @Test func review01OneMegabyteOfUnclosedTagsTakesLessThanOneSecond() {
        let input = String(repeating: "<p>abcdefghij", count: 90_000)
        #expect(input.utf8.count >= 1_048_576)
        let start = ContinuousClock.now
        let result = ClipboardDetector.detect(.text(input))
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .seconds(1), "Detection took \(elapsed)")
        #expect(result.ext == "txt")
        #expect(result.data == Data(input.utf8))
        print("T-0005 review 1: \(input.utf8.count) bytes detected in \(elapsed)")
    }
}
