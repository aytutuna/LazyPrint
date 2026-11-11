import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// A document opened for drawing, kept beside its LoadedDocument so SourcePage.document indexes both.
public struct OpenedDocument: @unchecked Sendable {
    public var loaded: LoadedDocument
    public var url: URL
    public var source: Source
    /// The same PDF in PDFKit, which draws the annotations and filled form fields that `CGContext.drawPDFPage` leaves out.
    public var annotated: PDFDocument?
    public let drawing = DrawingLock()
    /// The security-scoped access the file was opened under; it stops when the last copy of the document is gone.
    public var access: ScopedAccess?
    /// The text of a plain text file, which `TextPages` sets again when the paper changes.
    public var text: String?

    public enum Source {
        case pdf(CGPDFDocument)
        case picture(CGImageSource)
    }

    public init(loaded: LoadedDocument, url: URL, source: Source, annotated: PDFDocument? = nil) {
        self.loaded = loaded
        self.url = url
        self.source = source
        self.annotated = annotated
    }

    /// A page of the PDF as PDFKit has it, from 0.
    public func annotatedPage(_ index: Int) -> PDFPage? {
        annotated?.page(at: index)
    }
}

/// Taken while one placement of a document is drawn. A class box, so the copies of an OpenedDocument share it.
public final class DrawingLock: @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Security-scoped access to a file already started; it is stopped when this is released.
public final class ScopedAccess: @unchecked Sendable {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}
