namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppJobTicket.swift: the choices a Print-Job request carries.

/// <summary>
/// The paper of a job. <see cref="Entry"/> is the <c>Attributes</c> of a media-col-database entry, sent as media-col (size, margins,
/// media-type, media-source), so the margins the layout assumed are the ones the printer uses. <see cref="Name"/> is a PWG
/// self-describing name ("na_letter_8.5x11in"), sent as media only when there is no entry.
/// </summary>
public sealed record IppMediaChoice(IReadOnlyList<IppAttribute>? Entry, string Name)
{
    public bool Equals(IppMediaChoice? other) =>
        other is not null && Name == other.Name
        && (Entry is null ? other.Entry is null : other.Entry is not null && Entry.SequenceEqual(other.Entry));

    public override int GetHashCode() => HashCode.Combine(Name, Entry?.Count);
}

/// <summary>
/// What a job asks of the printer. <see cref="Sides"/> is "one-sided" or "two-sided-long-edge" ("two-sided-short-edge" only
/// for a document sent as is), <see cref="ColorMode"/> "color" or "monochrome", <see cref="Quality"/> 3, 4 or 5 when chosen,
/// <see cref="Scaling"/> "none" for imposed sheets and "fit" or "auto" for a document sent as is, and
/// <see cref="CollatedCopies"/> asks the printer to make the copies (separate-documents-collated-copies).
/// </summary>
public sealed record IppJobTicket(
    string JobName,
    string DocumentFormat,
    int Copies,
    string Sides,
    string ColorMode,
    IppMediaChoice Media,
    int? Quality = null,
    string? Scaling = null,
    bool CollatedCopies = false);
