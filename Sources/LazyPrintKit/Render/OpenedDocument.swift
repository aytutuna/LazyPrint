import CoreGraphics
import Foundation
import ImageIO

/// A document opened for drawing, kept beside its LoadedDocument so SourcePage.document indexes both.
public struct OpenedDocument: @unchecked Sendable {
    public var loaded: LoadedDocument
    public var url: URL
    public var source: Source
    public let drawing = DrawingLock()

    public enum Source {
        case pdf(CGPDFDocument)
        case picture(CGImageSource)
    }

    public init(loaded: LoadedDocument, url: URL, source: Source) {
        self.loaded = loaded
        self.url = url
        self.source = source
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
