import Foundation

// Twin of windows/LazyPrint.Core/Ipp/DocumentFormats.cs: which document format a job goes in.

/// What is being printed, as far as the format is concerned: a PDF printed as it is, one photo printed whole on
/// paper of its own size, or sheets drawn by Lazy Print.
public enum DocumentKind: Equatable, Sendable {
    case pdf(encrypted: Bool)
    case photo
    case imposed
}

public enum DocumentFormats {
    public static let pdf = "application/pdf"
    public static let pwgRaster = "image/pwg-raster"
    public static let urf = "image/urf"
    public static let jpeg = "image/jpeg"

    /// The format a job goes in. A PDF goes as itself only when it is printed as it is (one page per side, every page
    /// once in order, fit or shrink to fit, no booklet, no manual duplex), and not encrypted. One photo goes as JPEG
    /// only when it is printed whole on paper of its own size. Everything else is sheets drawn by Lazy Print: PDF
    /// where the platform can write one (`canWritePDF`), else PWG raster, then URF. Nil when the printer takes none
    /// of them.
    public static func choose(supported: [String], kind: DocumentKind, canWritePDF: Bool) -> String? {
        func takes(_ format: String) -> Bool {
            supported.contains { $0.caseInsensitiveCompare(format) == .orderedSame }
        }

        if case .pdf(let encrypted) = kind, !encrypted, takes(pdf) { return pdf }
        if case .photo = kind, takes(jpeg) { return jpeg }
        if canWritePDF && takes(pdf) { return pdf }
        if takes(pwgRaster) { return pwgRaster }
        if takes(urf) { return urf }
        return nil
    }

    /// A job refused with document-format-not-supported, document-format-error or document-unprintable-error is sent
    /// once more as raster.
    public static func retriesAsRaster(_ status: UInt16) -> Bool {
        status == IppStatus.clientErrorDocumentFormatNotSupported.rawValue
            || status == IppStatus.clientErrorDocumentFormatError.rawValue
            || status == IppStatus.clientErrorDocumentUnprintableError.rawValue
    }
}
