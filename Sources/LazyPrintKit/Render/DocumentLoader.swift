import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// Twin of windows/LazyPrint.App/Services/DocumentLoader.cs: opens PDFs, pictures and plain text for drawing.

public final class DocumentLoader: DocumentLoading {
    /// The density a picture is sized by when it states none worth believing (below 72 dpi).
    private static let assumedDpi: Double = 300
    private static let lowestDpi: Double = 72
    private static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv"]

    public init() {}

    public func load(_ url: URL) throws -> OpenedDocument {
        try load(url, password: "")
    }

    public func load(_ url: URL, password: String) throws -> OpenedDocument {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PrintError.unreadable(DocumentText.unreadable)
        }
        // The type comes from the name first: ImageIO also reads PDF and makes a source for almost any file.
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true { return try loadPDF(url, password: password) }
        if type?.conforms(to: .image) == true { return try loadPicture(url) }
        if type?.conforms(to: .plainText) == true || Self.textExtensions.contains(url.pathExtension.lowercased()) {
            return try loadText(url)
        }
        // A name that says nothing (Open In and downloads often have none) is no reason to refuse: the content tells.
        if Self.start(of: url).range(of: Data("%PDF-".utf8)) != nil { return try loadPDF(url, password: password) }
        do {
            return try loadPicture(url)
        } catch {
            if Self.looksLikeText(url) { return try loadText(url) }
            throw error
        }
    }

    /// The first 1024 bytes, where the spec lets a PDF's "%PDF-" header sit.
    private static func start(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 1024)) ?? Data()
    }

    /// No NUL byte in the start: not a PDF or a picture, but it could be read as text.
    private static func looksLikeText(_ url: URL) -> Bool {
        let start = Self.start(of: url)
        return !start.isEmpty && !start.contains(0)
    }

    public func originalFile(_ document: OpenedDocument) -> URL? {
        switch document.source {
        case .pdf:
            // The pages of a text file are drawn here, not the file's own.
            return document.loaded.kind == .imposed ? nil : document.url
        case .picture(let source):
            guard UTType(filenameExtension: document.url.pathExtension)?.conforms(to: .jpeg) == true else { return nil }
            return Self.orientation(of: source) <= 1 ? document.url : nil
        }
    }

    private func loadPDF(_ url: URL, password: String) throws -> OpenedDocument {
        guard let pdf = CGPDFDocument(url as CFURL) else { throw PrintError.unreadable(DocumentText.unreadable) }
        let encrypted = pdf.isEncrypted
        // Fails for a document with a user password when none is given; an owner password alone opens with the empty one.
        if encrypted { _ = pdf.unlockWithPassword(password) }
        guard pdf.isUnlocked else { throw PrintError.unreadable(DocumentText.lockedPdf) }
        guard pdf.numberOfPages > 0 else { throw PrintError.unreadable(DocumentText.noPages) }

        var pages: [LayoutSize] = []
        for number in 1...pdf.numberOfPages {
            guard let page = pdf.page(at: number) else { throw PrintError.unreadable(DocumentText.unreadable) }
            let box = page.getBoxRect(.cropBox)
            let turn = ((Int(page.rotationAngle) % 360) + 360) % 360
            let sideways = turn == 90 || turn == 270
            pages.append(LayoutSize(width: sideways ? box.height : box.width, height: sideways ? box.width : box.height))
        }
        let loaded = LoadedDocument(name: url.lastPathComponent, kind: .pdf(encrypted: encrypted), pages: pages)
        let annotated = PDFDocument(url: url)
        if annotated?.isLocked == true { _ = annotated?.unlock(withPassword: password) }
        return OpenedDocument(loaded: loaded, url: url, source: .pdf(pdf), annotated: annotated)
    }

    /// The text laid out in pages and drawn into a PDF of its own in memory, which the renderer then draws like any PDF.
    private func loadText(_ url: URL) throws -> OpenedDocument {
        guard let data = try? Data(contentsOf: url) else { throw PrintError.unreadable(DocumentText.unreadable) }
        // The usual paper where the user lives: the printer's paper is not known yet, and the page is fitted to it later.
        let size = PaperSizes.points(PaperSizes.defaultForRegion(Locale.current.region?.identifier))
            ?? LayoutSize(width: 612, height: 792)
        let pages = TextPages.paginate(TextPages.decode(data), page: size)
        guard !pages.isEmpty else { throw PrintError.unreadable(DocumentText.noText) }
        guard let pdf = Self.drawText(pages, size: size) else { throw PrintError.unreadable(DocumentText.unreadable) }
        // Not a PDF to send as it is: the file's own bytes are text.
        let loaded = LoadedDocument(name: url.lastPathComponent, kind: .imposed, pages: pages.map { _ in size })
        return OpenedDocument(loaded: loaded, url: url, source: .pdf(pdf))
    }

    private static func drawText(_ pages: [[String]], size: LayoutSize) -> CGPDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        let font = CTFontCreateWithName("Menlo" as CFString, TextPages.fontSize, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)]
        let ascent = CTFontGetAscent(font)
        for lines in pages {
            context.beginPDFPage(nil)
            for (row, text) in lines.enumerated() where !text.isEmpty {
                guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { continue }
                context.textPosition = CGPoint(x: TextPages.margin,
                                               y: size.height - TextPages.margin - Double(row) * TextPages.lineHeight - ascent)
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGPDFDocument(provider)
    }

    private func loadPicture(_ url: URL) throws -> OpenedDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source), CGImageSourceGetCount(source) > 0 else {
            throw PrintError.unreadable(DocumentText.notSupported)
        }
        // A TIFF is a page to a frame (faxes and scans); any other picture is its first frame.
        let frames = (type as String) == UTType.tiff.identifier ? CGImageSourceGetCount(source) : 1
        var pages: [LayoutSize] = []
        for index in 0..<frames {
            guard let size = Self.size(of: source, at: index) else { throw PrintError.unreadable(DocumentText.notSupported) }
            pages.append(size)
        }
        let loaded = LoadedDocument(name: url.lastPathComponent, kind: .photo, pages: pages)
        return OpenedDocument(loaded: loaded, url: url, source: .picture(source))
    }

    /// A frame as it is shown, in points: by its own density when that is 72 or more, else as 300 dpi.
    private static func size(of source: CGImageSource, at index: Int) -> LayoutSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        func dpi(_ key: CFString) -> Double {
            let stated = (properties[key] as? NSNumber)?.doubleValue ?? 0
            return stated >= lowestDpi ? stated : assumedDpi
        }
        let stored = LayoutSize(width: width * 72 / dpi(kCGImagePropertyDPIWidth), height: height * 72 / dpi(kCGImagePropertyDPIHeight))
        // Orientations 5 to 8 turn the picture a quarter.
        return orientation(of: source, at: index) >= 5 ? LayoutSize(width: stored.height, height: stored.width) : stored
    }

    private static func orientation(of source: CGImageSource, at index: Int = 0) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }
}
