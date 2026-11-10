import Vision

/// Which layout the on-screen keyboard shows, read from the screen: the pinyin keyboard labels its space bar
/// (a small 拼, or 空格) and may show 选定 on its return key; the English one shows nothing there.
enum KeyboardLayout: Equatable {
    case english, pinyin, none

    static func read(_ jpeg: Data) async -> KeyboardLayout {
        guard let image = Vision.image(jpeg), let rows = bottomRows(image) else { return .none }
        let words = await text(in: rows)
        if words.contains(where: { $0.contains("拼") || $0.contains("空格") || $0.contains("选定") }) { return .pinyin }
        return words.contains("123") ? .english : .none  // both layouts have the 123 key
    }

    /// The keyboard's bottom rows, scaled up to ~2000 px wide: the space bar's 拼 is a tiny grey glyph that
    /// text recognition misses at screen size (2026-11-03: missed at 718 px, found at 3x).
    private static func bottomRows(_ image: CGImage) -> CGImage? {
        let h = Double(image.height), w = Double(image.width)
        guard let crop = image.cropping(to: CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.22)) else { return nil }
        let scale = max(1, 2000 / w)
        let size = CGSize(width: Double(crop.width) * scale, height: Double(crop.height) * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private static func text(in image: CGImage) async -> [String] {
        await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                done.resume(returning: (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string })
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { done.resume(returning: []) }
            }
        }
    }
}

/// On-device targets for predicted steps. Exact, unique whole-label matches only; no remote service.
enum ScreenText {
    struct Label {
        let text: String
        /// Top-left origin, in screen fractions (Vision observations use bottom-left origin).
        let box: CGRect
        let confidence: Float
    }

    static func point(for target: String, labels: [Label]) -> CGPoint? {
        let wanted = normalized(target)
        guard !wanted.isEmpty, wanted.count <= 64 else { return nil }
        let matches = labels.filter {
            $0.confidence >= 0.6 && normalized($0.text) == wanted
                && $0.box.minX >= 0 && $0.box.minY >= Vision.topMask
                && $0.box.maxX <= 1 && $0.box.maxY <= 1 && $0.box.width > 0 && $0.box.height > 0
        }
        guard matches.count == 1, let label = matches.first else { return nil }
        return CGPoint(x: label.box.midX, y: label.box.midY)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }

    static func locate(_ target: String, in jpeg: Data) async -> CGPoint? {
        guard let image = Vision.image(jpeg) else { return nil }
        let labels: [Label] = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = false
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let labels = (request.results ?? []).compactMap { observation -> Label? in
                        guard let text = observation.topCandidates(1).first else { return nil }
                        let b = observation.boundingBox
                        return Label(text: text.string,
                                     box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                                     confidence: text.confidence)
                    }
                    done.resume(returning: labels)
                } catch { done.resume(returning: []) }
            }
        }
        return point(for: target, labels: labels)
    }
}
