import Foundation

public struct FileTemplate: Codable, Sendable {
    public let id: String
    /// Default filename stem. Dotfiles and Makefile use a literal name and an empty extension.
    public let name: String
    public let ext: String
    public let contents: Data
    public let symbol: String

    /// The journaled writer must apply executable permissions when creating this template.
    public var isExecutable: Bool { ext == "sh" }

    public init(id: String, name: String, ext: String, contents: Data, symbol: String) {
        self.id = id
        self.name = name
        self.ext = ext
        self.contents = contents
        self.symbol = symbol
    }
}

public enum TemplateLibrary {
    /// Shown in New File ▸ (kept short). The rest still work in csx; own templates always show.
    public static let inMenu: Set<String> = ["text", "markdown", "docx", "csv"]
    public static let builtIn: [FileTemplate] = [
        text("text", "Text File", "txt", "", "doc.text"),
        text("markdown", "Markdown", "md", "# Title\n\n", "text.document"),
        text("rtf", "Rich Text", "rtf", #"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs24\par}"#, "doc.richtext"),
        text("html", "Web Page", "html", """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>Untitled</title></head>
            <body>
            </body>
            </html>

            """, "globe"),
        text("css", "Stylesheet", "css", "/* Styles */\n", "curlybraces"),
        text("javascript", "JavaScript", "js", "\"use strict\";\n", "curlybraces"),
        text("typescript", "TypeScript", "ts", "export {};\n", "curlybraces"),
        text("python", "Python Script", "py", "#!/usr/bin/env python3\n", "chevron.left.forwardslash.chevron.right"),
        text("swift", "Swift Source", "swift", "import Foundation\n", "swift"),
        text("shell", "Shell Script", "sh", "#!/bin/sh\nset -eu\n", "terminal"),
        text("json", "JSON", "json", "{}\n", "curlybraces"),
        text("yaml", "YAML", "yaml", "---\n", "list.bullet"),
        text("csv", "Table", "csv", "name,value\nexample,1\n", "tablecells"),
        text("tsv", "Tab-Separated Table", "tsv", "name\tvalue\nexample\t1\n", "tablecells"),
        text("xml", "XML", "xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root/>\n", "chevron.left.forwardslash.chevron.right"),
        text("svg", "Drawing", "svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" viewBox=\"0 0 100 100\"/>\n", "square.on.circle"),
        FileTemplate(id: "docx", name: "Document", ext: "docx", contents: emptyWordDocument(), symbol: "doc.richtext"),
        text("gitignore", ".gitignore", "", "# Files ignored by Git\n.DS_Store\n", "eye.slash"),
        text("readme", "README", "md", "# Project\n\n## Usage\n\n", "text.book.closed"),
        text("makefile", "Makefile", "", ".PHONY: help\nhelp:\n\t@echo 'Add your build commands here.'\n", "hammer"),
        text("env", ".env", "", "# KEY=value\n", "gearshape"),
        text("sql", "Query", "sql", "-- SQL query\n", "cylinder"),
    ]

    private static func text(_ id: String, _ name: String, _ ext: String, _ contents: String, _ symbol: String) -> FileTemplate {
        FileTemplate(id: id, name: name, ext: ext, contents: Data(contents.utf8), symbol: symbol)
    }

    /// A minimal OOXML package. Stored ZIP entries need no compression dependency or
    /// runtime subprocess, and the fixed timestamp makes the template reproducible.
    private static func emptyWordDocument() -> Data {
        let entries: [(String, String)] = [
            ("[Content_Types].xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
                """),
            ("_rels/.rels", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
                """),
            ("word/document.xml", """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/></w:body></w:document>
                """),
        ]
        var archive = Data()
        var directory = Data()
        for (path, xml) in entries {
            let name = Data(path.utf8)
            let contents = Data(xml.utf8)
            let size = UInt32(contents.count)
            let checksum = crc32(contents)
            let offset = UInt32(archive.count)
            append(UInt32(0x04034b50), to: &archive)
            for value: UInt16 in [20, 0, 0, 0, 0x21] { append(value, to: &archive) }
            for value in [checksum, size, size] { append(value, to: &archive) }
            append(UInt16(name.count), to: &archive)
            append(UInt16(0), to: &archive)
            archive.append(name)
            archive.append(contents)

            append(UInt32(0x02014b50), to: &directory)
            for value: UInt16 in [20, 20, 0, 0, 0, 0x21] { append(value, to: &directory) }
            for value in [checksum, size, size] { append(value, to: &directory) }
            append(UInt16(name.count), to: &directory)
            for _ in 0..<4 { append(UInt16(0), to: &directory) }
            append(UInt32(0), to: &directory)
            append(offset, to: &directory)
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        append(UInt32(0x06054b50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(entries.count), to: &archive)
        append(UInt16(entries.count), to: &archive)
        append(UInt32(directory.count), to: &archive)
        append(directoryOffset, to: &archive)
        append(UInt16(0), to: &archive)
        return archive
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0)
            }
        }
        return ~crc
    }
}
