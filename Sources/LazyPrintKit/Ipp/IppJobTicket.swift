import Foundation

// Twin of windows/LazyPrint.Core/Ipp/IppJobTicket.cs: the choices a Print-Job request carries.

/// The paper of a job. `entry` is the `attributes` of a media-col-database entry, sent as media-col (size, margins, media-type,
/// media-source), so the margins the layout assumed are the ones the printer uses. `name` is a PWG self-describing
/// name ("na_letter_8.5x11in"), sent as media only when there is no entry.
public struct IppMediaChoice: Equatable, Sendable {
    public var entry: [IppAttribute]?
    public var name: String

    public init(entry: [IppAttribute]?, name: String) {
        self.entry = entry
        self.name = name
    }
}

/// What a job asks of the printer. `sides` is "one-sided" or "two-sided-long-edge" ("two-sided-short-edge" only for a
/// document sent as is), `colorMode` "color" or "monochrome", `quality` 3, 4 or 5 when chosen, `scaling` "none" for
/// imposed sheets and "fit" or "auto" for a document sent as is, and `collatedCopies` asks the printer to make the
/// copies (separate-documents-collated-copies).
public struct IppJobTicket: Equatable, Sendable {
    public var jobName: String
    public var documentFormat: String
    public var copies: Int
    public var sides: String
    public var colorMode: String
    public var media: IppMediaChoice
    public var quality: Int?
    public var scaling: String?
    public var collatedCopies: Bool

    public init(jobName: String, documentFormat: String, copies: Int, sides: String, colorMode: String,
                media: IppMediaChoice, quality: Int? = nil, scaling: String? = nil, collatedCopies: Bool = false) {
        self.jobName = jobName
        self.documentFormat = documentFormat
        self.copies = copies
        self.sides = sides
        self.colorMode = colorMode
        self.media = media
        self.quality = quality
        self.scaling = scaling
        self.collatedCopies = collatedCopies
    }
}
