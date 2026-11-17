import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

public enum CodeWriter {
    public enum Correction: String, Sendable, CaseIterable { case L, M, Q, H }

    public static func qrPNG(_ text: String, size: Int = 1024, correction: Correction = .M, output: URL,
                             progress: (Double) -> Void = { _ in },
                             isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        try VisionIO.typed("Could not create the QR image.") {
            try VisionIO.check(isCancelled)
            guard (1...6_000).contains(size), text.utf8.count <= 7_089 else {
                throw PowerError.badInput("Choose a QR size up to 6000 pixels and a payload within QR capacity.")
            }
            progress(0)
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = correction.rawValue
            guard let code = filter.outputImage else { throw PowerError.badInput("This text exceeds the QR code capacity at this correction level.") }
            let modules = Int(code.extent.width)
            let scale = size / (modules + 8)
            guard scale >= 1 else { throw PowerError.badInput("The QR image is too small to include a four-module quiet zone.") }
            try VisionIO.check(isCancelled)
            guard let image = CIContext().createCGImage(code, from: code.extent),
                  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw PowerError.failed("Could not render the QR image.")
            }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.interpolationQuality = .none
            let side = modules * scale, inset = (size - side) / 2
            ctx.draw(image, in: CGRect(x: inset, y: inset, width: side, height: side))
            progress(0.7)
            try VisionIO.check(isCancelled)
            guard let result = ctx.makeImage() else { throw PowerError.failed("Could not render the QR image.") }
            let data = try VisionIO.png(result)
            try VisionIO.write(data, to: output, isCancelled: isCancelled)
            progress(1)
        }
    }

    /// ZXing Wi-Fi encoding. Escape backslashes before the delimiter characters.
    public static func wifiString(ssid: String, password: String? = nil, security: String = "WPA", hidden: Bool = false) -> String {
        func escape(_ value: String) -> String {
            value.reduce(into: "") { output, c in
                if "\\;,:\"".contains(c) { output.append("\\") }
                output.append(c)
            }
        }
        func field(_ value: String) -> String {
            let escaped = escape(value)
            let isHex = !value.isEmpty && value.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
            return isHex ? "\"\(escaped)\"" : escaped
        }
        var value = "WIFI:T:\(escape(security));S:\(field(ssid));"
        if let password { value += "P:\(field(password));" }
        return value + "H:\(hidden ? "true" : "false");;"
    }
}
