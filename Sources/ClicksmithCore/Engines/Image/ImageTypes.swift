import Foundation

public enum ImageFormat: String, Codable, Sendable, CaseIterable {
    case jpeg, png, heic, avif, tiff, gif, bmp, webp, jp2, ico, icns, pdf

    var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .png: "public.png"
        case .heic: "public.heic"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        case .webp: "org.webmproject.webp"
        case .jp2: "public.jpeg-2000"
        case .ico: "com.microsoft.ico"
        case .icns: "com.apple.icns"
        case .pdf: "com.adobe.pdf"
        }
    }
}

/// RGB components in the range 0...1, used when a JPEG cannot retain transparency.
public struct ImageBackground: Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double = 1, green: Double = 1, blue: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct ImageConvertOptions: Codable, Sendable {
    public var quality: Double?
    public var maxPixelSize: Int?
    public var stripMetadata: Bool
    public var keepColorProfile: Bool
    public var background: ImageBackground

    public init(quality: Double? = nil, maxPixelSize: Int? = nil,
                stripMetadata: Bool = false, keepColorProfile: Bool = true,
                background: ImageBackground = ImageBackground()) {
        self.quality = quality
        self.maxPixelSize = maxPixelSize
        self.stripMetadata = stripMetadata
        self.keepColorProfile = keepColorProfile
        self.background = background
    }
}

public struct ImageInfo: Codable, Sendable {
    /// Encoded pixel dimensions. Conversion applies EXIF orientation to the pixels.
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let dpiWidth: Double?
    public let dpiHeight: Double?
    public let colorModel: String?
    public let hasAlpha: Bool
    /// EXIF's original date string, which may have no timezone.
    public let exifDate: String?
    public let cameraMake: String?
    public let cameraModel: String?
    public let frameCount: Int
}

/// Kept local to the engine until the action layer supplies PowerError and FileOps.
public enum ImageEngineError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case invalidOptions(String)
    case unsupportedFormat(ImageFormat)
    case outputExists(String)
    case encodingFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput: "The image could not be read."
        case .invalidOptions: "The image options are invalid."
        case .unsupportedFormat: "This image format cannot be written on this Mac."
        case .outputExists: "A file already exists at the output path."
        case .encodingFailed: "The image could not be converted."
        case .writeFailed: "The converted image could not be saved."
        }
    }

    public var detail: String {
        switch self {
        case .invalidInput(let detail), .invalidOptions(let detail), .outputExists(let detail),
             .encodingFailed(let detail), .writeFailed(let detail): detail
        case .unsupportedFormat(let format): "ImageIO has no writer for \(format.rawValue)."
        }
    }
}
