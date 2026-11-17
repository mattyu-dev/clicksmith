import CoreGraphics
import Foundation
import PDFKit
import Vision

public enum TextRecognizer {
    public static func text(image: URL, languages: [String]? = nil, accurate: Bool = true,
                            progress: (Double) -> Void = { _ in },
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> String {
        try VisionIO.typed("Could not recognize text in this image.") {
            try VisionIO.check(isCancelled)
            progress(0)
            let result = try recognize(VisionIO.image(image), languages: languages, accurate: accurate, isCancelled: isCancelled)
            progress(1)
            return result
        }
    }

    public static func text(pdf: URL, progress: (Double) -> Void = { _ in },
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> String {
        try VisionIO.typed("Could not extract text from this PDF.") {
            try VisionIO.check(isCancelled)
            let document = try VisionIO.pdf(pdf)
            progress(0)
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try VisionIO.check(isCancelled)
                let text: String = try autoreleasepool {
                    guard let page = document.page(at: index) else { throw PowerError.failed("Could not read PDF page \(index + 1).") }
                    let embedded = page.string ?? ""
                    if !needsOCR(page, embedded: embedded) { return embedded }
                    let recognized = try recognize(VisionIO.render(page, dpi: 200), languages: nil, accurate: true, isCancelled: isCancelled)
                    let caption = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
                    if caption.isEmpty || recognized.contains(caption) { return recognized }
                    // Preserve exact embedded captions even if OCR misses or reformats them.
                    return [recognized, embedded].filter { !$0.isEmpty }.joined(separator: "\n")
                }
                pages.append(text)
                progress(Double(index + 1) / Double(document.pageCount))
            }
            try VisionIO.check(isCancelled)
            return pages.joined(separator: "\n\n")
        }
    }

    static func needsOCR(_ page: PDFPage, embedded: String) -> Bool {
        if embedded.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 { return true }
        guard let ref = page.pageRef, var dictionary = ref.dictionary else { return true }
        // Resources may be inherited from a parent in the page tree.
        var resources: CGPDFDictionaryRef?
        for _ in 0..<16 {
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources) { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent), let parent else { break }
            dictionary = parent
        }
        guard let resources else { return false }
        let box = page.bounds(for: .cropBox)
        var remaining = 512
        return hasSubstantialRaster(resources, pageArea: Double(box.width * box.height), depth: 0, remaining: &remaining)
    }

    /// Conservative metadata check: high-resolution logos may also request OCR.
    /// Never decode image streams merely to decide whether a page needs recognition.
    private static func hasSubstantialRaster(_ resources: CGPDFDictionaryRef, pageArea: Double, depth: Int, remaining: inout Int) -> Bool {
        guard depth < 4 else { return true }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            remaining -= 1
            if remaining < 0 { found = true; return false }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            if String(cString: subtype) == "Image" {
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
                   width >= 100, height >= 100, Double(width) * Double(height) >= pageArea * 0.25 { found = true }
            } else if String(cString: subtype) == "Form" {
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    found = hasSubstantialRaster(nested, pageArea: pageArea, depth: depth + 1, remaining: &remaining)
                }
            }
            return !found
        }, nil)
        return found
    }

    private static func recognize(_ image: CGImage, languages: [String]?, accurate: Bool,
                                  isCancelled: @escaping @Sendable () -> Bool) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        if let languages {
            let supported = try request.supportedRecognitionLanguages()
            guard !languages.isEmpty, languages.allSatisfy({ supported.contains($0) }) else {
                throw PowerError.badInput("Choose OCR languages supported by this Mac: \(supported.joined(separator: ", ")).")
            }
            request.recognitionLanguages = languages
        } else { request.automaticallyDetectsLanguage = true }
        try VisionIO.perform(request, handler: VNImageRequestHandler(cgImage: image), isCancelled: isCancelled)
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
