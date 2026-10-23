import AppKit
import ImageIO
import PDFKit

@main
@MainActor
enum FileConverterTests {
    static func main() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-convert-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var cases = 0
        func check(_ ok: Bool, _ what: String) {
            precondition(ok, "failed: \(what)")
            cases += 1
        }

        // What each file is
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/photo.HEIC")) == .image, "heic is an image")
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/scan.pdf")) == .pdf, "pdf")
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/letter.docx")) == .document, "docx")
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/page.htm")) == .document, "htm")
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/song.mp3")) == nil, "mp3 not yet")
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/logo.svg")) == nil, "svg can't be read")
        check(FileConverter.kind(of: URL(fileURLWithPath: "/a/README")) == nil, "no extension")

        // Offered formats never include the file's own format
        let forJPEG = FileConverter.formats(for: URL(fileURLWithPath: "/a/photo.jpeg")).map(\.ext)
        check(!forJPEG.contains("jpg") && forJPEG.contains("png") && forJPEG.contains("pdf"), "jpeg offers")
        check(forJPEG.first == "png", "most common first")
        let forHTM = FileConverter.formats(for: URL(fileURLWithPath: "/a/page.htm")).map(\.ext)
        check(!forHTM.contains("html") && forHTM.contains("docx"), "htm offers")
        check(FileConverter.formats(for: URL(fileURLWithPath: "/a/scan.pdf")).map(\.ext) == ["png", "jpg", "txt"], "pdf offers")
        check(FileConverter.formats(for: URL(fileURLWithPath: "/a/song.mp3")).isEmpty, "mp3 offers nothing")

        // Names never overwrite an existing file
        let taken = folder.appendingPathComponent("name.txt")
        try! Data().write(to: taken)
        check(FileConverter.availableURL(in: folder, base: "name", ext: "txt").lastPathComponent == "name 2.txt", "name 2")
        check(FileConverter.availableURL(in: folder, base: "name", ext: "png").lastPathComponent == "name.png", "free name")

        // Image: a 40×20 PNG, left half red, right half see-through
        let png = folder.appendingPathComponent("dot.png")
        writeTestPNG(to: png)
        for format in FileConverter.formats(for: png) {
            let out = try! await FileConverter.convert(png, to: format, in: folder)
            check(FileManager.default.fileExists(atPath: out.path) && out.pathExtension == format.ext, "png → \(format.ext)")
            if format.ext == "pdf" {
                check(PDFDocument(url: out)?.pageCount == 1, "image pdf has one page")
            } else {
                let source = CGImageSourceCreateWithURL(out as CFURL, nil)
                let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                check(image?.width == 40 && image?.height == 20, "\(format.ext) keeps the size")
            }
        }
        // JPEG puts the see-through half on white
        let jpg = folder.appendingPathComponent("dot.jpg")
        check(pixel(of: jpg, x: 35, y: 10).map { $0.r > 240 && $0.g > 240 && $0.b > 240 } == true, "jpeg on white")
        check(pixel(of: jpg, x: 5, y: 10).map { $0.r > 200 && $0.g < 60 } == true, "jpeg keeps red")
        // Converting twice gives a second name, never overwrites
        let again = try! await FileConverter.convert(png, to: .init(ext: "jpg", label: "JPEG"), in: folder)
        check(again.lastPathComponent == "dot 2.jpg", "second jpeg is dot 2.jpg")

        // Document: an RTF with bold text, long enough for several PDF pages
        let rtf = folder.appendingPathComponent("letter.rtf")
        let body = NSMutableAttributedString(string: "Hello Mochi\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        body.append(NSAttributedString(string: String(repeating: "Line of text for the converter.\n", count: 150),
                                       attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        try! body.data(from: NSRange(location: 0, length: body.length),
                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)
        for format in FileConverter.formats(for: rtf) {
            let out = try! await FileConverter.convert(rtf, to: format, in: folder)
            if format.ext == "pdf" {
                let pdf = PDFDocument(url: out)
                check((pdf?.pageCount ?? 0) >= 3, "long text gives several pages")
                check(pdf?.string?.contains("Hello Mochi") == true, "pdf keeps the text")
            } else {
                let back = try? NSAttributedString(url: out, options: [:], documentAttributes: nil)
                check(back?.string.hasPrefix("Hello Mochi") == true, "rtf → \(format.ext) keeps the text")
            }
        }

        // PDF: the 3+ page PDF just made, to images (a folder) and to text
        let pdf = folder.appendingPathComponent("letter.pdf")
        let pagesCount = PDFDocument(url: pdf)!.pageCount
        let pages = try! await FileConverter.convert(pdf, to: .init(ext: "png", label: "PNG"), in: folder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pages.path))?.sorted() ?? []
        check(pages.lastPathComponent == "letter pages" && files.count == pagesCount, "one png per page")
        check(files.first == "letter-1.png" || files.first == "letter-01.png", "pages are numbered")
        let text = try! await FileConverter.convert(pdf, to: .init(ext: "txt", label: "TXT"), in: folder)
        check((try? String(contentsOf: text, encoding: .utf8))?.contains("Hello Mochi") == true, "pdf → txt")
        // A one-page PDF gives a single image, not a folder
        let onePage = folder.appendingPathComponent("dot.pdf")
        let single = try! await FileConverter.convert(onePage, to: .init(ext: "jpg", label: "JPEG"), in: folder)
        check(single.lastPathComponent == "dot 3.jpg", "one page → one image")

        // Errors
        let broken = folder.appendingPathComponent("broken.png")
        try! Data("not an image".utf8).write(to: broken)
        do { _ = try await FileConverter.convert(broken, to: .init(ext: "jpg", label: "JPEG"), in: folder); check(false, "broken") }
        catch { check(error as? ConvertError == .unreadable, "broken image is unreadable") }
        do { _ = try await FileConverter.convert(URL(fileURLWithPath: "/a/song.mp3"), to: .init(ext: "wav", label: "WAV"), in: folder); check(false, "mp3") }
        catch { check(error as? ConvertError == .unsupported, "mp3 is unsupported") }

        print("File converter: \(cases) cases passed")
    }

    static func writeTestPNG(to url: URL) {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func pixel(of url: URL, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (data[i], data[i + 1], data[i + 2])
    }
}
