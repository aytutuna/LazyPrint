import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppRequests.cs: the requests both platforms send, byte for byte.

/// The requests to a printer. Every one is version 2.0 with the operation group in a fixed order: charset utf-8,
/// language en, printer-uri, requesting-user-name, then the operation's own attributes. `userName` is the account
/// name, or "iPhone" on the iPhone, and is the same for Cancel-Job or printers refuse it. `downgraded` makes the
/// 1.1 request for a printer that does not speak 2.0.
public enum IppRequests {
    private static let nameLimit = 255

    public static func getPrinterAttributes(printerUri: String, userName: String, requestId: Int32 = 1) -> IppMessage {
        request(.getPrinterAttributes, printerUri, userName, requestId,
                [keywords("requested-attributes", "all", "media-col-database")])
    }

    public static func printJob(printerUri: String, userName: String, ticket: IppJobTicket, requestId: Int32 = 1) -> IppMessage {
        var job = [IppAttribute]()
        if ticket.copies > 1 { job.append(IppAttribute("copies", .integer(Int32(ticket.copies)))) }
        job.append(IppAttribute("sides", .keyword(ticket.sides)))
        job.append(IppAttribute("print-color-mode", .keyword(ticket.colorMode)))
        if let entry = ticket.media.entry {
            job.append(IppAttribute("media-col", .collection(entry)))
        } else {
            job.append(IppAttribute("media", .keyword(ticket.media.name)))
        }
        if let quality = ticket.quality { job.append(IppAttribute("print-quality", .enumValue(Int32(quality)))) }
        if let scaling = ticket.scaling { job.append(IppAttribute("print-scaling", .keyword(scaling))) }
        if ticket.collatedCopies {
            job.append(IppAttribute("multiple-document-handling", .keyword("separate-documents-collated-copies")))
        }

        var message = request(.printJob, printerUri, userName, requestId, [
            IppAttribute("job-name", .name(truncated(ticket.jobName))),
            IppAttribute("document-format", .mimeType(ticket.documentFormat)),
        ])
        message.groups.append(IppGroup(tag: IppTag.jobAttributes, attributes: job))
        return message
    }

    public static func getJobAttributes(printerUri: String, userName: String, jobId: Int, requestId: Int32 = 1) -> IppMessage {
        request(.getJobAttributes, printerUri, userName, requestId, [
            IppAttribute("job-id", .integer(Int32(jobId))),
            keywords("requested-attributes", "job-state", "job-state-reasons", "job-impressions-completed"),
        ])
    }

    public static func cancelJob(printerUri: String, userName: String, jobId: Int, requestId: Int32 = 1) -> IppMessage {
        request(.cancelJob, printerUri, userName, requestId, [IppAttribute("job-id", .integer(Int32(jobId)))])
    }

    /// The same request as IPP 1.1.
    public static func downgraded(_ request: IppMessage) -> IppMessage {
        var copy = request
        copy.version = .v11
        return copy
    }

    /// An address typed as http or https goes in the request as ipp or ipps.
    static func ippUri(_ address: String) -> String {
        let lower = address.lowercased()
        if lower.hasPrefix("http://") { return "ipp://" + String(address.dropFirst(7)) }
        if lower.hasPrefix("https://") { return "ipps://" + String(address.dropFirst(8)) }
        return address
    }

    /// The text cut to 255 bytes of UTF-8 without splitting a character.
    static func truncated(_ text: String) -> String {
        if text.utf8.count <= nameLimit { return text }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in text.unicodeScalars {
            bytes += String(scalar).utf8.count
            if bytes > nameLimit { break }
            result.append(scalar)
        }
        return String(result)
    }

    private static func keywords(_ name: String, _ values: String...) -> IppAttribute {
        IppAttribute(name: name, values: values.map { IppValue.keyword($0) })
    }

    private static func request(_ operation: IppOperation, _ printerUri: String, _ userName: String, _ requestId: Int32,
                                _ own: [IppAttribute]) -> IppMessage {
        let common = [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("attributes-natural-language", .language("en")),
            IppAttribute("printer-uri", .uri(ippUri(printerUri))),
            IppAttribute("requesting-user-name", .name(truncated(userName))),
        ]
        return IppMessage(version: .v20, code: operation.rawValue, requestId: requestId,
                          groups: [IppGroup(tag: IppTag.operationAttributes, attributes: common + own)])
    }
}
