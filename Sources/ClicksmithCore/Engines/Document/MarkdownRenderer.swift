import Foundation
import Darwin

public enum MarkdownStyle: String, Codable, Sendable, CaseIterable {
    case github
}

public enum MarkdownRenderer {
    /// Raw HTML is omitted. System CommonMark/GFM parsing is optional acceleration;
    /// the Swift renderer also works when the private system library is absent.
    public static func html(_ markdown: String, title: String?, style: MarkdownStyle = .github, useSystemRenderer: Bool = true) -> String {
        let accelerated = useSystemRenderer ? CMark.shared?.render(markdown) : nil
        let body = accelerated ?? SwiftMarkdownRenderer.render(markdown)
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: file: https:;">
        <title>\(escape(title ?? "Document"))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; max-width: 900px; margin: 40px auto; padding: 0 24px; color: #24292f; background: #fff; overflow-wrap: break-word; }
        h1,h2,h3,h4,h5,h6 { line-height: 1.25; margin: 1.4em 0 .6em; }
        h1,h2 { border-bottom: 1px solid #d0d7de; padding-bottom: .3em; }
        a { color: #0969da; } blockquote { border-left: 4px solid #d0d7de; margin-left: 0; padding-left: 1em; color: #57606a; }
        pre,code { font-family: ui-monospace, Menlo, monospace; background: #f6f8fa; border-radius: 6px; }
        code { padding: .15em .3em; } pre { padding: 16px; overflow-x: auto; } pre code { padding: 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; } th,td { border: 1px solid #d0d7de; padding: 6px 13px; }
        img { max-width: 100%; } input[type=checkbox] { margin-right: .4em; } hr { border: 0; border-top: 1px solid #d0d7de; }
        @media (prefers-color-scheme: dark) {
          body { color: #e6edf3; background: #0d1117; } a { color: #58a6ff; }
          pre,code { background: #161b22; } h1,h2,th,td,blockquote,hr { border-color: #30363d; } blockquote { color: #8b949e; }
        }
        @media print { body { color: #000; background: #fff; margin: 0; max-width: none; } pre { white-space: pre-wrap; } }
        </style></head><body>
        \(body)
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

}

/// The system library has no Swift module. Keep its C ABI in this one adapter.
private final class CMark: @unchecked Sendable {
    typealias New = @convention(c) (Int32) -> OpaquePointer?
    typealias Free = @convention(c) (OpaquePointer?) -> Void
    typealias Feed = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Void
    typealias Finish = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias Render = @convention(c) (OpaquePointer?, Int32, OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias Find = @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    typealias Attach = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32
    typealias Extensions = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias Register = @convention(c) () -> Void

    static let shared = CMark()
    private let handle: UnsafeMutableRawPointer
    private let new: New, freeParser: Free, feed: Feed, finish: Finish, freeNode: Free
    private let renderHTML: Render, find: Find, attach: Attach, extensions: Extensions

    private init?() {
        guard let handle = dlopen("/usr/lib/libcmark-gfm.dylib", RTLD_LOCAL | RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let value = dlsym(handle, name) else { return nil }
            return unsafeBitCast(value, to: type)
        }
        guard let new = symbol("cmark_parser_new", New.self),
              let freeParser = symbol("cmark_parser_free", Free.self),
              let feed = symbol("cmark_parser_feed", Feed.self),
              let finish = symbol("cmark_parser_finish", Finish.self),
              let freeNode = symbol("cmark_node_free", Free.self),
              let render = symbol("cmark_render_html", Render.self),
              let find = symbol("cmark_find_syntax_extension", Find.self),
              let attach = symbol("cmark_parser_attach_syntax_extension", Attach.self),
              let extensions = symbol("cmark_parser_get_syntax_extensions", Extensions.self),
              let register = symbol("cmark_gfm_core_extensions_ensure_registered", Register.self) else {
            dlclose(handle); return nil
        }
        self.handle = handle; self.new = new; self.freeParser = freeParser; self.feed = feed
        self.finish = finish; self.freeNode = freeNode; self.renderHTML = render
        self.find = find; self.attach = attach; self.extensions = extensions
        register()
    }

    deinit { dlclose(handle) }

    func render(_ markdown: String) -> String? {
        // Default options exclude raw HTML and dangerous URL schemes.
        guard let parser = new(0) else { return nil }
        defer { freeParser(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist", "tagfilter"] {
            guard let ext = name.withCString({ find($0) }), attach(parser, ext) != 0 else { return nil }
        }
        markdown.withCString { feed(parser, $0, markdown.utf8.count) }
        guard let node = finish(parser) else { return nil }
        defer { freeNode(node) }
        guard let output = renderHTML(node, 0, extensions(parser)) else { return nil }
        defer { free(output) }
        return String(cString: output)
    }
}
