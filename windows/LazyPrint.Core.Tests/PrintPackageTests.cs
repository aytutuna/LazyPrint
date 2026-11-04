using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintPackageTests.swift (same cases). The golden file
// Tests/Fixtures/Companion/print-package.lppkg is written here (LAZYPRINT_WRITE_GOLDEN=1) and
// only read by Swift.

public class PrintPackageTests
{
    private const string Batch = "batch-golden-01";

    private static byte[] Golden() =>
        PrintPackage.Make("Report.pdf", "application/pdf", Batch, 0, 3, "Aytu's iPhone", CompanionFixtures.Pdf);

    private static string Header(string name = "Report.pdf", string type = "application/pdf", string batch = Batch, int index = 0, int count = 3) =>
        $$"""{"name":{{CompanionProtocol.Quote(name)}},"contentType":"{{type}}","batch":"{{batch}}","index":{{index}},"count":{{count}},"from":"x"}""";

    [Fact]
    public void Make_WritesTheGoldenFile()
    {
        IppFixtures.Golden("print-package", Golden(), "", ".lppkg", "Companion");
    }

    [Fact]
    public void Make_WritesTheMagicTheHeaderLengthAndTheHeader()
    {
        byte[] package = Golden();
        Assert.Equal("LPPKG01\0"u8.ToArray(), package[..8]);
        string json = """{"name":"Report.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":0,"count":3,"from":"Aytu's iPhone"}""";
        Assert.Equal((uint)json.Length, BitConverter.ToUInt32(package, 8));
        Assert.Equal(json, Encoding.UTF8.GetString(package, 12, json.Length));
        Assert.Equal(CompanionFixtures.Pdf, package[(12 + json.Length)..]);
    }

    [Fact]
    public void Read_ReadsTheGoldenFile()
    {
        byte[] package = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "Companion", "print-package.lppkg"));
        var info = PrintPackage.Read(package);
        Assert.Equal(new PrintPackageInfo("Report.pdf", "application/pdf", Batch, 0, 3, "Aytu's iPhone") { DataOffset = info.DataOffset }, info);
        Assert.Equal(CompanionFixtures.Pdf, package[info.DataOffset..]);
    }

    [Fact]
    public void Read_LeavesTheStreamAtTheFile()
    {
        using var stream = new MemoryStream(Golden());
        var info = PrintPackage.Read(stream);
        Assert.Equal(info.DataOffset, stream.Position);
    }

    [Fact]
    public void Read_ReadsAFileOnDisk()
    {
        string path = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N") + ".lppkg");
        File.WriteAllBytes(path, Golden());
        try
        {
            Assert.Equal("Report.pdf", PrintPackage.ReadFile(path).Name);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void NamesAndSendersKeepEveryCharacter()
    {
        string name = "Rapor \"Özet\" 日本\t1.pdf";
        string from = "Aytu's \u0001 iPhone";
        byte[] package = PrintPackage.Make(name, "application/pdf", Batch, 1, 2, from, CompanionFixtures.Pdf);
        var info = PrintPackage.Read(package);
        Assert.Equal(name, info.Name);
        Assert.Equal(from, info.From);
        // The header holds the characters themselves, not \u escapes.
        Assert.True(package.AsSpan().IndexOf("Özet"u8) > 0);
    }

    [Fact]
    public void Read_IgnoresUnknownKeysAndTheirOrder()
    {
        byte[] package = CompanionFixtures.Raw(
            """{"extra":[1,{"a":null}],"count":3,"from":"x","index":2,"batch":"batch-golden-01","contentType":"application/pdf","name":"a.pdf"}""");
        var info = PrintPackage.Read(package);
        Assert.Equal(("a.pdf", 2, 3), (info.Name, info.Index, info.Count));
    }

    [Fact]
    public void Read_RefusesWhatIsNotAPackage()
    {
        byte[] good = Golden();
        Assert.Equal(PrintPackage.NotPackageMessage, Refused([]));
        Assert.Equal(PrintPackage.NotPackageMessage, Refused(good[..11]));
        Assert.Equal(PrintPackage.NotPackageMessage, Refused(With(good, 0, (byte)'X')));
        Assert.Equal(PrintPackage.NotPackageMessage, Refused(With(good, 7, 1)));
        Assert.Equal(PrintPackage.NotPackageMessage, Refused(Encoding.ASCII.GetBytes("%PDF-1.7 a pdf, not a package")));
    }

    [Theory]
    [InlineData(0u)]
    [InlineData(65537u)]
    [InlineData(uint.MaxValue)]
    public void Read_RefusesAHeaderLengthOutOfRange(uint length)
    {
        byte[] package = Golden();
        BitConverter.GetBytes(length).CopyTo(package, 8);
        Assert.Equal(PrintPackage.DamagedMessage, Refused(package));
    }

    [Fact]
    public void Read_AcceptsAHeaderOfTheLargestLength()
    {
        string padded = Header().Replace("\"from\":\"x\"", $"\"from\":\"{new string('x', PrintPackage.MaxHeaderBytes - Header().Length + 1)}\"");
        Assert.Equal(PrintPackage.MaxHeaderBytes, Encoding.UTF8.GetByteCount(padded));
        Assert.Equal("Report.pdf", PrintPackage.Read(CompanionFixtures.Raw(padded)).Name);
        Assert.Equal(PrintPackage.DamagedMessage, Refused(CompanionFixtures.Raw(padded.Replace("\"from\":\"x", "\"from\":\"xx"))));
    }

    [Theory]
    [InlineData("""{"name":"Report.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":0,"count""")]
    [InlineData("not json")]
    [InlineData("[]")]
    [InlineData("null")]
    [InlineData("""{"contentType":"application/pdf","batch":"batch-golden-01","index":0,"count":1}""")]
    [InlineData("""{"name":"a.pdf","batch":"batch-golden-01","index":0,"count":1}""")]
    [InlineData("""{"name":"a.pdf","contentType":"application/pdf","index":0,"count":1}""")]
    [InlineData("""{"name":"a.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":0}""")]
    [InlineData("""{"name":"a.pdf","contentType":"application/pdf","batch":"batch-golden-01","index":"0","count":"1"}""")]
    [InlineData("""{"name":5,"contentType":"application/pdf","batch":"batch-golden-01","index":0,"count":1}""")]
    public void Read_RefusesAnUnusableHeader(string json)
    {
        string message = Refused(CompanionFixtures.Raw(json));
        Assert.Contains(message, new[] { PrintPackage.DamagedMessage, PrintPackage.NameMessage });
    }

    [Theory]
    [InlineData("a/b.pdf")]
    [InlineData("../\u0301x.pdf")]
    [InlineData("a\\b.pdf")]
    [InlineData("/a.pdf")]
    [InlineData("..")]
    [InlineData(".")]
    [InlineData("")]
    public void Read_RefusesANameWithAPathOrNone(string name)
    {
        Assert.Equal(PrintPackage.NameMessage, Refused(CompanionFixtures.Raw(Header(name))));
        Assert.Throws<PrintPackageException>(() => PrintPackage.Make(name, "application/pdf", Batch, 0, 1, "x", CompanionFixtures.Pdf));
    }

    [Fact]
    public void Read_LimitsANameTo255Utf8Bytes()
    {
        string fits = new string('é', 127) + "a";
        string tooLong = new string('é', 128);
        Assert.Equal(255, Encoding.UTF8.GetByteCount(fits));
        Assert.Equal(256, Encoding.UTF8.GetByteCount(tooLong));
        Assert.Equal(fits, PrintPackage.Read(CompanionFixtures.Raw(Header(fits))).Name);
        Assert.Equal(PrintPackage.NameMessage, Refused(CompanionFixtures.Raw(Header(tooLong))));
    }

    [Theory]
    [InlineData("application/pdf", true)]
    [InlineData("image/jpeg", true)]
    [InlineData("image/png", true)]
    [InlineData("image/heic", true)]
    [InlineData("image/tiff", true)]
    [InlineData("image/gif", false)]
    [InlineData("text/plain", false)]
    [InlineData("application/PDF", false)]
    [InlineData("", false)]
    public void Read_TakesTheFiveContentTypes(string type, bool accepted)
    {
        byte[] bytes = type switch
        {
            "image/jpeg" => [0xFF, 0xD8, 0xFF, 0xE0],
            "image/png" => [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A],
            "image/heic" => [0, 0, 0, 0x18, .. "ftypheic"u8],
            "image/tiff" => [.. "II*\0"u8, 8, 0, 0, 0],
            _ => CompanionFixtures.Pdf,
        };
        byte[] package = CompanionFixtures.Raw(Header("a.bin", type, count: 1), bytes);
        if (accepted) Assert.Equal(type, PrintPackage.Read(package).ContentType);
        else Assert.Equal(PrintPackage.DamagedMessage, Refused(package));
    }

    public static TheoryData<string, byte[], bool> Sniffing => new()
    {
        { "application/pdf", "%PDF-1.4"u8.ToArray(), true },
        { "application/pdf", "%PDF"u8.ToArray(), false },
        { "application/pdf", "%pdf-1.4"u8.ToArray(), false },
        { "application/pdf", [0xFF, 0xD8, 0xFF, 0xE0], false },
        { "application/pdf", [], false },
        { "image/jpeg", [0xFF, 0xD8, 0xFF], true },
        { "image/jpeg", [0xFF, 0xD8, 0x00], false },
        { "image/jpeg", [0xFF, 0xD8], false },
        { "image/jpeg", "%PDF-1.4"u8.ToArray(), false },
        { "image/png", [0x89, 0x50, 0x4E, 0x47], true },
        { "image/png", [0x89, 0x50, 0x4E], false },
        { "image/png", [0x89, 0x50, 0x4E, 0x46], false },
        { "image/heic", [0, 0, 0, 0x18, .. "ftypheic"u8], true },
        { "image/heic", [0, 0, 0, 0x18, .. "ftypmif1"u8], true },
        { "image/heic", [0, 0, 0, 0x18, .. "moovheic"u8], false },
        { "image/heic", [0, 0, 0, 0x18, (byte)'f', (byte)'t', (byte)'y'], false },
        { "image/heic", "ftypheic"u8.ToArray(), false },
        { "image/tiff", [.. "II*\0"u8], true },
        { "image/tiff", [.. "MM\0*"u8], true },
        { "image/tiff", [.. "II\0*"u8], false },
        { "image/tiff", [.. "MM*\0"u8], false },
        { "image/tiff", [.. "II*"u8], false },
    };

    [Theory]
    [MemberData(nameof(Sniffing))]
    public void TheFirstBytesDecideWhatTheFileIs(string type, byte[] start, bool matches)
    {
        byte[] package = CompanionFixtures.Raw(Header("a.bin", type, count: 1), start);
        if (matches)
        {
            Assert.Equal(type, PrintPackage.Read(package).ContentType);
            Assert.Equal(type, PrintPackage.Read(PrintPackage.Make("a.bin", type, Batch, 0, 1, "x", start)).ContentType);
        }
        else
        {
            Assert.Equal(PrintPackage.ContentMessage, Refused(package));
            Assert.Throws<PrintPackageException>(() => PrintPackage.Make("a.bin", type, Batch, 0, 1, "x", start));
        }
    }

    [Theory]
    [InlineData("short", 0, 1)]
    [InlineData("../batch-0001", 0, 1)]
    [InlineData("batch 0001", 0, 1)]
    [InlineData("", 0, 1)]
    [InlineData("batch-0001", 0, 0)]
    [InlineData("batch-0001", 3, 3)]
    [InlineData("batch-0001", 4, 3)]
    [InlineData("batch-0001", -1, 3)]
    [InlineData("batch-0001", 0, -2)]
    public void Read_RefusesABatchThatDoesNotAddUp(string batch, int index, int count)
    {
        Assert.Equal(PrintPackage.DamagedMessage, Refused(CompanionFixtures.Raw(Header(batch: batch, index: index, count: count))));
        Assert.Throws<PrintPackageException>(() => PrintPackage.Make("a.pdf", "application/pdf", batch, index, count, "x", CompanionFixtures.Pdf));
    }

    [Fact]
    public void Read_TakesTheFirstAndTheLastOfABatch()
    {
        Assert.Equal(0, PrintPackage.Read(CompanionFixtures.Raw(Header(index: 0, count: 3))).Index);
        Assert.Equal(2, PrintPackage.Read(CompanionFixtures.Raw(Header(index: 2, count: 3))).Index);
    }

    [Fact]
    public void Read_RefusesAFileWithNothingInIt()
    {
        Assert.Equal(PrintPackage.ContentMessage, Refused(CompanionFixtures.Raw(Header(), [])));
    }

    [Fact]
    public void Read_RefusesAPackageLargerThanTheLimit()
    {
        Assert.Equal(512L * 1024 * 1024 + 65536 + 12, PrintPackage.MaxPackageBytes);
        string path = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N") + ".lppkg");
        try
        {
            using (var file = new FileStream(path, FileMode.Create))
            {
                file.Write(Golden());
                file.SetLength(PrintPackage.MaxPackageBytes + 1);
            }
            Assert.Equal(PrintPackage.TooLargeMessage, Assert.Throws<PrintPackageException>(() => PrintPackage.ReadFile(path)).Message);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static byte[] With(byte[] data, int index, byte value)
    {
        var copy = (byte[])data.Clone();
        copy[index] = value;
        return copy;
    }

    private static string Refused(byte[] package) => Assert.Throws<PrintPackageException>(() => PrintPackage.Read(package)).Message;
}
