import Foundation
import UniformTypeIdentifiers
import ImageIO

/// Finder menu entries for the image engine (T-0004). All work is local (ImageIO).
enum ImageExts {
    static let readable: Set<String> = Set(ImageEngine.readableTypes().compactMap { UTType($0) }
        .flatMap { $0.tags[.filenameExtension] ?? [] }.map { $0.lowercased() })

    static func title(_ f: ImageFormat) -> String {
        switch f {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .webp: "WebP"
        case .jp2: "JPEG 2000"
        case .ico: "ICO (Windows Icon)"
        case .icns: "ICNS (Mac Icon)"
        case .pdf: "PDF"
        }
    }

    static func ext(_ f: ImageFormat) -> String {
        switch f {
        case .jpeg: "jpg"
        case .jp2: "jp2"
        default: f.rawValue
        }
    }

    /// The real format of a file, read from its content (a PNG named .jpg is a PNG).
    static func format(of url: URL) -> ImageFormat? {
        let id: String?
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let t = CGImageSourceGetType(src) { id = t as String }
        else { id = UTType(filenameExtension: url.pathExtension)?.identifier }   // PDF
        guard let id else { return nil }
        return ImageFormat.allCases.first { $0.typeIdentifier == id } ?? (id == "public.heif" || id == "public.heics" ? .heic : nil)
    }

    /// Extensions of files whose own format we can also write (resize / strip keep the format).
    static let sameFormatWritable: Set<String> = Set(ImageEngine.writableFormats().filter { $0 != .ico && $0 != .icns }
        .compactMap { UTType($0.typeIdentifier) }.flatMap { $0.tags[.filenameExtension] ?? [] }.map { $0.lowercased() })
        .union(ImageEngine.writableFormats().contains(.heic) ? ["heif", "hif"] : [])
        .subtracting(["pdf"])   // PDF pages are vector: resizing/stripping would turn text into pictures
}

private func produce(_ c: ActionContext, _ url: URL, ext: String, suffix: String, _ work: (URL) throws -> Void) throws -> URL {
    try c.files.produce(from: url, ext: ext, suffix: suffix.isEmpty ? nil : suffix, work)
}

/// Engine errors are not PowerError yet: wrap them with the user message.
private func engine<T>(_ body: () throws -> T) throws -> T {
    do { return try body() }
    catch let e as PowerError { throw e }
    catch let e as ImageEngineError { throw PowerError.failed(e.errorDescription ?? "The image could not be converted.", detail: e.detail) }
    catch { throw PowerError.failed("The image could not be converted.", detail: String(describing: error)) }
}

struct ConvertImageAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "image.convert", title: "Convert Image", symbol: "photo.on.rectangle.angled", group: .image,
                                      summary: "Saves a copy in another format. Keeps colours, rotation and photo data.",
                                      extensions: ImageExts.readable.subtracting(["pdf"]), isLongRunning: true)   // PDFs: "PDF to Images"

    func dynamicMenu(_ env: MenuEnvironment) -> DynamicMenu {
        .variants(ImageEngine.writableFormats().filter { $0 != .ico && $0 != .icns }
            .map { ActionVariant(ImageExts.title($0), options: ["format": $0.rawValue]) })
    }

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let f = ImageFormat(rawValue: c.options["format"] ?? "") else { throw PowerError.badInput("Choose an image format.") }
        try c.checkCancelled()
        // Same format as the source: add a suffix so the copy is easy to tell apart.
        let suffix = ImageExts.format(of: url) == f ? "converted" : ""
        return [try engine { try produce(c, url, ext: ImageExts.ext(f), suffix: suffix) {
            try ImageEngine.convert(url, to: f, options: ImageConvertOptions(quality: f == .jpeg || f == .heic || f == .avif ? 0.9 : nil), output: $0)
        } }]
    }
}

struct ResizeImageAction: PerFileAction {
    static let sizes = [512, 1024, 1920, 2560, 3840]
    let descriptor = ActionDescriptor(id: "image.resize", title: "Resize Image", symbol: "arrow.up.left.and.arrow.down.right", group: .image,
                                      summary: "Saves a smaller copy. The longest side gets the chosen size. Never makes images bigger.",
                                      extensions: ImageExts.sameFormatWritable,
                                      variants: ResizeImageAction.sizes.map { ActionVariant("Longest Side \($0) px", options: ["px": "\($0)"]) },
                                      isLongRunning: true)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let px = Int(c.options["px"] ?? ""), (16...16_384).contains(px) else { throw PowerError.badInput("Choose a size from 16 to 16384 px.") }
        guard let f = ImageExts.format(of: url), f != .pdf else { throw PowerError.badInput("This image type cannot be resized.") }
        if let i = try? ImageEngine.info(url), max(i.pixelWidth, i.pixelHeight) <= px {
            throw PowerError.badInput("“\(url.lastPathComponent)” is already \(max(i.pixelWidth, i.pixelHeight)) px or smaller.")
        }
        try c.checkCancelled()
        // Name and encode with the one detected format (not the file extension).
        return [try engine { try produce(c, url, ext: ImageExts.ext(f), suffix: "\(px)px") {
            try ImageEngine.convert(url, to: f, options: ImageConvertOptions(maxPixelSize: px), output: $0)
        } }]
    }
}

struct MakeIconAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "image.makeIcon", title: "Make Icon", symbol: "app.dashed", group: .image,
                                      summary: "Makes an app icon with every standard size.", extensions: ImageExts.readable,
                                      variants: [ActionVariant("ICNS (Mac Icon)", options: ["format": "icns"]),
                                                 ActionVariant("ICO (Windows Icon)", options: ["format": "ico"])])

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let f = ImageFormat(rawValue: c.options["format"] ?? ""), f == .ico || f == .icns else { throw PowerError.badInput("Choose ICNS or ICO.") }
        return [try engine { try produce(c, url, ext: f.rawValue, suffix: "") { try ImageEngine.makeIcon(url, format: f, output: $0) } }]
    }
}

struct StripMetadataAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "image.stripMetadata", title: "Remove Location & Camera Data", symbol: "location.slash", group: .image,
                                      summary: "Saves a copy without GPS location, camera, and date data. Safe to share.",
                                      extensions: ImageExts.sameFormatWritable)

    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        guard let f = ImageExts.format(of: url), f != .pdf else { throw PowerError.badInput("This image type is not supported.") }
        return [try engine { try produce(c, url, ext: ImageExts.ext(f), suffix: "clean") {
            try ImageEngine.convert(url, to: f, options: ImageConvertOptions(quality: f == .jpeg || f == .heic ? 0.95 : nil, stripMetadata: true), output: $0)
        } }]
    }
}
