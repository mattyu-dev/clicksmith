import Foundation

private let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif", "jp2"]

// MARK: - Read QR / barcodes

struct ReadCodesAction: PowerAction {
    let descriptor = ActionDescriptor(id: "qr.read", title: "Read QR Code / Barcode", symbol: "qrcode.viewfinder", group: .qr,
                                      summary: "Finds codes in images and PDFs. Copies the content. Checks links for phishing.",
                                      extensions: imageExts.union(["pdf"]), isLongRunning: true)

    func run(_ c: ActionContext) async throws -> ActionResult {
        var lines: [String] = [], summaries: [String] = []
        for (i, u) in c.inputs.enumerated() {
            try c.checkCancelled()
            await c.progress.update(done: i, total: c.inputs.count, current: u.lastPathComponent)
            let codes = u.pathExtension.lowercased() == "pdf"
                ? try CodeReader.read(pdf: u, isCancelled: c.isCancelled)
                : try CodeReader.read(image: u, isCancelled: c.isCancelled)
            for code in codes {
                let parsed = CodeReader.parse(code.payloadString)
                let (copy, summary) = Self.describe(parsed)
                // Copy the full payload (mailto subject, SMS body…). Only Wi-Fi copies the password: the raw WIFI: string is useless.
                if case .wifi = parsed { lines.append(copy) } else { lines.append(code.payloadString) }
                summaries.append(summary)
            }
        }
        guard !lines.isEmpty else { throw PowerError.badInput("No QR code or barcode found.") }
        await c.environment.setClipboard(lines.joined(separator: "\n"))
        let msg = summaries.joined(separator: "\n")
        await c.environment.notify(title: lines.count == 1 ? "Code copied" : "\(lines.count) codes copied", body: msg)
        return ActionResult(message: msg)
    }

    /// What to copy and what to tell the user. Never opens anything by itself.
    static func describe(_ p: QRPayload) -> (copy: String, summary: String) {
        switch p {
        case .url(let u):
            let risk = CodeReader.assess(u)
            let tag: String
            switch risk.level {
            case .safe: tag = "Link"
            case .caution: tag = "⚠️ Careful: " + risk.reasons.joined(separator: "; ")
            case .danger: tag = "⛔️ Looks dangerous: " + risk.reasons.joined(separator: "; ")
            }
            return (u.absoluteString, "\(tag) — \(u.absoluteString)")
        case .wifi(let ssid, let password, _, _):
            return (password ?? ssid, "Wi-Fi “\(ssid)” — password copied")
        case .contact(_, let name): return (Self.raw(p), "Contact \(name ?? "")")
        case .event(_, let title, _): return (Self.raw(p), "Event \(title ?? "")")
        case .email(let to, _, _): return (to, "Email \(to)")
        case .phone(let n): return (n, "Phone \(n)")
        case .sms(let n, _): return (n, "SMS \(n)")
        case .geo(let lat, let lon): return ("\(lat),\(lon)", "Location \(lat), \(lon)")
        case .text(let t): return (t, "Text: \(t.prefix(80))")
        }
    }

    static func raw(_ p: QRPayload) -> String {
        switch p {
        case .contact(let v, _): v
        case .event(let ics, _, _): ics
        default: ""
        }
    }
}

// MARK: - Make QR

struct MakeQRFromClipboardAction: PowerAction {
    let descriptor = ActionDescriptor(id: "qr.makeFromClipboard", title: "Create QR Code from Clipboard", symbol: "qrcode", group: .qr,
                                      summary: "Saves a QR code PNG of the copied text or link here.", contexts: [.container], minCount: 0)

    func run(_ c: ActionContext) async throws -> ActionResult {
        try c.checkCancelled()
        // Check a trimmed copy, but encode exactly what was copied.
        guard let text = await c.environment.readClipboard().string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PowerError.badInput("Copy some text or a link first.")
        }
        let raw: String = {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Name by kind, never by secret content (Wi-Fi passwords, tokens).
            switch CodeReader.parse(t) {
            case .wifi(let ssid, _, _, _): return "QR Wi-Fi \(ssid.prefix(24))".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            case .url(let u): if let host = u.host { return "QR \(host)" }
            case .contact(_, let name): return "QR Contact \(name ?? "")".trimmingCharacters(in: .whitespaces)
            case .event: return "QR Event"
            case .email: return "QR Email"
            case .phone, .sms: return "QR Phone"
            case .geo: return "QR Location"
            case .text: break
            }
            return "QR " + String(t.prefix(24)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        }()
        // Any part may come from the code (vCard name, SSID): make it a safe, short file name.
        let cleaned = raw.map { "/:\n\r\t".contains($0) || $0.isNewline ? "-" : $0 }
        let base = Self.fit(String(cleaned), bytes: 120).trimmingCharacters(in: .whitespaces)
        let out = try c.files.produce(base: base.isEmpty ? "QR" : base, ext: "png", in: NewFileAction.folder(c)) { try CodeWriter.qrPNG(text, output: $0, isCancelled: c.isCancelled) }
        var r = ActionResult(created: [out], message: "Created \(out.lastPathComponent).")
        r.revealCreated = true
        return r
    }
}

extension MakeQRFromClipboardAction {
    /// Longest prefix (whole characters) within `bytes` UTF-8 bytes; leaves room for " 99.png" (name limit 255).
    static func fit(_ s: String, bytes: Int) -> String {
        var out = "", n = 0
        for ch in s {
            let b = String(ch).utf8.count
            if n + b > bytes { break }
            out.append(ch); n += b
        }
        return out
    }
}

// MARK: - OCR

struct CopyTextFromImageAction: PowerAction {
    let descriptor = ActionDescriptor(id: "text.ocr", title: "Copy Text from Image", symbol: "text.viewfinder", group: .copy,
                                      summary: "Recognizes text in images and scanned PDFs, on this Mac.", extensions: imageExts.union(["pdf"]),
                                      isLongRunning: true)

    func run(_ c: ActionContext) async throws -> ActionResult {
        var parts: [String] = []
        for (i, u) in c.inputs.enumerated() {
            try c.checkCancelled()
            await c.progress.update(done: i, total: c.inputs.count, current: u.lastPathComponent)
            let t = u.pathExtension.lowercased() == "pdf"
                ? try TextRecognizer.text(pdf: u, isCancelled: c.isCancelled)
                : try TextRecognizer.text(image: u, isCancelled: c.isCancelled)
            if !t.isEmpty { parts.append(t) }
        }
        guard !parts.isEmpty else { throw PowerError.badInput("No text found.") }
        let text = parts.joined(separator: "\n\n")
        await c.environment.setClipboard(text)
        return ActionResult(message: "Copied \(text.count) characters.")
    }
}

// MARK: - Background removal

struct RemoveBackgroundAction: PerFileAction {
    let descriptor = ActionDescriptor(id: "image.removeBackground", title: "Remove Background", symbol: "person.crop.rectangle.badge.plus",
                                      group: .image, summary: "Cuts out the subject into a transparent PNG, on this Mac.",
                                      extensions: imageExts, isLongRunning: true)
    func process(_ url: URL, _ c: ActionContext) async throws -> [URL] {
        [try c.files.produce(from: url, ext: "png", suffix: "cutout") { try BackgroundRemover.removeBackground(url, output: $0, isCancelled: c.isCancelled) }]
    }
}
