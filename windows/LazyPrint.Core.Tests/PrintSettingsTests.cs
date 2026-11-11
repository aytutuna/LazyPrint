using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintSettingsTests.swift: the same cases. The files follow
// CONTRACTS.md, Global rule 5.

public sealed class PrintSettingsTests : IDisposable
{
    private readonly string _directory;

    public PrintSettingsTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private string Settings => Path.Combine(_directory, "settings.json");
    private string Printers => Path.Combine(_directory, "printers.json");

    [Fact]
    public void Defaults_AreTheContractsDefaults()
    {
        var s = new PrintSettings();
        Assert.Null(s.TaskId);
        Assert.Null(s.PrinterId);
        Assert.Equal(1, s.Copies);
        Assert.True(s.Collate);
        Assert.Equal(ColorChoice.Color, s.Color);
        Assert.Equal(QualityChoice.Normal, s.Quality);
        Assert.Equal(Sides.OneSided, s.Sides);
        Assert.Equal(1, s.PagesPerSheet);
        Assert.False(s.Booklet);
        Assert.False(s.RightToLeft);
        Assert.False(s.PageBorders);
        Assert.Equal(Scaling.ShrinkToFit, s.Scaling);
        Assert.Equal("auto", s.PaperId);
        Assert.Equal("4x6", s.PhotoSizeId);
        Assert.True(s.PhotoFill);
        Assert.True(s.CutMarks);
    }

    [Fact]
    public void Settings_RoundTrip()
    {
        var s = new PrintSettings
        {
            TaskId = "booklet", PrinterId = "ipp:4509a320", Copies = 3, Collate = false, Color = ColorChoice.Gray,
            Quality = QualityChoice.Best, Sides = Sides.ShortEdge, PagesPerSheet = 4, Booklet = true, RightToLeft = true,
            PageBorders = true, Scaling = Scaling.Fill, PaperId = "a4", PhotoSizeId = "10x15cm", PhotoFill = false, CutMarks = false,
        };
        SettingsStore.Save(s, _directory);
        Assert.Equal(s with { Copies = 1 }, SettingsStore.Load(_directory));
    }

    [Fact]
    public void Settings_AreWrittenWithTheKeysAndRawValues()
    {
        SettingsStore.Save(new PrintSettings { Quality = QualityChoice.Draft, Sides = Sides.LongEdge, Scaling = Scaling.ActualSize }, _directory);
        string json = File.ReadAllText(Settings);
        Assert.Contains("\"quality\": \"draft\"", json);
        Assert.Contains("\"sides\": \"longEdge\"", json);
        Assert.Contains("\"scaling\": \"actualSize\"", json);
        Assert.Contains("\"photoSizeId\": \"4x6\"", json);
        Assert.Contains("\"paperId\": \"auto\"", json);
    }

    [Fact]
    public void Settings_Missing_IsNull()
    {
        Assert.Null(SettingsStore.Load(_directory));
        Assert.Empty(SettingsStore.LoadPrinters(_directory));
    }

    [Fact]
    public void Settings_FromAnOlderVersion_KeepTheirValuesAndDefaultTheRest()
    {
        File.WriteAllText(Settings, """{"copies": 7, "sides": "longEdge", "unknownKey": [1, 2]}""");
        var s = SettingsStore.Load(_directory)!;
        Assert.Equal(1, s.Copies);
        Assert.Equal(Sides.LongEdge, s.Sides);
        Assert.Equal(new PrintSettings { Sides = Sides.LongEdge }, s);
    }

    [Fact]
    public void Settings_WithAnUnknownOrWrongValue_ResetOnlyThatField()
    {
        File.WriteAllText(Settings, """
            {"taskId": "poster", "quality": "ultra", "color": "gray", "copies": "many", "scaling": null, "pagesPerSheet": 2}
            """);
        var s = SettingsStore.Load(_directory)!;
        // A task of a newer version survives as text.
        Assert.Equal("poster", s.TaskId);
        Assert.Equal(QualityChoice.Normal, s.Quality);
        Assert.Equal(ColorChoice.Gray, s.Color);
        Assert.Equal(1, s.Copies);
        Assert.Equal(Scaling.ShrinkToFit, s.Scaling);
        Assert.Equal(2, s.PagesPerSheet);
    }

    [Fact]
    public void Settings_Unreadable_AreMovedAside()
    {
        File.WriteAllText(Settings, "this is not JSON {");
        Assert.Null(SettingsStore.Load(_directory));
        Assert.False(File.Exists(Settings));
        var kept = Assert.Single(Directory.GetFiles(_directory));
        Assert.Matches(@"settings\.unreadable-\d{8}-\d{6}\.json$", kept);
    }

    [Fact]
    public void Printers_RoundTrip_ById()
    {
        var printers = new Dictionary<string, PrinterPrefs>
        {
            ["ipp:4509a320"] = new() { PaperPath = new PaperPath { TurnStackOver = false, TurnBacks = true, Checked = true }, LastPaperId = "letter" },
            ["system:Office"] = new(),
        };
        SettingsStore.SavePrinters(printers, _directory);
        var loaded = SettingsStore.LoadPrinters(_directory);
        Assert.Equal(["ipp:4509a320", "system:Office"], loaded.Keys.Order(StringComparer.Ordinal));
        Assert.Equal(printers["ipp:4509a320"], loaded["ipp:4509a320"]);
        Assert.Equal(new PrinterPrefs(), loaded["system:Office"]);
        Assert.Contains("\"turnStackOver\": false", File.ReadAllText(Printers));
    }

    [Fact]
    public void Printers_WithMissingOrBadFields_GetDefaults()
    {
        File.WriteAllText(Printers, """
            {"demo": {}, "ipp:x": {"paperPath": {"turnBacks": true, "turnStackOver": "no"}, "lastPaperId": 5}}
            """);
        var loaded = SettingsStore.LoadPrinters(_directory);
        Assert.Equal(new PrinterPrefs(), loaded["demo"]);
        var x = loaded["ipp:x"];
        Assert.True(x.PaperPath.TurnBacks);
        Assert.True(x.PaperPath.TurnStackOver);
        Assert.Null(x.LastPaperId);
    }

    [Fact]
    public void Printers_Unreadable_AreMovedAside_AndEmpty()
    {
        File.WriteAllText(Printers, "[1, 2");
        Assert.Empty(SettingsStore.LoadPrinters(_directory));
        Assert.False(File.Exists(Printers));
        Assert.Single(Directory.GetFiles(_directory), path => Path.GetFileName(path).StartsWith("printers.unreadable-", StringComparison.Ordinal));
    }
}
