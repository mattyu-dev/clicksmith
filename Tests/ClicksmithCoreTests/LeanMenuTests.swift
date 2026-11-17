import Testing
@testable import ClicksmithCore

@Test("Items macOS already has are off by default; image items stay on") func leanMenu() {
    let s = ClicksmithSettings()
    let all = BuiltInActions.all().map(\.descriptor)
    for d in all where ActionDescriptor.builtIntoMacOS.contains(d.id) { #expect(!s.isVisible(d), "\(d.id)") }
    for id in ["image.convert", "image.resize", "image.makeIcon", "image.stripMetadata", "image.removeBackground", "text.ocr", "qr.read", "copy.path", "create.newFile"] {
        #expect(all.first { $0.id == id }.map(s.isVisible) == true, "\(id)")
    }
    #expect(Set(all.map(\.id)).isSuperset(of: ActionDescriptor.builtIntoMacOS))
    var on = s; on.shownActions.insert("organize.batchRename")
    #expect(on.isVisible(all.first { $0.id == "organize.batchRename" }!))
}
