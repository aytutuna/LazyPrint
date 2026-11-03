using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>Light, dark, or whatever Windows is set to. The first case is the default (Global rule 5).</summary>
public enum AppAppearance
{
    System,
    Light,
    Dark,
}

/// <summary>
/// What the Windows app remembers about its own window, apart from what is printed (settings.json). Windows only:
/// the Mac lays its settings out its own way.
/// </summary>
public sealed class AppPreferences
{
    public AppAppearance Appearance { get; set; } = AppAppearance.System;

    /// <summary>Which inspector sections the user left open or closed: <see cref="InspectorSections"/> id, open. No entry is the default.</summary>
    public Dictionary<string, bool> InspectorSections { get; set; } = [];
}

/// <summary>preferences.json in %APPDATA%\Lazy Print, read and written by the rules of settings.json.</summary>
public static class AppPreferencesStore
{
    private static string Path(string directory) => System.IO.Path.Combine(directory, "preferences.json");

    public static AppPreferences Load() => Load(StoreFiles.DefaultDirectory);

    /// <summary>Re-reads the file, applies <paramref name="change"/> and saves, so each part of the app changes only its own preference.</summary>
    public static void Update(Action<AppPreferences> change) => Update(change, StoreFiles.DefaultDirectory);

    internal static AppPreferences Load(string directory) =>
        StoreFiles.Load<AppPreferences>(Path(directory)) ?? new AppPreferences();

    internal static void Update(Action<AppPreferences> change, string directory)
    {
        var preferences = Load(directory);
        change(preferences);
        StoreFiles.Write(preferences, Path(directory));
    }
}
