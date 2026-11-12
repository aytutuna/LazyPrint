using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/UserPresetsTests.swift: the same cases.

public sealed class UserPresetsTests : IDisposable
{
    private readonly string _directory;

    public UserPresetsTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private string PresetsFile => Path.Combine(_directory, "presets.json");

    private static PrintSettings Draft() => new()
    {
        Quality = QualityChoice.Draft, Color = ColorChoice.Gray, Sides = Sides.ShortEdge, PagesPerSheet = 2, PaperId = "a5",
        MediaSource = "tray-2", MediaType = "stationery", PageBorders = true, Margin = MarginChoice.Custom, MarginMm = 15,
    };

    [Fact]
    public void APresetKeepsTheOptionsAndNotTheJob()
    {
        var job = Draft() with
        {
            PrinterId = "system:HP", TaskId = "booklet", Copies = 5, PageSelection = PageSelection.Odd, ReverseOrder = true,
        };

        var preset = UserPresets.Make("  Draft  ", job);

        Assert.Equal("Draft", preset.Name);
        Assert.Equal(Draft(), preset.Settings);
    }

    [Fact]
    public void PresetsRoundTripInTheOrderSaved()
    {
        var presets = new List<UserPreset> { UserPresets.Make("Draft", Draft()), UserPresets.Make("Plain", new PrintSettings()) };

        SettingsStore.SavePresets(presets, _directory);

        Assert.Equal(presets, SettingsStore.LoadPresets(_directory));
        Assert.Contains("\"name\": \"Draft\"", File.ReadAllText(PresetsFile));
    }

    [Fact]
    public void NoFileIsNoPresets()
    {
        Assert.Empty(SettingsStore.LoadPresets(_directory));
    }

    [Fact]
    public void UnknownKeysAndBadValuesAreTolerated()
    {
        File.WriteAllText(PresetsFile, """
            [
              {"name": "Old", "later": 1, "settings": {"quality": "draft", "sides": "sideways", "paperId": "a5", "later": true}},
              {"name": "  "},
              {"settings": {}}
            ]
            """);

        var loaded = SettingsStore.LoadPresets(_directory);

        var old = Assert.Single(loaded);
        Assert.Equal("Old", old.Name);
        Assert.Equal(QualityChoice.Draft, old.Settings.Quality);
        Assert.Equal(Sides.OneSided, old.Settings.Sides);
        Assert.Equal("a5", old.Settings.PaperId);
    }

    [Fact]
    public void AnUnreadableFileIsKeptAside()
    {
        File.WriteAllText(PresetsFile, "not json {");

        Assert.Empty(SettingsStore.LoadPresets(_directory));

        Assert.False(File.Exists(PresetsFile));
        Assert.Single(Directory.GetFiles(_directory, "presets.unreadable-*.json"));
    }

    [Theory]
    [InlineData("", PresetNameCheck.Empty)]
    [InlineData("   ", PresetNameCheck.Empty)]
    [InlineData("Draft", PresetNameCheck.Exists)]
    [InlineData(" draft ", PresetNameCheck.Exists)]
    [InlineData("Booklet", PresetNameCheck.BuiltIn)]
    [InlineData("photo PRINTS", PresetNameCheck.BuiltIn)]
    [InlineData("Receipts", PresetNameCheck.Ok)]
    public void ANameMustBeNewAndNotEmpty(string name, PresetNameCheck expected)
    {
        var presets = new List<UserPreset> { UserPresets.Make("Draft", Draft()) };

        Assert.Equal(expected, UserPresets.Check(name, presets));
    }

    [Fact]
    public void ARenamedPresetMayKeepItsNameInAnotherCase()
    {
        var presets = new List<UserPreset> { UserPresets.Make("Draft", Draft()), UserPresets.Make("Plain", new PrintSettings()) };

        Assert.Equal(PresetNameCheck.Ok, UserPresets.Check("DRAFT", presets, renaming: "Draft"));
        Assert.Equal(PresetNameCheck.Exists, UserPresets.Check("plain", presets, renaming: "Draft"));
    }

    [Fact]
    public void ApplyingSetsTheOptionsAndLeavesThePrinterCopiesAndPages()
    {
        var preset = UserPresets.Make("Draft", Draft());
        var job = new PrintSettings
        {
            PrinterId = "system:HP", TaskId = "photos", Copies = 3, PageSelection = PageSelection.Even, ReverseOrder = true,
            Quality = QualityChoice.Best, LayoutStyle = LayoutStyle.PhotoPrints,
        };

        var applied = UserPresets.Apply(preset, job);

        Assert.Equal(Draft() with { PrinterId = "system:HP", Copies = 3, PageSelection = PageSelection.Even, ReverseOrder = true }, applied);
        Assert.Null(applied.TaskId);
    }

    [Fact]
    public void APresetMatchesUntilAnOptionChanges()
    {
        var preset = UserPresets.Make("Draft", Draft());
        var applied = UserPresets.Apply(preset, new PrintSettings { Copies = 4, PrinterId = "demo" });
        Assert.True(UserPresets.Matches(preset, applied));

        Assert.False(UserPresets.Matches(preset, applied with { Quality = QualityChoice.Normal }));
        Assert.False(UserPresets.Matches(preset, applied with { PaperId = "letter" }));
    }

    [Fact]
    public void APresetStillMatchesWhenAnUnusedOptionChanges()
    {
        var preset = UserPresets.Make("Draft", Draft());
        var applied = UserPresets.Apply(preset, new PrintSettings());
        Assert.True(UserPresets.Matches(preset, applied with { MarginMm = 15 }));
    }
}
