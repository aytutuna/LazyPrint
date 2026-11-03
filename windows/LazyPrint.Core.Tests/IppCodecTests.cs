using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppCodecTests.swift: the same cases.

public class IppCodecTests
{
    private static IppMessage Roundtrip(IppMessage message) => IppMessage.Decode(message.Encoded()).Message;

    private static IppMessage Single(params IppAttribute[] attributes) =>
        new(IppVersion.V20, 0, 7, [new IppGroup(IppTag.PrinterAttributes, attributes)]);

    [Fact]
    public void Encoded_SmallRequest_IsTheBytesOfRfc8010()
    {
        var message = new IppMessage(IppVersion.V20, 0x000B, 1,
            [new IppGroup(IppTag.OperationAttributes, [new IppAttribute("attributes-charset", new IppValue.Charset("utf-8"))])]);
        byte[] expected =
        [
            0x02, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x01,
            0x01,
            0x47, 0x00, 0x12, .. Encoding.ASCII.GetBytes("attributes-charset"), 0x00, 0x05, .. Encoding.ASCII.GetBytes("utf-8"),
            0x03,
        ];
        Assert.Equal(expected, message.Encoded());
    }

    [Fact]
    public void Roundtrip_EveryValueType_IsKept()
    {
        var message = Single(
            new IppAttribute("i", new IppValue.Integer(-5), new IppValue.Integer(70000)),
            new IppAttribute("b", new IppValue.Bool(true), new IppValue.Bool(false)),
            new IppAttribute("e", new IppValue.EnumValue(4)),
            new IppAttribute("o", new IppValue.Octets([0, 1, 2, 255])),
            new IppAttribute("d", new IppValue.DateTimeValue([0x07, 0xEA, 11, 3, 10, 20, 30, 4, (byte)'+', 1, 0])),
            new IppAttribute("r", new IppValue.Resolution(600, 300, 3)),
            new IppAttribute("g", new IppValue.Range(1, 999)),
            new IppAttribute("t", new IppValue.Text("Grüße 日本")),
            new IppAttribute("n", new IppValue.Name("job")),
            new IppAttribute("k", new IppValue.Keyword("one-sided"), new IppValue.Keyword("two-sided-long-edge")),
            new IppAttribute("u", new IppValue.Uri("ipp://printer.local:631/ipp/print")),
            new IppAttribute("s", new IppValue.UriScheme("ipp")),
            new IppAttribute("c", new IppValue.Charset("utf-8")),
            new IppAttribute("l", new IppValue.Language("en")),
            new IppAttribute("m", new IppValue.MimeType("application/pdf")),
            new IppAttribute("x", new IppValue.OutOfBand(IppTag.Unsupported)),
            new IppAttribute("y", new IppValue.OutOfBand(IppTag.Unknown)),
            new IppAttribute("z", new IppValue.OutOfBand(IppTag.NoValue)));
        Assert.Equal(message, Roundtrip(message));
    }

    [Fact]
    public void Roundtrip_Collections_KeepMembersNestingAndAdditionalValues()
    {
        var size = new IppValue.Collection([
            new IppAttribute("x-dimension", new IppValue.Integer(21000)),
            new IppAttribute("y-dimension", new IppValue.Integer(29700)),
        ]);
        var first = new IppValue.Collection([
            new IppAttribute("media-size", size),
            new IppAttribute("media-type", new IppValue.Keyword("stationery"), new IppValue.Keyword("labels")),
        ]);
        var second = new IppValue.Collection([new IppAttribute("media-top-margin", new IppValue.Integer(0))]);
        var message = Single(new IppAttribute("media-col-database", first, second), new IppAttribute("after", new IppValue.Integer(1)));
        Assert.Equal(message, Roundtrip(message));
    }

    [Fact]
    public void Encoded_Collection_HasMemberNamesAndEndCollectionAsRfc8010()
    {
        var collection = new IppValue.Collection([new IppAttribute("x-dimension", new IppValue.Integer(5))]);
        byte[] bytes = Single(new IppAttribute("c", collection)).Encoded();
        byte[] body =
        [
            0x34, 0x00, 0x01, (byte)'c', 0x00, 0x00,
            0x4A, 0x00, 0x00, 0x00, 0x0B, .. Encoding.ASCII.GetBytes("x-dimension"),
            0x21, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x05,
            0x37, 0x00, 0x00, 0x00, 0x00,
        ];
        Assert.Equal(body, bytes[9..^1]);
    }

    [Fact]
    public void Roundtrip_UnknownTagsAndOddLengths_AreKeptAsTheyCame()
    {
        var message = Single(
            new IppAttribute("a", new IppValue.Unknown(0x7F, [1, 2, 3])),
            new IppAttribute("b", new IppValue.Unknown(IppTag.Integer, [1, 2, 3])),
            new IppAttribute("c", new IppValue.Unknown(0x15, [])),
            new IppAttribute("d", new IppValue.Unknown(IppTag.Boolean, [])));
        Assert.Equal(message, Roundtrip(message));
    }

    [Fact]
    public void Roundtrip_AnyDelimiterGroup_IsKept()
    {
        var message = new IppMessage(IppVersion.V11, 0x0402, 99,
        [
            new IppGroup(IppTag.OperationAttributes, [new IppAttribute("a", new IppValue.Integer(1))]),
            new IppGroup(0x07, [new IppAttribute("b", new IppValue.Integer(2))]),
            new IppGroup(IppTag.UnsupportedAttributes, [new IppAttribute("c", new IppValue.OutOfBand(IppTag.Unsupported))]),
            new IppGroup(IppTag.JobAttributes, []),
        ]);
        Assert.Equal(message, Roundtrip(message));
    }

    [Fact]
    public void Decode_TextAndNameWithLanguage_DropTheLanguage()
    {
        byte[] data =
        [
            0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x04,
            0x35, 0x00, 0x01, (byte)'t', 0x00, 0x09, 0x00, 0x02, (byte)'e', (byte)'n', 0x00, 0x03, (byte)'a', (byte)'b', (byte)'c',
            0x36, 0x00, 0x01, (byte)'n', 0x00, 0x09, 0x00, 0x02, (byte)'d', (byte)'e', 0x00, 0x03, (byte)'x', (byte)'y', (byte)'z',
            0x03,
            0xAA, 0xBB,
        ];
        var (message, offset) = IppMessage.Decode(data);
        Assert.Equal(new IppValue.Text("abc"), message["t"]!.Values[0]);
        Assert.Equal(new IppValue.Name("xyz"), message["n"]!.Values[0]);
        Assert.Equal(data.Length - 2, offset);
        Assert.Equal(new IppVersion(1, 1), message.Version);
    }

    [Fact]
    public void Decode_RequestFollowedByDocument_GivesTheDocumentOffset()
    {
        var message = Single(new IppAttribute("a", new IppValue.Integer(1)));
        byte[] bytes = [.. message.Encoded(), .. "%PDF-1.7"u8.ToArray()];
        var (decoded, offset) = IppMessage.Decode(bytes);
        Assert.Equal(message, decoded);
        Assert.Equal("%PDF-1.7", Encoding.ASCII.GetString(bytes[offset..]));
    }

    [Fact]
    public void Decode_EveryCutOfAFixture_IsABadResponse()
    {
        byte[] data = IppFixtures.Printer("epson-ecotank");
        for (int length = 0; length < data.Length; length++)
        {
            int cut = length;
            var error = Assert.Throws<PrintException>(() => IppMessage.Decode(data.AsSpan(0, cut)));
            Assert.IsType<PrintError.BadResponse>(error.Error);
        }
    }

    [Fact]
    public void Decode_NotIpp_IsABadResponse()
    {
        Assert.Throws<PrintException>(() => IppMessage.Decode("HTTP/1.1 200 OK\r\n\r\n"u8));
        Assert.Throws<PrintException>(() => IppMessage.Decode([0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03]));
    }

    [Fact]
    public void Decode_ValueWithoutAName_IsABadResponseWhenNothingPrecedesIt()
    {
        byte[] data = [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x21, 0x00, 0x00, 0x00, 0x04, 0, 0, 0, 1, 0x03];
        Assert.Throws<PrintException>(() => IppMessage.Decode(data));
    }

    [Fact]
    public void IsSuccess_CodesBelow0x0100()
    {
        IppMessage With(ushort code) => new(IppVersion.V20, code, 1, []);
        Assert.True(With(0x0000).IsSuccess);
        Assert.True(With(0x0001).IsSuccess);
        Assert.True(With(0x0002).IsSuccess);
        Assert.False(With(0x0400).IsSuccess);
        Assert.False(With(0x0507).IsSuccess);
    }

    [Fact]
    public void Indexer_FindsTheFirstAttributeOutsideTheUnsupportedGroup()
    {
        var message = new IppMessage(IppVersion.V20, 0x040B, 1,
        [
            new IppGroup(IppTag.OperationAttributes, [new IppAttribute("x", new IppValue.Integer(1))]),
            new IppGroup(IppTag.UnsupportedAttributes, [new IppAttribute("copies", new IppValue.Integer(9)), new IppAttribute("sides", new IppValue.OutOfBand(IppTag.Unsupported))]),
            new IppGroup(IppTag.JobAttributes, [new IppAttribute("copies", new IppValue.Integer(2)), new IppAttribute("copies", new IppValue.Integer(3))]),
        ]);
        Assert.Equal(new IppValue.Integer(2), message["copies"]!.Values[0]);
        Assert.Null(message["sides"]);
        Assert.Null(message["missing"]);
    }

    [Fact]
    public void Decode_EveryPrinterFixture_ReadsToTheEndAndEncodesBack()
    {
        foreach (string name in IppFixtures.PrinterNames)
        {
            byte[] data = IppFixtures.Printer(name);
            var (message, offset) = IppMessage.Decode(data);
            Assert.True(message.IsSuccess, name);
            Assert.Equal(data.Length, offset);
            Assert.Equal(message, IppMessage.Decode(message.Encoded()).Message);
            // The fixtures come from the separate Python encoder. Brother's has values with a language, which the codec drops.
            if (name != "brother-laser") Assert.Equal(data, message.Encoded());
        }
    }
}
