import AppKit
import zlib

/// AppKit's DOCX writer drops hyperlinks and NSTextTable blocks. Preserve those
/// using standard WordprocessingML for the local HTML/Markdown conversion path.
enum DOCXWriter {
    static func write(_ text: NSAttributedString, to output: URL, isCancelled: () -> Bool) throws {
        let writer = Writer()
        let body = try writer.body(text, isCancelled: isCancelled)
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720"/></w:sectPr></w:body></w:document>
        """
        let types = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let packageRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="document" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let links = writer.links.enumerated().map { index, url in
            "<Relationship Id=\"link\(index)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xml(url))\" TargetMode=\"External\"/>"
        }.joined()
        let documentRels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(links)<Relationship Id=\"numbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/><Relationship Id=\"styles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
        try StoredZIP.write([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(packageRels.utf8)),
                             ("word/document.xml", Data(document.utf8)), ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
                             ("word/numbering.xml", Data(writer.numbering().utf8)), ("word/styles.xml", Data(styles.utf8))],
                            to: output, isCancelled: isCancelled)
    }

    private static var styles: String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:rPr><w:rFonts w:ascii=\"Helvetica Neue\" w:hAnsi=\"Helvetica Neue\"/><w:sz w:val=\"24\"/></w:rPr></w:style>"
        for level in 1...6 {
            xml += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Helvetica Neue\" w:hAnsi=\"Helvetica Neue\"/><w:b/><w:sz w:val=\"\((28 - level * 2) * 2)\"/></w:rPr></w:style>"
        }
        return xml + "</w:styles>"
    }

    private static func xml(_ string: String) -> String {
        let valid = String(String.UnicodeScalarView(string.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xd7ff).contains($0.value) ||
            (0xe000...0xfffd).contains($0.value) || (0x10000...0x10ffff).contains($0.value)
        }))
        return MarkdownRenderer.escape(valid)
    }

    private final class Writer {
        var links: [String] = []
        var lists: [(list: NSTextList, level: Int)] = []
        var listIDs: [ObjectIdentifier: Int] = [:]

        func numbering() -> String {
            var result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            // All instances share two definitions; starts belong to instances.
            for (id, ordered) in [(1, false), (2, true)] {
                result += "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"multilevel\"/>"
                for level in 0...8 {
                    let marker = ordered ? "%\(level + 1)." : "•"
                    result += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(ordered ? "decimal" : "bullet")\"/><w:lvlText w:val=\"\(marker)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\((level + 1) * 360)\" w:hanging=\"180\"/></w:pPr></w:lvl>"
                }
                result += "</w:abstractNum>"
            }
            for (index, entry) in lists.enumerated() {
                let abstract = entry.list.markerFormat == .decimal ? 2 : 1
                result += "<w:num w:numId=\"\(index + 1)\"><w:abstractNumId w:val=\"\(abstract)\"/><w:lvlOverride w:ilvl=\"\(entry.level)\"><w:startOverride w:val=\"\(entry.list.startingItemNumber)\"/></w:lvlOverride></w:num>"
            }
            return result + "</w:numbering>"
        }

        func body(_ text: NSAttributedString, isCancelled: () -> Bool) throws -> String {
            let source = text.string as NSString
            var body = "", offset = 0
            var table: NSTextTable?
            var rows: [Int: [Int: (span: Int, content: String)]] = [:]
            func flushTable() {
                guard let table else { return }
                body += "<w:tbl><w:tblPr><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>"
                for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] { body += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:color=\"BBBBBB\"/>" }
                body += "</w:tblBorders></w:tblPr><w:tblGrid>"
                for _ in 0..<table.numberOfColumns { body += "<w:gridCol w:w=\"\(10_466 / max(1, table.numberOfColumns))\"/>" }
                body += "</w:tblGrid>"
                for row in rows.keys.sorted() {
                    body += "<w:tr>"
                    for column in (rows[row] ?? [:]).keys.sorted() {
                        guard let cell = rows[row]?[column] else { continue }
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"\(10_466 * cell.span / max(1, table.numberOfColumns))\" w:type=\"dxa\"/>"
                        if cell.span > 1 { body += "<w:gridSpan w:val=\"\(cell.span)\"/>" }
                        body += "</w:tcPr>\(cell.content)</w:tc>"
                    }
                    body += "</w:tr>"
                }
                body += "</w:tbl>"
                rows.removeAll()
            }
            while offset < source.length {
                try DocumentIO.checkCancellation(isCancelled)
                var end = 0, contentEnd = 0
                source.getParagraphStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: offset, length: 0))
                let attrs = text.attributes(at: offset, effectiveRange: nil)
                let style = attrs[.paragraphStyle] as? NSParagraphStyle
                let cell = style?.textBlocks.first as? NSTextTableBlock
                if cell?.table !== table {
                    flushTable(); table = cell?.table
                }
                let paragraph = paragraph(text, source: source, range: NSRange(location: offset, length: contentEnd - offset), style: style)
                if let cell {
                    var columns = rows[cell.startingRow] ?? [:]
                    let old = columns[cell.startingColumn]?.content ?? ""
                    columns[cell.startingColumn] = (cell.columnSpan, old + paragraph)
                    rows[cell.startingRow] = columns
                } else { body += paragraph }
                offset = end
            }
            flushTable()
            return body.isEmpty ? "<w:p/>" : body
        }

        func paragraph(_ text: NSAttributedString, source: NSString, range: NSRange, style: NSParagraphStyle?) -> String {
            var properties = "", numbering = "", indentation = ""
            var contentRange = range
            if let style {
                let heading = min(6, max(0, style.headerLevel))
                if heading > 0 { properties += "<w:pStyle w:val=\"Heading\(heading)\"/><w:keepNext/>" }
                if let list = style.textLists.last {
                    let value = source.substring(with: range)
                    if let marker = value.range(of: "^(?:•|[0-9]+\\.)\\t", options: .regularExpression) {
                        let length = (String(value[marker]) as NSString).length
                        contentRange.location += length; contentRange.length -= length
                        let key = ObjectIdentifier(list), level = min(8, style.textLists.count - 1)
                        let index: Int
                        if let existing = listIDs[key] { index = existing }
                        else { index = lists.count; listIDs[key] = index; lists.append((list, level)) }
                        numbering = "<w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(index + 1)\"/></w:numPr>"
                    } else { indentation = "<w:ind w:left=\"\(style.textLists.count * 360)\"/>" }
                }
                properties += numbering + indentation
                let alignment: String
                switch style.alignment { case .right: alignment = "right"; case .center: alignment = "center"; case .justified: alignment = "both"; default: alignment = "left" }
                properties += "<w:jc w:val=\"\(alignment)\"/>"
                if heading > 0 { properties += "<w:outlineLvl w:val=\"\(heading - 1)\"/>" }
            }
            var result = "<w:p><w:pPr>\(properties)</w:pPr>"
            text.enumerateAttributes(in: contentRange) { attrs, runRange, _ in
                var properties = "", size = ""
                if let font = attrs[.font] as? NSFont {
                    let family = font.familyName ?? font.fontName
                    let publicFamily = font.fontDescriptor.symbolicTraits.contains(.monoSpace) ? "Menlo" : family.hasPrefix(".") ? "Helvetica Neue" : family
                    let name = DOCXWriter.xml(publicFamily)
                    properties += "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\"/>"
                    if font.fontDescriptor.symbolicTraits.contains(.bold) { properties += "<w:b/>" }
                    if font.fontDescriptor.symbolicTraits.contains(.italic) { properties += "<w:i/>" }
                    size = "<w:sz w:val=\"\(Int(font.pointSize * 2))\"/>"
                }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { properties += "<w:strike/>" }
                properties += size
                if (attrs[.underlineStyle] as? Int ?? 0) != 0 { properties += "<w:u w:val=\"single\"/>" }
                let value = DOCXWriter.xml(source.substring(with: runRange))
                    .replacingOccurrences(of: "\t", with: "</w:t><w:tab/><w:t xml:space=\"preserve\">")
                    .replacingOccurrences(of: "\n", with: "</w:t><w:br/><w:t xml:space=\"preserve\">")
                let run = "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(value)</w:t></w:r>"
                let link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
                if let link {
                    let index = links.count; links.append(link)
                    result += "<w:hyperlink r:id=\"link\(index)\">\(run)</w:hyperlink>"
                } else { result += run }
            }
            return result + "</w:p>"
        }
    }
}

/// A small ZIP32 writer. Stored entries keep document packaging dependency-free.
private enum StoredZIP {
    static func write(_ entries: [(String, Data)], to output: URL, isCancelled: () -> Bool) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw PowerError.failed("Could not create the DOCX archive.") }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        var central = Data()
        for (name, data) in entries {
            try DocumentIO.checkCancellation(isCancelled)
            let offset = try handle.offset()
            guard data.count < UInt32.max, offset < UInt32.max else { throw PowerError.unsupported("This document exceeds the DOCX archive size limit.") }
            let path = Data(name.utf8)
            let crc = data.withUnsafeBytes { bytes in
                UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
            }
            var local = Data()
            local.put(UInt32(0x04034b50)); local.put(UInt16(20)); local.put(UInt16(0x800)); local.put(UInt16(0))
            local.put(UInt16(0)); local.put(UInt16(0x21)); local.put(crc); local.put(UInt32(data.count)); local.put(UInt32(data.count))
            local.put(UInt16(path.count)); local.put(UInt16(0)); local.append(path)
            try handle.write(contentsOf: local)
            // Chunking keeps cancellation responsive during large writes.
            for start in stride(from: 0, to: data.count, by: 64 * 1024) {
                try DocumentIO.checkCancellation(isCancelled)
                try handle.write(contentsOf: data[start..<min(data.count, start + 64 * 1024)])
            }
            central.put(UInt32(0x02014b50)); central.put(UInt16(20)); central.put(UInt16(20)); central.put(UInt16(0x800)); central.put(UInt16(0))
            central.put(UInt16(0)); central.put(UInt16(0x21)); central.put(crc); central.put(UInt32(data.count)); central.put(UInt32(data.count))
            central.put(UInt16(path.count)); central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0))
            central.put(UInt32(0)); central.put(UInt32(offset)); central.append(path)
        }
        let offset = try handle.offset()
        guard offset < UInt32.max else { throw PowerError.unsupported("This document exceeds the DOCX archive size limit.") }
        try handle.write(contentsOf: central)
        var end = Data()
        end.put(UInt32(0x06054b50)); end.put(UInt16(0)); end.put(UInt16(0)); end.put(UInt16(entries.count)); end.put(UInt16(entries.count))
        end.put(UInt32(central.count)); end.put(UInt32(offset)); end.put(UInt16(0))
        try handle.write(contentsOf: end)
    }
}

private extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
