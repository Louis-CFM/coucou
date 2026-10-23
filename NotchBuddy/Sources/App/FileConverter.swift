import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// What kind of dropped file Mochi can convert.
enum ConvertKind: Sendable {
    case image, pdf, document
}

/// One format the dropped file can become, shown as a button.
struct ConvertFormat: Hashable, Identifiable, Sendable {
    let ext: String     // extension written, e.g. "jpg"
    let label: String   // button title, e.g. "JPEG"
    var id: String { ext }
}

enum ConvertError: Error, Equatable {
    case unsupported    // not a file Mochi knows how to convert
    case unreadable     // the file is damaged or not what its extension says
    case locked         // a PDF with a password
    case writeFailed    // the new file could not be written
}

/// Converts images, PDFs and documents with what macOS already has: ImageIO, PDFKit and
/// AppKit's text system. No third-party code and no network. The result is always a new
/// file next to the others; the original is never changed.
enum FileConverter {

    // MARK: - What the file is

    static func kind(of url: URL) -> ConvertKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if documentInputs.contains(ext) { return .document }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image),
           readableImageTypes.contains(type) {
            return .image
        }
        return nil
    }

    /// The formats offered for this file, most common first, without the format it already is.
    static func formats(for url: URL) -> [ConvertFormat] {
        let ext = url.pathExtension.lowercased()
        switch kind(of: url) {
        case .image:
            let current = UTType(filenameExtension: ext)
            return imageOutputs.filter { format in
                guard let type = imageType(for: format) else { return true }  // PDF: always possible
                guard writableImageTypes.contains(type) else { return false } // this Mac can't write it
                return current.map { !$0.conforms(to: type) } ?? true        // not what it already is
            }
        case .pdf:
            return pdfOutputs
        case .document:
            let current = ext == "htm" ? "html" : ext
            return documentOutputs.filter { $0.ext != current }
        case nil:
            return []
        }
    }

    // MARK: - Converting

    /// Writes `input` as `format` into `folder` and returns the new file. A PDF of several
    /// pages turned into images gives a folder with one image per page.
    @MainActor
    static func convert(_ input: URL, to format: ConvertFormat, in folder: URL) async throws -> URL {
        guard let kind = kind(of: input) else { throw ConvertError.unsupported }
        switch kind {
        case .document:
            // AppKit reads HTML through WebKit, which only works on the main thread.
            return try convertDocument(input, to: format, in: folder)
        case .image, .pdf:
            // Big photos and long PDFs take a moment: keep the island smooth.
            return try await Task.detached(priority: .userInitiated) {
                kind == .image
                    ? try convertImage(input, to: format, in: folder)
                    : try convertPDF(input, to: format, in: folder)
            }.value
        }
    }

    /// `photo.jpg`, or `photo 2.jpg` if that name is taken. With no extension, a folder name.
    static func availableURL(in folder: URL, base: String, ext: String?) -> URL {
        func candidate(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            guard let ext else { return folder.appendingPathComponent(name, isDirectory: true) }
            return folder.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var n = 1
        while FileManager.default.fileExists(atPath: candidate(n).path) { n += 1 }
        return candidate(n)
    }

    // MARK: - Lists

    private static let imageOutputs: [ConvertFormat] = [
        .init(ext: "jpg", label: "JPEG"),
        .init(ext: "png", label: "PNG"),
        .init(ext: "heic", label: "HEIC"),
        .init(ext: "pdf", label: "PDF"),
        .init(ext: "avif", label: "AVIF"),
        .init(ext: "tiff", label: "TIFF"),
        .init(ext: "gif", label: "GIF"),
        .init(ext: "bmp", label: "BMP"),
    ]

    private static let pdfOutputs: [ConvertFormat] = [
        .init(ext: "png", label: "PNG"),
        .init(ext: "jpg", label: "JPEG"),
        .init(ext: "txt", label: "TXT"),
    ]

    private static let documentOutputs: [ConvertFormat] = [
        .init(ext: "pdf", label: "PDF"),
        .init(ext: "docx", label: "DOCX"),
        .init(ext: "txt", label: "TXT"),
        .init(ext: "rtf", label: "RTF"),
        .init(ext: "html", label: "HTML"),
        .init(ext: "odt", label: "ODT"),
    ]

    private static let documentInputs: Set<String> = [
        "txt", "rtf", "html", "htm", "doc", "docx", "odt", "webarchive",
    ]

    private static let documentTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument,
    ]

    private static let readableImageTypes: Set<UTType> = Set(
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
    )

    private static let writableImageTypes: Set<UTType> = Set(
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
    )

    private static func imageType(for format: ConvertFormat) -> UTType? {
        format.ext == "pdf" ? nil : UTType(filenameExtension: format.ext)
    }

    // MARK: - Images

    private static func convertImage(_ input: URL, to format: ConvertFormat, in folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { throw ConvertError.unreadable }
        let output = availableURL(in: folder, base: baseName(of: input), ext: format.ext)

        if format.ext == "pdf" {
            guard let image = uprightImage(from: source) else { throw ConvertError.unreadable }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
            try writeImagePDF(image, dpi: dpi > 0 ? dpi : 72, to: output)
            return output
        }

        guard let type = imageType(for: format),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil)
        else { throw ConvertError.writeFailed }
        let quality: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]

        // JPEG and BMP have no transparency: put see-through parts on white, not black.
        if ["jpg", "bmp"].contains(format.ext),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil), hasAlpha(image),
           let flat = flattenedOnWhite(image) {
            var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            properties.merge(quality) { _, new in new }
            CGImageDestinationAddImage(destination, flat, properties as CFDictionary)
        } else {
            // Copies the picture with its metadata, orientation included.
            CGImageDestinationAddImageFromSource(destination, source, 0, quality as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ConvertError.writeFailed
        }
        return output
    }

    /// The first image, turned the right way up (photos often store their rotation apart).
    private static func uprightImage(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(.white)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func writeImagePDF(_ image: CGImage, dpi: CGFloat, to output: URL) throws {
        var page = CGRect(x: 0, y: 0, width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else { throw ConvertError.writeFailed }
        context.beginPDFPage(nil)
        context.draw(image, in: page)
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - PDF

    private static func convertPDF(_ input: URL, to format: ConvertFormat, in folder: URL) throws -> URL {
        guard let document = PDFDocument(url: input) else { throw ConvertError.unreadable }
        guard !document.isLocked else { throw ConvertError.locked }
        let base = baseName(of: input)

        if format.ext == "txt" {
            let output = availableURL(in: folder, base: base, ext: "txt")
            try write(Data((document.string ?? "").utf8), to: output)
            return output
        }

        guard let type = imageType(for: format) else { throw ConvertError.unsupported }
        let count = document.pageCount
        guard count > 0 else { throw ConvertError.unreadable }

        // One page: a single image. Several: a folder "Report pages" with Report-01.png, Report-02.png…
        let target = count == 1 ? folder : availableURL(in: folder, base: "\(base) pages", ext: nil)
        if count > 1 {
            do { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            catch { throw ConvertError.writeFailed }
        }
        let digits = String(count).count
        var single = target
        for index in 0..<count {
            guard let page = document.page(at: index), let image = render(page) else { throw ConvertError.unreadable }
            let output = count == 1
                ? availableURL(in: folder, base: base, ext: format.ext)
                : target.appendingPathComponent("\(base)-\(String(repeating: "0", count: digits - String(index + 1).count))\(index + 1)")
                    .appendingPathExtension(format.ext)
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil)
            else { throw ConvertError.writeFailed }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConvertError.writeFailed }
            single = output
        }
        return count == 1 ? single : target
    }

    /// A page as a sharp image (twice the PDF size, like a Retina screen), on white.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let turned = page.rotation % 180 != 0
        let size = CGSize(width: (turned ? bounds.height : bounds.width) * 2,
                          height: (turned ? bounds.width : bounds.height) * 2)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Documents

    @MainActor
    private static func convertDocument(_ input: URL, to format: ConvertFormat, in folder: URL) throws -> URL {
        let text: NSAttributedString
        do { text = try NSAttributedString(url: input, options: [:], documentAttributes: nil) }
        catch { throw ConvertError.unreadable }
        let output = availableURL(in: folder, base: baseName(of: input), ext: format.ext)

        switch format.ext {
        case "pdf":
            try writeTextPDF(text, to: output)
        case "txt":
            try write(Data(text.string.utf8), to: output)
        default:
            guard let type = documentTypes[format.ext] else { throw ConvertError.unsupported }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data: Data
            do { data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes) }
            catch { throw ConvertError.writeFailed }
            try write(data, to: output)
        }
        return output
    }

    /// Lays the text out on pages of the user's paper size (A4 or Letter) with 1-inch margins.
    @MainActor
    private static func writeTextPDF(_ text: NSAttributedString, to output: URL) throws {
        let paper = NSPrintInfo.shared.paperSize
        let margin: CGFloat = 72
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else { throw ConvertError.writeFailed }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let origin = CGPoint(x: margin, y: margin)
        var done = 0
        var pages = 0
        repeat {
            let container = NSTextContainer(size: CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin))
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)

            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: paper.height)   // AppKit text draws top-down
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()

            pages += 1
            if glyphs.length == 0 { break }   // nothing fits (or empty text): stop
            done = NSMaxRange(glyphs)
        } while done < layout.numberOfGlyphs && pages < 5000
        context.closePDF()
    }

    // MARK: - Helpers

    private static func baseName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch { throw ConvertError.writeFailed }
    }
}
