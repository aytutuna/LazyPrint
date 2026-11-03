using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppRequests.swift: the requests both platforms send, byte for byte.

/// <summary>
/// The requests to a printer. Every one is version 2.0 with the operation group in a fixed order: charset utf-8, language en,
/// printer-uri, requesting-user-name, then the operation's own attributes. <c>userName</c> is the account name, or "iPhone"
/// on the iPhone, and is the same for Cancel-Job or printers refuse it. <see cref="Downgraded"/> makes the 1.1 request for a
/// printer that does not speak 2.0.
/// </summary>
public static class IppRequests
{
    private const int NameLimit = 255;

    public static IppMessage GetPrinterAttributes(string printerUri, string userName, int requestId = 1) =>
        Request(IppOperation.GetPrinterAttributes, printerUri, userName, requestId,
            [Keywords("requested-attributes", "all", "media-col-database")]);

    public static IppMessage PrintJob(string printerUri, string userName, IppJobTicket ticket, int requestId = 1)
    {
        var job = new List<IppAttribute>();
        if (ticket.Copies > 1) job.Add(new IppAttribute("copies", new IppValue.Integer(ticket.Copies)));
        job.Add(new IppAttribute("sides", new IppValue.Keyword(ticket.Sides)));
        job.Add(new IppAttribute("print-color-mode", new IppValue.Keyword(ticket.ColorMode)));
        job.Add(ticket.Media.Entry is { } entry
            ? new IppAttribute("media-col", new IppValue.Collection(entry))
            : new IppAttribute("media", new IppValue.Keyword(ticket.Media.Name)));
        if (ticket.Quality is { } quality) job.Add(new IppAttribute("print-quality", new IppValue.EnumValue(quality)));
        if (ticket.Scaling is { } scaling) job.Add(new IppAttribute("print-scaling", new IppValue.Keyword(scaling)));
        if (ticket.CollatedCopies)
            job.Add(new IppAttribute("multiple-document-handling", new IppValue.Keyword("separate-documents-collated-copies")));

        var request = Request(IppOperation.PrintJob, printerUri, userName, requestId,
        [
            new IppAttribute("job-name", new IppValue.Name(Truncated(ticket.JobName))),
            new IppAttribute("document-format", new IppValue.MimeType(ticket.DocumentFormat)),
        ]);
        return request with { Groups = [.. request.Groups, new IppGroup(IppTag.JobAttributes, job)] };
    }

    public static IppMessage GetJobAttributes(string printerUri, string userName, int jobId, int requestId = 1) =>
        Request(IppOperation.GetJobAttributes, printerUri, userName, requestId,
        [
            new IppAttribute("job-id", new IppValue.Integer(jobId)),
            Keywords("requested-attributes", "job-state", "job-state-reasons", "job-impressions-completed"),
        ]);

    public static IppMessage CancelJob(string printerUri, string userName, int jobId, int requestId = 1) =>
        Request(IppOperation.CancelJob, printerUri, userName, requestId,
            [new IppAttribute("job-id", new IppValue.Integer(jobId))]);

    /// <summary>The same request as IPP 1.1.</summary>
    public static IppMessage Downgraded(IppMessage request) => request with { Version = IppVersion.V11 };

    /// <summary>An address typed as http or https goes in the request as ipp or ipps.</summary>
    internal static string IppUri(string address)
    {
        if (address.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) return "ipp://" + address[7..];
        if (address.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return "ipps://" + address[8..];
        return address;
    }

    /// <summary>The text cut to 255 bytes of UTF-8 without splitting a character.</summary>
    internal static string Truncated(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) <= NameLimit) return text;
        var result = new StringBuilder();
        int bytes = 0;
        foreach (Rune rune in text.EnumerateRunes())
        {
            bytes += rune.Utf8SequenceLength;
            if (bytes > NameLimit) break;
            result.Append(rune.ToString());
        }
        return result.ToString();
    }

    private static IppAttribute Keywords(string name, params string[] values) =>
        new(name, [.. values.Select(v => (IppValue)new IppValue.Keyword(v))]);

    private static IppMessage Request(IppOperation operation, string printerUri, string userName, int requestId,
        IReadOnlyList<IppAttribute> own) =>
        new(IppVersion.V20, (ushort)operation, requestId,
        [
            new IppGroup(IppTag.OperationAttributes,
            [
                new IppAttribute("attributes-charset", new IppValue.Charset("utf-8")),
                new IppAttribute("attributes-natural-language", new IppValue.Language("en")),
                new IppAttribute("printer-uri", new IppValue.Uri(IppUri(printerUri))),
                new IppAttribute("requesting-user-name", new IppValue.Name(Truncated(userName))),
                .. own,
            ]),
        ]);
}
