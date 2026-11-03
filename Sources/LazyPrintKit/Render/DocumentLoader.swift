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
        throw PrintError.unreadable(DocumentText.notSupported)
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
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0,
              let size = Self.size(of: source) else {
            throw PrintError.unreadable(DocumentText.notSupported)
        }
        let loaded = LoadedDocument(name: url.lastPathComponent, kind: .photo, pages: [size])
        return OpenedDocument(loaded: loaded, url: url, source: .picture(source))
    }

    /// The first frame as it is shown, in points: by its own density when that is 72 or more, else as 300 dpi.
    private static func size(of source: CGImageSource) -> LayoutSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        func dpi(_ key: CFString) -> Double {
            let stated = (properties[key] as? NSNumber)?.doubleValue ?? 0
            return stated >= lowestDpi ? stated : assumedDpi
        }
        let stored = LayoutSize(width: width * 72 / dpi(kCGImagePropertyDPIWidth), height: height * 72 / dpi(kCGImagePropertyDPIHeight))
        // Orientations 5 to 8 turn the picture a quarter.
        return orientation(of: source) >= 5 ? LayoutSize(width: stored.height, height: stored.width) : stored
    }

    private static func orientation(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }
}
