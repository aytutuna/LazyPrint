import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Twin of windows/LazyPrint.App/Services/DocumentLoader.cs: opens PDFs and pictures for drawing.

public final class DocumentLoader: DocumentLoading {
    /// The density a picture is sized by when it states none worth believing (below 72 dpi).
    private static let assumedDpi: Double = 300
    private static let lowestDpi: Double = 72

    public init() {}

    public func load(_ url: URL) throws -> OpenedDocument {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PrintError.unreadable(DocumentText.unreadable)
        }
        // The type comes from the name first: ImageIO also reads PDF and makes a source for almost any file.
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true { return try loadPDF(url) }
        if type?.conforms(to: .image) == true { return try loadPicture(url) }
        // A name that says nothing (Open In and downloads often have none) is no reason to refuse: the content tells.
        if Self.startsWithPDF(url) { return try loadPDF(url) }
        return try loadPicture(url)
    }

    /// "%PDF-" in the first 1024 bytes, where the spec lets the header sit.
    private static func startsWithPDF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: 1024) else { return false }
        return start.range(of: Data("%PDF-".utf8)) != nil
    }

    public func originalFile(_ document: OpenedDocument) -> URL? {
        switch document.source {
        case .pdf:
            return document.url
        case .picture(let source):
            guard UTType(filenameExtension: document.url.pathExtension)?.conforms(to: .jpeg) == true else { return nil }
            return Self.orientation(of: source) <= 1 ? document.url : nil
        }
    }

    private func loadPDF(_ url: URL) throws -> OpenedDocument {
        guard let pdf = CGPDFDocument(url as CFURL) else { throw PrintError.unreadable(DocumentText.unreadable) }
        let encrypted = pdf.isEncrypted
        // Fails for a document with a user password; an owner password alone opens with the empty one.
        if encrypted { _ = pdf.unlockWithPassword("") }
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
        return OpenedDocument(loaded: loaded, url: url, source: .pdf(pdf))
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
