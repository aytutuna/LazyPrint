import Foundation

// Twin of windows/LazyPrint.Core/PrintError.cs: what goes wrong when printing, thrown across modules.

/// Why a print or a conversation with a printer failed; `errorDescription` is for the user.
public enum PrintError: LocalizedError, Equatable, Sendable {
    /// An answer that is not IPP, or is cut short.
    case badResponse
    case unreachable(name: String, reason: String)
    /// The printer stopped answering after it had the job, which it may still print; `PrintText.lostContactTitle` names it.
    case lostContact(name: String)
    /// The printer answered with an IPP status that is an error.
    case refused(status: UInt16, detail: String)
    case needsDriver
    case busy
    case certificateChanged
    case needsSignIn
    /// A sheet was drawn with the wrong line length for its raster header (a bug, not the printer's doing).
    case badRaster(line: Int, length: Int, expected: Int)
    /// A file that can't be printed; the sentence says why (`DocumentText`).
    case unreadable(String)
    case noPrinter

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "The printer's answer could not be read"
        case .unreachable(let name, let reason): return "Can't reach \(name): \(reason)"
        case .lostContact: return PrintText.lostContactMessage
        case .refused(let status, let detail):
            return detail.isEmpty ? String(format: "The printer refused the job (0x%04X)", Int(status)) : detail
        case .needsDriver: return "This printer needs its driver"
        case .busy: return "The printer is busy"
        case .certificateChanged: return "The printer's certificate has changed"
        case .needsSignIn: return "This printer asks for a sign-in, which Lazy Print can't do yet"
        case .badRaster: return "A page could not be prepared for the printer"
        case .unreadable(let sentence): return sentence
        case .noPrinter: return PrintText.noPrinterMessage
        }
    }
}
