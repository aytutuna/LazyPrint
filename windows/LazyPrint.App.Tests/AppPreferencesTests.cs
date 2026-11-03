using System.IO;
using LazyPrint.App.Services;
using Xunit;

namespace LazyPrint.App.Tests;

public sealed class AppPreferencesTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), "lazyprint-prefs-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);
    }

    [Fact]
    public void NothingSavedIsTheDefaults()
    {
        var preferences = AppPreferencesStore.Load(_directory);

        Assert.Equal(AppAppearance.System, preferences.Appearance);
        Assert.Empty(preferences.InspectorSections);
    }

    [Fact]
    public void EachPartKeepsTheOthersChanges()
    {
        AppPreferencesStore.Update(p => p.Appearance = AppAppearance.Dark, _directory);
        AppPreferencesStore.Update(p => p.InspectorSections["layout"] = true, _directory);

        var preferences = AppPreferencesStore.Load(_directory);
        Assert.Equal(AppAppearance.Dark, preferences.Appearance);
        Assert.True(preferences.InspectorSections["layout"]);
    }

    [Fact]
    public void AnAppearanceFromANewerVersionIsTheDefault()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, "preferences.json"), """{ "appearance": "sepia", "inspectorSections": { "paper": false } }""");

        var preferences = AppPreferencesStore.Load(_directory);
        Assert.Equal(AppAppearance.System, preferences.Appearance);
        Assert.False(preferences.InspectorSections["paper"]);
    }
}
