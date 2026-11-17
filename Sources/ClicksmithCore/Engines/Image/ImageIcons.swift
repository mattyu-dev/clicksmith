import CoreGraphics
import Foundation
import ImageIO

extension ImageEngine {
    static func iconData(_ source: ImageInput, format: ImageFormat, options: ImageConvertOptions) throws -> Data {
        let bound = min(options.maxPixelSize ?? (format == .ico ? 256 : 1024), format == .ico ? 256 : 1024)
        let image = try source.image(at: source.primaryIndex, maxPixelSize: bound)
        switch format {
        case .ico: return try ico(image, keepColorProfile: options.keepColorProfile, maxPixelSize: options.maxPixelSize)
        case .icns: return try icns(image, keepColorProfile: options.keepColorProfile, maxPixelSize: options.maxPixelSize)
        default: throw ImageEngineError.invalidOptions("Icon container must be ico or icns.")
        }
    }

    private static func png(_ image: CGImage, size: Int, keepColorProfile: Bool) throws -> Data {
        let bitmap = try rendered(image, keepColorProfile: keepColorProfile, canvasSize: size)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw ImageEngineError.encodingFailed("Cannot create icon PNG.")
        }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageEngineError.encodingFailed("Cannot encode icon PNG.") }
        return data as Data
    }

    private static func ico(_ image: CGImage, keepColorProfile: Bool, maxPixelSize: Int?) throws -> Data {
        // ICO's one-byte dimensions encode 256 as zero. Larger sizes belong in ICNS.
        let limit = min(maxPixelSize ?? 256, 256)
        let sizes = limit < 16 ? [limit] : [16, 32, 48, 64, 128, 256].filter { $0 <= limit }
        let payloads = try sizes.map { try png(image, size: $0, keepColorProfile: keepColorProfile) }
        var data = Data()
        appendLittle(UInt16(0), to: &data)
        appendLittle(UInt16(1), to: &data)
        appendLittle(UInt16(sizes.count), to: &data)
        var offset = 6 + sizes.count * 16
        for (size, payload) in zip(sizes, payloads) {
            data.append(contentsOf: [UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0])
            appendLittle(UInt16(1), to: &data)
            appendLittle(UInt16(32), to: &data)
            appendLittle(UInt32(payload.count), to: &data)
            appendLittle(UInt32(offset), to: &data)
            offset += payload.count
        }
        for payload in payloads { data.append(payload) }
        return data
    }

    private static func icns(_ image: CGImage, keepColorProfile: Bool, maxPixelSize: Int?) throws -> Data {
        // Retina tags identify logical size independently of the PNG's physical pixels.
        let entries = [
            ("icp4", 16), ("icp5", 32), ("ic07", 128),
            ("ic08", 256), ("ic09", 512), ("ic10", 1024),
            ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)
        ].filter { $0.1 <= (maxPixelSize ?? 1024) }
        guard !entries.isEmpty else { throw ImageEngineError.invalidOptions("ICNS requires at least 16 pixels.") }
        var body = Data()
        var payloads: [Int: Data] = [:]
        for (tag, size) in entries {
            let payload: Data
            if let cached = payloads[size] { payload = cached } else {
                payload = try png(image, size: size, keepColorProfile: keepColorProfile)
                payloads[size] = payload
            }
            body.append(contentsOf: tag.utf8)
            appendBig(UInt32(payload.count + 8), to: &body)
            body.append(payload)
        }
        var data = Data("icns".utf8)
        appendBig(UInt32(body.count + 8), to: &data)
        data.append(body)
        return data
    }

    private static func appendLittle<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bytes = value.littleEndian
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }

    private static func appendBig(_ value: UInt32, to data: inout Data) {
        var bytes = value.bigEndian
        withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
    }
}
