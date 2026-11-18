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
        Assert.Equal(SheetOrientation.Automatic, s.Orientation);
        Assert.Equal(MarginChoice.Printer, s.Margin);
        Assert.Equal(0, s.Poster);
        Assert.Equal(PageSelection.All, s.PageSelection);
        Assert.False(s.ReverseOrder);
        Assert.Equal("auto", s.PaperId);
        Assert.Equal("page", s.PhotoSizeId);
        Assert.False(s.CutMarks);
    }

    [Fact]
    public void Settings_RoundTrip()
    {
        var s = new PrintSettings
        {
            TaskId = "booklet", PrinterId = "ipp:4509a320", Copies = 3, Collate = false, Color = ColorChoice.Gray,
            Quality = QualityChoice.Best, Sides = Sides.ShortEdge, PagesPerSheet = 4, Booklet = true, RightToLeft = true,
            PageBorders = true, Scaling = Scaling.Fill, Orientation = SheetOrientation.Landscape, Margin = MarginChoice.Custom, MarginMm = 20, Poster = 3, PaperId = "a4", PhotoSizeId = "10x15cm", CutMarks = true,
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
        Assert.Contains("\"photoSizeId\": \"page\"", json);
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
    public void MarginMm_ArrowStepFromAHundredthLandsOnTheNextTenth()
    {
        var s = new PrintSettings { MarginMm = 0.05 };
        s.MarginMm += 0.1;
        Assert.Equal(0.15, s.MarginMm);
    }

    [Theory]
    [InlineData("10", 10)]
    [InlineData("3.2", 3.2)]
    [InlineData("3.25", 3.25)]
    [InlineData("3.256", 3.26)]
    [InlineData("0.05", 0.05)]
    [InlineData("80", 50)]
    [InlineData("-4", 0)]
    public void Settings_LoadTheMarginToHundredthsAndClamped(string json, double expected)
    {
        File.WriteAllText(Settings, "{\"margin\": \"custom\", \"marginMm\": " + json + "}");
        Assert.Equal(expected, SettingsStore.Load(_directory)!.MarginMm);
    }

    [Fact]
    public void Settings_SaveAWholeMarginWithoutADecimalPoint()
    {
        SettingsStore.Save(new PrintSettings { MarginMm = 10 }, _directory);
        Assert.Contains("\"marginMm\": 10,", File.ReadAllText(Settings));
    }

    [Fact]
    public void Settings_WithTheOldSmallMargin_LoadThePrintersMargin()
    {
        File.WriteAllText(Settings, """{"margin": "small"}""");
        Assert.Equal(MarginChoice.Printer, SettingsStore.Load(_directory)!.Margin);
        File.WriteAllText(Settings, """{"margin": "printer"}""");
        Assert.Equal(MarginChoice.Printer, SettingsStore.Load(_directory)!.Margin);
    }


    [Fact]
    public void Settings_SavedWithALayoutStyle_GetWhatThatStyleForced()
    {
        File.WriteAllText(Settings, """
            {"layoutStyle": "photoPrints", "photoSizeId": "5x7", "photoFill": false, "cutMarks": true,
             "pagesPerSheet": 4, "sides": "longEdge", "booklet": true, "poster": 2, "margin": "normal"}
            """);
        var prints = SettingsStore.Load(_directory)!;
        Assert.Equal("5x7", prints.PhotoSizeId);
        Assert.True(prints.CutMarks);
        Assert.Equal(Scaling.Fit, prints.Scaling);
        Assert.Equal(1, prints.PagesPerSheet);
        Assert.Equal(Sides.OneSided, prints.Sides);
        Assert.False(prints.Booklet);
        Assert.Equal(0, prints.Poster);
        Assert.Equal(MarginChoice.None, prints.Margin);
        Assert.Null(prints.LayoutStyle);

        File.WriteAllText(Settings, """{"layoutStyle": "photoPrints", "photoFill": true}""");
        Assert.Equal(Scaling.Fill, SettingsStore.Load(_directory)!.Scaling);

        File.WriteAllText(Settings, """
            {"layoutStyle": "photoSheet", "photoSizeId": "4x6", "pagesPerSheet": 4, "scaling": "fill", "cutMarks": true, "margin": "normal", "poster": 3}
            """);
        var sheet = SettingsStore.Load(_directory)!;
        Assert.Equal("page", sheet.PhotoSizeId);
        Assert.Equal(4, sheet.PagesPerSheet);
        Assert.Equal(Scaling.Fill, sheet.Scaling);
        Assert.True(sheet.CutMarks);
        Assert.Equal(MarginChoice.None, sheet.Margin);
        Assert.Equal(0, sheet.Poster);

        File.WriteAllText(Settings, """{"layoutStyle": "pages", "photoSizeId": "4x6", "cutMarks": true, "margin": "normal"}""");
        var pages = SettingsStore.Load(_directory)!;
        Assert.Equal("page", pages.PhotoSizeId);
        Assert.False(pages.CutMarks);
        Assert.Equal(MarginChoice.Normal, pages.Margin);
    }

    [Fact]
    public void Settings_WithAPhotoFillButNoLayoutStyle_ArePhotoOptionsOfTheirTask()
    {
        File.WriteAllText(Settings, """{"taskId": "document", "photoFill": true, "photoSizeId": "4x6", "cutMarks": true, "margin": "normal"}""");
        var document = SettingsStore.Load(_directory)!;
        Assert.Equal("page", document.PhotoSizeId);
        Assert.False(document.CutMarks);
        Assert.Equal(MarginChoice.Normal, document.Margin);

        File.WriteAllText(Settings, """{"taskId": "photos", "photoFill": false, "photoSizeId": "4x6", "cutMarks": true, "margin": "normal", "pagesPerSheet": 4}""");
        var photos = SettingsStore.Load(_directory)!;
        Assert.Equal("4x6", photos.PhotoSizeId);
        Assert.True(photos.CutMarks);
        Assert.Equal(MarginChoice.None, photos.Margin);
        Assert.Equal(1, photos.PagesPerSheet);
        Assert.Equal(Scaling.Fit, photos.Scaling);
    }

    [Fact]
    public void Settings_WithNeitherAPhotoFillNorALayoutStyle_AreLeftAsSaved()
    {
        File.WriteAllText(Settings, """{"taskId": "document", "photoSizeId": "4x6", "cutMarks": true, "margin": "normal"}""");
        var s = SettingsStore.Load(_directory)!;
        Assert.Equal("4x6", s.PhotoSizeId);
        Assert.True(s.CutMarks);
        Assert.Equal(MarginChoice.Normal, s.Margin);
    }

    [Fact]
    public void Settings_SavedWithAByteOrderMark_StillMigrate()
    {
        byte[] json = System.Text.Encoding.UTF8.GetBytes("""{"layoutStyle": "photoPrints", "photoSizeId": "4x6"}""");
        File.WriteAllBytes(Settings, [0xEF, 0xBB, 0xBF, .. json]);
        Assert.Equal(Scaling.Fill, SettingsStore.Load(_directory)!.Scaling);
        File.WriteAllBytes(Settings, [0xFF, 0xFE, .. System.Text.Encoding.Unicode.GetBytes("""{"layoutStyle": "photoPrints", "photoFill": false}""")]);
        Assert.Equal(Scaling.Fit, SettingsStore.Load(_directory)!.Scaling);
    }

    [Fact]
    public void Settings_AreSavedWithoutTheOldStyleKeys()
    {
        File.WriteAllText(Settings, """{"layoutStyle": "photoSheet", "photoFill": false}""");
        SettingsStore.Save(SettingsStore.Load(_directory)!, _directory);
        string text = File.ReadAllText(Settings);
        Assert.DoesNotContain("layoutStyle", text);
        Assert.DoesNotContain("photoFill", text);
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
            ["ipp:4509a320"] = new() { PaperPath = new PaperPath { TurnStackOver = false, TurnBacks = true, Checked = true } },
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
    }

    [Fact]
    public void Printers_KeepWhatWasLastUsed_AndOldFilesLoadWithoutIt()
    {
        var used = new PrinterPrefs { PaperId = "a5", Sides = Sides.LongEdge, Color = ColorChoice.Gray, Quality = QualityChoice.Draft };
        SettingsStore.SavePrinters(new Dictionary<string, PrinterPrefs> { ["system:Office"] = used }, _directory);
        Assert.Equal(used, SettingsStore.LoadPrinters(_directory)["system:Office"]);

        File.WriteAllText(Printers, """{"system:Old": {"paperPath": {"turnBacks": true}}, "system:Bad": {"paperId": 4, "sides": "sideways"}}""");
        var loaded = SettingsStore.LoadPrinters(_directory);
        Assert.Null(loaded["system:Old"].PaperId);
        Assert.Null(loaded["system:Old"].Sides);
        Assert.Equal(new PrinterPrefs(), loaded["system:Bad"]);
    }

    [Fact]
    public void Printers_ApplyOnlyWhatTheyRemember_AndRememberOnlyThoseFour()
    {
        var settings = new PrintSettings { PaperId = "legal", Sides = Sides.ShortEdge, Copies = 4, PagesPerSheet = 2 };
        new PrinterPrefs().ApplyTo(settings);
        Assert.Equal("legal", settings.PaperId);
        Assert.Equal(Sides.ShortEdge, settings.Sides);

        var prefs = new PrinterPrefs().Remembering(settings);
        var other = new PrintSettings { Copies = 1, PagesPerSheet = 1 };
        prefs.ApplyTo(other);
        Assert.Equal("legal", other.PaperId);
        Assert.Equal(Sides.ShortEdge, other.Sides);
        Assert.Equal(1, other.Copies);
        Assert.Equal(1, other.PagesPerSheet);
    }

    [Fact]
    public void Printers_KeepTheTrayAndPaperType()
    {
        var settings = new PrintSettings { MediaSource = "tray-2", MediaType = "photographic-glossy" };
        var prefs = new PrinterPrefs().Remembering(settings);
        var other = new PrintSettings();
        prefs.ApplyTo(other);
        Assert.Equal("tray-2", other.MediaSource);
        Assert.Equal("photographic-glossy", other.MediaType);

        var untouched = new PrintSettings { MediaSource = "manual" };
        new PrinterPrefs().ApplyTo(untouched);
        Assert.Equal("manual", untouched.MediaSource);
        Assert.Equal("auto", new PrintSettings().MediaType);
    }

    [Fact]
    public void Printers_Unreadable_AreMovedAside_AndEmpty()
    {
        File.WriteAllText(Printers, "[1, 2");
        Assert.Empty(SettingsStore.LoadPrinters(_directory));
        Assert.False(File.Exists(Printers));
        Assert.Single(Directory.GetFiles(_directory), path => Path.GetFileName(path).StartsWith("printers.unreadable-", StringComparison.Ordinal));
    }

    [Fact]
    public void Orientation_IsSaved_ButPageSelectionAndReverseAreForOneJob()
    {
        SettingsStore.Save(new PrintSettings { Orientation = SheetOrientation.Portrait, PageSelection = PageSelection.Odd, ReverseOrder = true }, _directory);
        string json = File.ReadAllText(Settings);
        Assert.Contains("\"orientation\": \"portrait\"", json);
        Assert.DoesNotContain("pageSelection", json);
        Assert.DoesNotContain("reverseOrder", json);
        Assert.Equal(new PrintSettings { Orientation = SheetOrientation.Portrait }, SettingsStore.Load(_directory));
    }
}
