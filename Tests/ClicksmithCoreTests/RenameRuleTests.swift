import Foundation
import Testing
@testable import ClicksmithCore

private func previewName(_ name: String, _ rules: [RenameRule], facts: RenameItem.Facts = .init()) -> RenamePlan {
    RenameEngine.preview([.init(url: URL(fileURLWithPath: "/clicksmith-rename-rule-tests/" + name), facts: facts)], rules: rules)[0]
}

@Suite("Rename rules")
struct RenameRuleTests {
    @Test func prefixKeepsExtension() {
        #expect(previewName("photo.JPG", [.prefix("new-")]).newName == "new-photo.JPG")
    }

    @Test func suffixKeepsExtension() {
        #expect(previewName("photo.jpg", [.suffix("-edited")]).newName == "photo-edited.jpg")
    }

    @Test func rulesRunInOrder() {
        #expect(previewName("photo.jpg", [.prefix("A"), .replace(find: "Aphoto", with: "B", caseSensitive: true), .suffix("C")]).newName == "BC.jpg")
    }

    @Test func replaceIsLiteral() {
        #expect(previewName("a.b[1].txt", [.replace(find: ".b[1]", with: "$1", caseSensitive: true)]).newName == "a$1.txt")
    }

    @Test func caseSensitiveReplace() {
        #expect(previewName("PhotoPHOTO.txt", [.replace(find: "PHOTO", with: "image", caseSensitive: true)]).newName == "Photoimage.txt")
    }

    @Test func caseInsensitiveReplace() {
        #expect(previewName("PhotoPHOTO.txt", [.replace(find: "photo", with: "image", caseSensitive: false)]).newName == "imageimage.txt")
    }

    @Test func regexCaptureTemplate() {
        #expect(previewName("IMG_1234.jpg", [.regex(pattern: #"IMG_(\d+)"#, template: "photo-$1")]).newName == "photo-1234.jpg")
    }

    @Test func regexUsesUTF16Ranges() {
        #expect(previewName("📷é123.jpg", [.regex(pattern: #"(\d+)"#, template: "[$1]")]).newName == "📷é[123].jpg")
    }

    @Test func invalidRegexIsConflict() {
        #expect(previewName("photo.jpg", [.regex(pattern: "[", template: "")]).conflict == .invalidName)
    }

    @Test func emptySearchIsConflict() {
        #expect(previewName("photo.jpg", [.replace(find: "", with: "x", caseSensitive: true)]).conflict == .invalidName)
    }

    @Test func allCaseStyles() {
        let cases: [(RenameRule.CaseStyle, String)] = [
            (.lower, "hello world"), (.upper, "HELLO WORLD"), (.title, "Hello World"), (.sentence, "Hello world"),
            (.camel, "helloWorld"), (.pascal, "HelloWorld"), (.kebab, "hello-world"), (.snake, "hello_world")
        ]
        #expect(cases.count == RenameRule.CaseStyle.allCases.count)
        for (style, expected) in cases {
            #expect(previewName("hello WORLD.txt", [.changeCase(style)]).newName == expected + ".txt", "\(style)")
        }
    }

    @Test func wordStylesSplitAcronyms() {
        #expect(previewName("JSONParser helloWorld.txt", [.changeCase(.snake)]).newName == "json_parser_hello_world.txt")
    }

    @Test func sentenceHandlesLeadingWhitespaceAndUnicode() {
        #expect(previewName("  ÉCOLE À PARIS.txt", [.changeCase(.sentence)]).newName == "  École à paris.txt")
    }

    @Test func uppercaseCanExpandCharacters() {
        #expect(previewName("straße.txt", [.changeCase(.upper)]).newName == "STRASSE.txt")
    }

    @Test func trimWhitespace() {
        #expect(previewName(" \tphoto\n .txt", [.trimWhitespace]).newName == "photo.txt")
    }

    @Test func collapseWhitespacePreservesOneBoundarySpace() {
        #expect(previewName("  a\t\n b  .txt", [.collapseWhitespace]).newName == " a b .txt")
    }

    @Test func removeCharactersUsesGraphemes() {
        #expect(previewName("a👨‍👩‍👧‍👦é-b.txt", [.removeCharacters(set: "👨‍👩‍👧‍👦é-")]).newName == "ab.txt")
    }

    @Test func sequenceUsesInputOrderAndStep() {
        let items = ["c", "a", "b"].map { RenameItem(url: URL(fileURLWithPath: "/clicksmith-rename-rule-tests/\($0).txt")) }
        let plans = RenameEngine.preview(items, rules: [.sequence(start: 3, step: 2, padding: 3, position: .prefix, separator: "-")])
        #expect(plans.map(\.newName) == ["003-c.txt", "005-a.txt", "007-b.txt"])
        #expect(plans.allSatisfy { $0.conflict == nil })
    }

    @Test func negativeSequenceAndSuffix() {
        #expect(previewName("a.txt", [.sequence(start: -2, step: -1, padding: 3, position: .suffix, separator: "_")]).newName == "a_-002.txt")
    }

    @Test func minimumIntegerSequence() {
        #expect(previewName("a.txt", [.sequence(start: .min, step: 0, padding: 0, position: .prefix, separator: "_")]).newName == "\(Int.min)_a.txt")
    }

    @Test func sequenceOverflowIsConflict() {
        let items = ["a", "b", "c"].map { RenameItem(url: URL(fileURLWithPath: "/clicksmith-rename-rule-tests/\($0)")) }
        let plans = RenameEngine.preview(items, rules: [.sequence(start: .max, step: .max, padding: 0, position: .prefix, separator: "")])
        #expect(plans[0].conflict == nil)
        #expect(plans[1].conflict == .invalidName)
        #expect(plans[2].conflict == .invalidName)
    }

    @Test func invalidPaddingIsConflict() {
        for padding in [-1, Int.max] {
            #expect(previewName("a", [.sequence(start: 0, step: 1, padding: padding, position: .prefix, separator: "")]).conflict == .invalidName)
        }
    }

    @Test func allDateSourcesUseInjectedFactsAndUTC() {
        let day: TimeInterval = 86_400
        let facts = RenameItem.Facts(created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: day),
                                    exifDate: Date(timeIntervalSince1970: 2 * day), now: Date(timeIntervalSince1970: 3 * day))
        let sources: [RenameRule.DateSource] = [.created, .modified, .exifTaken, .now]
        for (index, source) in sources.enumerated() {
            let plan = previewName("photo.jpg", [.datePrefix(source: source, format: "yyyy-MM-dd'_'天地")], facts: facts)
            #expect(plan.newName == "1970-01-0\(index + 1)_天地photo.jpg")
            #expect(plan.conflict == nil)
        }
    }

    @Test func missingDateIsConflict() {
        #expect(previewName("photo.jpg", [.datePrefix(source: .exifTaken, format: "yyyy")]).conflict == .invalidName)
    }

    @Test func emptyDateFormatIsConflict() {
        #expect(previewName("photo.jpg", [.datePrefix(source: .now, format: "")]).conflict == .invalidName)
    }

    @Test func extensionLower() {
        #expect(previewName("Photo.JPEG", [.extension(.lower)]).newName == "Photo.jpeg")
    }

    @Test func extensionUpper() {
        #expect(previewName("Photo.jpeg", [.extension(.upper)]).newName == "Photo.JPEG")
    }

    @Test func extensionSetAndRemove() {
        #expect(previewName("archive.tar.gz", [.extension(.set("zip"))]).newName == "archive.tar.zip")
        #expect(previewName("archive.tar.gz", [.extension(.remove)]).newName == "archive.tar")
    }

    @Test func extensionlessFile() {
        #expect(previewName("README", [.suffix("-new"), .extension(.set("txt"))]).newName == "README-new.txt")
        #expect(previewName("README.txt", [.extension(.set(""))]).newName == "README")
    }

    @Test func hiddenFileRemainsHidden() {
        #expect(previewName(".env", [.suffix("-backup")]).newName == ".env-backup")
        #expect(previewName(".config.json", [.suffix("-backup")]).newName == ".config-backup.json")
    }

    @Test func insertCountsGraphemes() {
        #expect(previewName("a👨‍👩‍👧‍👦b.txt", [.insert(text: "X", at: 2)]).newName == "a👨‍👩‍👧‍👦Xb.txt")
        #expect(previewName("ab", [.insert(text: "X", at: 0)]).newName == "Xab")
        #expect(previewName("ab", [.insert(text: "X", at: 2)]).newName == "abX")
    }

    @Test func invalidInsertIndexIsConflict() {
        for offset in [-1, 4, Int.max] {
            #expect(previewName("abc", [.insert(text: "x", at: offset)]).conflict == .invalidName)
        }
    }

    @Test func truncateCountsGraphemes() {
        #expect(previewName("a👩🏽‍💻ébc.txt", [.truncate(maxLength: 3)]).newName == "a👩🏽‍💻é.txt")
        #expect(previewName("abc", [.truncate(maxLength: 100)]).conflict == .unchanged)
    }

    @Test func invalidTruncateLength() {
        #expect(previewName("abc.txt", [.truncate(maxLength: -1)]).conflict == .invalidName)
        #expect(previewName("abc.txt", [.truncate(maxLength: 0)]).conflict == .invalidName)
    }

    @Test func emptyResultIsInvalid() {
        #expect(previewName("abc.txt", [.replace(find: "abc", with: "", caseSensitive: true)]).conflict == .invalidName)
    }

    @Test func invalidCharactersAndHiddenNameAreFlagged() {
        for prefix in ["/", ":", "\0", ".", "/\u{301}", ":\u{301}", ".\u{301}"] {
            #expect(previewName("a.txt", [.prefix(prefix)]).conflict == .invalidName)
        }
        #expect(previewName("a.txt", [.extension(.set("bad/name"))]).conflict == .invalidName)
    }

    @Test func nameLengthUsesUTF8Bytes() {
        let allowed = [String(repeating: "a", count: 255), String(repeating: "📷", count: 63) + "abc",
                       String(repeating: "é", count: 127) + "a", String(repeating: "e\u{301}", count: 85)]
        for name in allowed {
            let plan = previewName("a", [.replace(find: "a", with: name, caseSensitive: true)])
            #expect(plan.newName.utf8.count == 255)
            #expect(plan.conflict == nil)
        }
        let rejected = [String(repeating: "a", count: 256), String(repeating: "📷", count: 64),
                        String(repeating: "é", count: 128), String(repeating: "e\u{301}", count: 86)]
        for name in rejected {
            #expect(previewName("a", [.replace(find: "a", with: name, caseSensitive: true)]).conflict == .invalidName)
        }
    }

    @Test func lengthLimitIncludesExtension() {
        let allowed = previewName("a.txt", [.prefix(String(repeating: "x", count: 250))])
        #expect(allowed.newName.utf8.count == 255)
        #expect(allowed.conflict == nil)
        let rejected = previewName("a.txt", [.prefix(String(repeating: "x", count: 400))])
        #expect(rejected.newName.utf8.count == 405)
        #expect(rejected.conflict == .invalidName)
    }

    @Test func directoryRulesUseTheWholeName() {
        let facts = RenameItem.Facts(isDirectory: true)
        #expect(previewName("My.Folder", [.changeCase(.upper)], facts: facts).newName == "MY.FOLDER")
        #expect(previewName("My.Folder", [.suffix("-backup")], facts: facts).newName == "My.Folder-backup")
        #expect(previewName("My.Folder", [.truncate(maxLength: 5)], facts: facts).newName == "My.Fo")
    }

    @Test func extensionRulesIgnoreDirectories() {
        let facts = RenameItem.Facts(isDirectory: true)
        for change: RenameRule.ExtensionChange in [.lower, .upper, .set("txt"), .remove] {
            let plan = previewName("My.Folder", [.extension(change)], facts: facts)
            #expect(plan.newName == "My.Folder")
            #expect(plan.conflict == .unchanged)
        }
        #expect(RenameItem.Facts().isDirectory == false)
        #expect(previewName("My.Folder", [.changeCase(.upper)]).newName == "MY.Folder")
    }

    @Test func hiddenCombiningDotNameCanStayHidden() {
        let plan = previewName(".\u{301}hidden", [.suffix("-backup")])
        #expect(plan.newName == ".\u{301}hidden-backup")
        #expect(plan.conflict == nil)
    }

    @Test func dotAndDotDotAreInvalid() {
        #expect(previewName(".a", [.replace(find: "a", with: "", caseSensitive: true)]).conflict == .invalidName)
        #expect(previewName(".a", [.replace(find: "a", with: ".", caseSensitive: true)]).conflict == .invalidName)
    }

    @Test func noRulesIsUnchanged() {
        #expect(previewName("a.txt", []).conflict == .unchanged)
        #expect(RenameEngine.preview([], rules: [.prefix("x")]).isEmpty)
    }

    @Test func unicodeNormalizationIsPreserved() {
        // fileURLWithPath decomposes Unicode on this platform. Explicit URL encodings exercise both forms.
        for (path, expected) in [("caf%C3%A9", "café-x.txt"), ("cafe%CC%81", "cafe\u{301}-x.txt")] {
            let item = RenameItem(url: URL(string: "file:///clicksmith-rename-rule-tests/\(path).txt")!)
            let plan = RenameEngine.preview([item], rules: [.suffix("-x")])[0]
            #expect(plan.newName.utf8.elementsEqual(expected.utf8))
        }
    }

    @Test func normalizationOnlyChangeIsNotUnchanged() {
        let plan = previewName("cafe\u{301}.txt", [.regex(pattern: "e\u{301}", template: "é")])
        #expect(plan.newName.utf8.elementsEqual("café.txt".utf8))
        #expect(plan.conflict == nil)
    }

    @Test func emojiAndNonLatinNames() {
        #expect(previewName("📷旅行🐈.jpg", [.prefix("été-"), .suffix("-完成")]).newName == "été-📷旅行🐈-完成.jpg")
    }

    @Test func remoteURLIsInvalid() {
        let plans = RenameEngine.preview([.init(url: URL(string: "https://example.com/a.txt")!)], rules: [.prefix("x")])
        #expect(plans[0].conflict == .invalidName)
    }

    @Test func ruleCodableRoundTripAndHashable() throws {
        var rules: [RenameRule] = [
            .prefix("a"), .suffix("b"), .replace(find: "a", with: "b", caseSensitive: false), .regex(pattern: ".", template: "x"),
            .trimWhitespace, .collapseWhitespace, .removeCharacters(set: "-"),
            .sequence(start: -1, step: 2, padding: 3, position: .prefix, separator: "_"),
            .sequence(start: 0, step: 0, padding: 0, position: .suffix, separator: ""),
            .extension(.lower), .extension(.upper), .extension(.set("png")), .extension(.remove),
            .insert(text: "x", at: 1), .truncate(maxLength: 8)
        ]
        rules += RenameRule.CaseStyle.allCases.map(RenameRule.changeCase)
        rules += [.created, .modified, .exifTaken, .now].map { .datePrefix(source: $0, format: "yyyy") }
        let decoded = try JSONDecoder().decode([RenameRule].self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
        #expect(Set(decoded).count == rules.count)
    }

    @Test func conflictCodableAndPlanHashable() throws {
        let conflicts: [RenameConflict] = [.duplicateInBatch, .existsOnDisk, .invalidName, .unchanged]
        #expect(try JSONDecoder().decode([RenameConflict].self, from: JSONEncoder().encode(conflicts)) == conflicts)
        let url = URL(fileURLWithPath: "/a.txt")
        let plans = conflicts.map { RenamePlan(source: url, newName: "b.txt", conflict: $0) }
        #expect(Set(plans).count == 4)
        #expect(plans[0] == RenamePlan(source: url, newName: "b.txt", conflict: .duplicateInBatch))
    }
}
