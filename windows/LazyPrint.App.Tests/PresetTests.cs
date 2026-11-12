using System.IO;
using LazyPrint.App;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

// Mirrored by the Presets block of Tests/LazyPrintTests/AppStateSeamTests.swift: the same cases.
public sealed class PresetTests
{
    private static void Edit(Rig rig, Action<PrintSettings> change)
    {
        change(rig.Model.Settings);
        rig.Model.SettingsEdited();
    }

    private static string SavedPresets(Rig rig) => File.ReadAllText(Path.Combine(rig.Directory, "presets.json"));

    [Fact]
    public void SavingKeepsTheOptionsUnderTheTrimmedNameAndChecksIt()
    {
        using var rig = new Rig();
        Edit(rig, s => { s.PaperId = "a5"; s.Quality = QualityChoice.Draft; s.Copies = 4; });

        Assert.Equal(PresetNameCheck.Ok, rig.Model.SavePreset("  Notes "));

        var preset = Assert.Single(rig.Model.Presets);
        Assert.Equal("Notes", preset.Name);
        Assert.Equal("a5", preset.Settings.PaperId);
        Assert.Equal(1, preset.Settings.Copies);
        Assert.True(rig.Model.IsCurrent(preset));
        Assert.Contains("\"name\": \"Notes\"", SavedPresets(rig));
    }

    [Fact]
    public void ABadNameSavesNothing()
    {
        using var rig = new Rig();

        Assert.Equal(PresetNameCheck.Empty, rig.Model.SavePreset("  "));
        Assert.Equal(PresetNameCheck.BuiltIn, rig.Model.SavePreset("Handouts"));
        Assert.Empty(rig.Model.Presets);
    }

    [Fact]
    public void ANameInUseAsksBeforeItReplaces()
    {
        using var rig = new Rig();
        Edit(rig, s => s.PaperId = "a5");
        rig.Model.SavePreset("Notes");
        Edit(rig, s => s.PaperId = "letter");

        Assert.Equal(PresetNameCheck.Exists, rig.Model.SavePreset("notes"));
        Assert.Equal("a5", Assert.Single(rig.Model.Presets).Settings.PaperId);

        Assert.Equal(PresetNameCheck.Ok, rig.Model.SavePreset("notes", replace: true));
        var preset = Assert.Single(rig.Model.Presets);
        Assert.Equal("notes", preset.Name);
        Assert.Equal("letter", preset.Settings.PaperId);
    }

    [Fact]
    public async Task ApplyingSetsTheOptionsAndLeavesCopiesAndTheTask()
    {
        using var rig = new Rig();
        Edit(rig, s => { s.PaperId = "a5"; s.Sides = Sides.LongEdge; });
        rig.Model.SavePreset("Notes");
        await rig.Model.StartTaskAsync(PrintTask.Photos);
        Edit(rig, s => s.Copies = 3);

        rig.Model.ApplyPreset("notes");

        var s = rig.Model.Settings;
        Assert.Equal("a5", s.PaperId);
        Assert.Equal(Sides.LongEdge, s.Sides);
        Assert.Equal(LayoutStyle.Pages, s.LayoutStyle);
        Assert.Equal(3, s.Copies);
        Assert.Null(s.TaskId);
        Assert.Null(rig.Model.SelectedTask);
        Assert.True(rig.Model.IsCurrent(rig.Model.Presets[0]));
    }

    [Fact]
    public void TheCheckGoesWhenAnOptionDiffersAndComesBackWhenItDoesNot()
    {
        using var rig = new Rig();
        rig.Model.SavePreset("Plain");
        var preset = rig.Model.Presets[0];
        Assert.True(rig.Model.IsCurrent(preset));

        Edit(rig, s => s.Quality = QualityChoice.Best);
        Assert.False(rig.Model.IsCurrent(preset));

        Edit(rig, s => s.Quality = QualityChoice.Normal);
        Assert.True(rig.Model.IsCurrent(preset));
    }

    [Fact]
    public async Task APresetIsNotCheckedAfterATaskIsPicked()
    {
        using var rig = new Rig();
        rig.Model.SavePreset("Plain");

        await rig.Model.StartTaskAsync(PrintTask.Handouts);

        Assert.False(rig.Model.IsCurrent(rig.Model.Presets[0]));
    }

    [Fact]
    public async Task AnAppliedPresetsValuesWinOverThePrintersAndAreKeptForIt()
    {
        using var rig = new Rig();
        rig.Spooler.Queue.Add(Rig.Queue("HP LaserJet", isDefault: true));
        await rig.Model.RefreshPrintersAsync();
        await rig.Model.SelectPrinterAsync("system:HP LaserJet");
        Edit(rig, s => { s.PaperId = "letter"; s.Quality = QualityChoice.Best; });
        Edit(rig, s => { s.PaperId = "a5"; s.Quality = QualityChoice.Draft; });
        rig.Model.SavePreset("Notes");
        Edit(rig, s => { s.PaperId = "legal"; s.Quality = QualityChoice.Normal; });

        rig.Model.ApplyPreset("Notes");

        Assert.Equal("a5", rig.Model.Settings.PaperId);
        Assert.Equal("a5", rig.Model.SelectedPrefs.PaperId);
        Assert.Equal(QualityChoice.Draft, rig.Model.SelectedPrefs.Quality);
    }

    [Fact]
    public void RenamingKeepsTheOptionsAndTheCheck()
    {
        using var rig = new Rig();
        Edit(rig, s => s.PaperId = "a5");
        rig.Model.SavePreset("Notes");
        rig.Model.SavePreset("Other");

        Assert.Equal(PresetNameCheck.Exists, rig.Model.RenamePreset("Notes", "other"));
        Assert.Equal(PresetNameCheck.BuiltIn, rig.Model.RenamePreset("Notes", "Booklet"));
        Assert.Equal(PresetNameCheck.Empty, rig.Model.RenamePreset("Notes", " "));
        Assert.Equal(PresetNameCheck.Ok, rig.Model.RenamePreset("Other", " Draft "));

        Assert.Equal(["Notes", "Draft"], rig.Model.Presets.Select(p => p.Name));
        Assert.True(rig.Model.IsCurrent(rig.Model.Presets[1]));
        Assert.Contains("\"name\": \"Draft\"", SavedPresets(rig));
        Assert.DoesNotContain("Other", SavedPresets(rig));
    }

    [Fact]
    public void DeletingRemovesThePresetAndItsCheck()
    {
        using var rig = new Rig();
        rig.Model.SavePreset("Notes");
        Assert.Equal("Notes", rig.Model.AppliedPreset);

        rig.Model.DeletePreset("notes");

        Assert.Empty(rig.Model.Presets);
        Assert.Null(rig.Model.AppliedPreset);
        Assert.DoesNotContain("Notes", SavedPresets(rig));
    }

    [Fact]
    public void ThePresetsComeBackOnTheNextStart()
    {
        using var rig = new Rig();
        rig.Model.SavePreset("Notes");

        Assert.Equal(["Notes"], rig.Open().Presets.Select(p => p.Name));
    }

    [Fact]
    public async Task ABuiltInPresetIsCurrentOnlyWhileItsOptionsHold()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Booklet);
        Assert.Equal(PrintTask.Booklet, rig.Model.CurrentTask);

        Edit(rig, s => s.Copies = 3);
        Assert.Equal(PrintTask.Booklet, rig.Model.CurrentTask);

        Edit(rig, s => s.Booklet = false);
        Assert.Null(rig.Model.CurrentTask);
    }

    [Fact]
    public async Task ABuiltInPresetStaysCurrentWhenAnUnusedOptionChanges()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Document);

        Edit(rig, s => { s.MarginMm = 15; s.PhotoSizeId = "5x7"; });
        Assert.Equal(PrintTask.Document, rig.Model.CurrentTask);

        Edit(rig, s => s.Orientation = SheetOrientation.Landscape);
        Assert.Null(rig.Model.CurrentTask);
    }

    [Fact]
    public async Task SavingWhileABuiltInPresetIsOnLeavesOnlyTheNewOneCurrent()
    {
        using var rig = new Rig();
        await rig.Model.StartTaskAsync(PrintTask.Booklet);

        rig.Model.SavePreset("Mine");

        Assert.Null(rig.Model.CurrentTask);
        Assert.True(rig.Model.IsCurrent(rig.Model.Presets[0]));
    }
}
