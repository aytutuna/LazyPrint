using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppRequestsTests.swift: the same cases. The golden files are written by
// LAZYPRINT_WRITE_GOLDEN=1 dotnet test windows/LazyPrint.sln --filter IppRequestsTests, once, when a request changes on purpose.

public class IppRequestsTests
{
    private const string Uri = "ipp://printer.local:631/ipp/print";

    private static readonly IReadOnlyList<IppAttribute> A4Entry =
    [
        new IppAttribute("media-bottom-margin", new IppValue.Integer(300)),
        new IppAttribute("media-left-margin", new IppValue.Integer(300)),
        new IppAttribute("media-right-margin", new IppValue.Integer(300)),
        new IppAttribute("media-size", new IppValue.Collection([
            new IppAttribute("x-dimension", new IppValue.Integer(21000)),
            new IppAttribute("y-dimension", new IppValue.Integer(29700)),
        ])),
        new IppAttribute("media-source", new IppValue.Keyword("main")),
        new IppAttribute("media-top-margin", new IppValue.Integer(300)),
        new IppAttribute("media-type", new IppValue.Keyword("stationery")),
    ];

    private static IppJobTicket Ticket(string name = "Report.pdf") =>
        new(name, "application/pdf", 1, "one-sided", "color", new IppMediaChoice(null, "iso_a4_210x297mm"));

    private static IReadOnlyList<string> Names(IppMessage message, byte group) =>
        [.. message.Groups.Single(g => g.Tag == group).Attributes.Select(a => a.Name)];

    [Fact]
    public void GetPrinterAttributes_IsTheGoldenRequest()
    {
        IppFixtures.Golden("get-printer-attributes", IppRequests.GetPrinterAttributes(Uri, "anna").Encoded());
    }

    [Fact]
    public void GetPrinterAttributes_AsVersion11_IsTheGoldenRequest()
    {
        var request = IppRequests.Downgraded(IppRequests.GetPrinterAttributes(Uri, "anna"));
        Assert.Equal(IppVersion.V11, request.Version);
        IppFixtures.Golden("get-printer-attributes-11", request.Encoded());
    }

    [Fact]
    public void GetPrinterAttributes_AsksForAllAndTheMediaDatabase()
    {
        var request = IppRequests.GetPrinterAttributes(Uri, "anna");
        Assert.Equal(["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "requested-attributes"],
            Names(request, IppTag.OperationAttributes));
        Assert.Equal([new IppValue.Keyword("all"), new IppValue.Keyword("media-col-database")], request["requested-attributes"]!.Values);
        Assert.Equal(0x000B, request.Code);
        Assert.Equal(IppVersion.V20, request.Version);
    }

    [Fact]
    public void PrintJob_WithAName_IsTheGoldenRequest()
    {
        IppFixtures.Golden("print-job-pdf", IppRequests.PrintJob(Uri, "anna", Ticket()).Encoded());
    }

    [Fact]
    public void PrintJob_WithEveryChoice_IsTheGoldenRequest()
    {
        var ticket = new IppJobTicket("Sheets", "image/pwg-raster", 3, "two-sided-long-edge", "monochrome",
            new IppMediaChoice(A4Entry, "iso_a4_210x297mm"), Quality: 5, Scaling: "none", CollatedCopies: true);
        IppFixtures.Golden("print-job-media-col", IppRequests.PrintJob(Uri, "iPhone", ticket).Encoded());
    }

    [Fact]
    public void PrintJob_LongNonAsciiName_IsTheGoldenRequest()
    {
        IppFixtures.Golden("print-job-long-name", IppRequests.PrintJob(Uri, "anna", Ticket(new string('日', 100))).Encoded());
    }

    [Fact]
    public void PrintJob_AttributeOrder_FollowsTheContract()
    {
        var ticket = new IppJobTicket("Sheets", "image/pwg-raster", 3, "two-sided-long-edge", "monochrome",
            new IppMediaChoice(A4Entry, "iso_a4_210x297mm"), Quality: 4, Scaling: "none", CollatedCopies: true);
        var request = IppRequests.PrintJob(Uri, "anna", ticket);
        Assert.Equal(["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-name", "document-format"],
            Names(request, IppTag.OperationAttributes));
        Assert.Equal(["copies", "sides", "print-color-mode", "media-col", "print-quality", "print-scaling", "multiple-document-handling"],
            Names(request, IppTag.JobAttributes));
        Assert.Equal([IppTag.OperationAttributes, IppTag.JobAttributes], request.Groups.Select(g => g.Tag));
        Assert.Equal(new IppValue.EnumValue(4), request["print-quality"]!.Values[0]);
        Assert.Equal(new IppValue.Keyword("separate-documents-collated-copies"), request["multiple-document-handling"]!.Values[0]);
    }

    [Fact]
    public void PrintJob_Defaults_LeaveOutTheOptionalAttributes()
    {
        var request = IppRequests.PrintJob(Uri, "anna", Ticket());
        Assert.Equal(["sides", "print-color-mode", "media"], Names(request, IppTag.JobAttributes));
        Assert.Equal(new IppValue.Keyword("iso_a4_210x297mm"), request["media"]!.Values[0]);
        Assert.Equal(0x0002, request.Code);
    }

    [Fact]
    public void PrintJob_MediaEntry_IsSentVerbatimAsMediaCol()
    {
        var ticket = Ticket() with { Media = new IppMediaChoice(A4Entry, "iso_a4_210x297mm") };
        var request = IppRequests.PrintJob(Uri, "anna", ticket);
        Assert.Null(request["media"]);
        Assert.Equal(new IppValue.Collection(A4Entry), request["media-col"]!.Values[0]);
    }

    [Fact]
    public void GetJobAttributes_IsTheGoldenRequest()
    {
        var request = IppRequests.GetJobAttributes(Uri, "anna", 42);
        Assert.Equal(["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-id", "requested-attributes"],
            Names(request, IppTag.OperationAttributes));
        IppFixtures.Golden("get-job-attributes", request.Encoded());
    }

    [Fact]
    public void CancelJob_IsTheGoldenRequest()
    {
        var request = IppRequests.CancelJob(Uri, "anna", 42);
        Assert.Equal(["attributes-charset", "attributes-natural-language", "printer-uri", "requesting-user-name", "job-id"],
            Names(request, IppTag.OperationAttributes));
        IppFixtures.Golden("cancel-job", request.Encoded());
    }

    [Theory]
    [InlineData("http://printer.local/ipp/print", "ipp://printer.local/ipp/print")]
    [InlineData("HTTPS://printer.local:443/ipp/print", "ipps://printer.local:443/ipp/print")]
    [InlineData("ipp://printer.local:631/ipp/print", "ipp://printer.local:631/ipp/print")]
    [InlineData("ipps://printer.local/ipp/print", "ipps://printer.local/ipp/print")]
    public void PrinterUri_IsAlwaysIppOrIpps(string typed, string sent)
    {
        var request = IppRequests.CancelJob(typed, "anna", 1);
        Assert.Equal(new IppValue.Uri(sent), request["printer-uri"]!.Values[0]);
    }

    [Fact]
    public void Truncated_CutsAt255BytesWithoutSplittingACharacter()
    {
        Assert.Equal("short", IppRequests.Truncated("short"));
        Assert.Equal(255, Encoding.UTF8.GetByteCount(IppRequests.Truncated(new string('a', 300))));

        string cjk = IppRequests.Truncated(new string('日', 100));
        Assert.Equal(85, cjk.Length);
        Assert.Equal(255, Encoding.UTF8.GetByteCount(cjk));

        string emoji = IppRequests.Truncated("a" + string.Concat(Enumerable.Repeat("\U0001F600", 100)));
        Assert.Equal(1 + 63, emoji.EnumerateRunes().Count());
        Assert.Equal(253, Encoding.UTF8.GetByteCount(emoji));
    }

    [Fact]
    public void Names_AreCutInTheRequest()
    {
        var request = IppRequests.PrintJob(Uri, new string('u', 400), Ticket(new string('n', 400)));
        Assert.Equal(255, ((IppValue.Name)request["job-name"]!.Values[0]).Value.Length);
        Assert.Equal(255, ((IppValue.Name)request["requesting-user-name"]!.Values[0]).Value.Length);
    }
}
