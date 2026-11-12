namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/UserPresets.swift: presets.json, the presets the user saved.

/// <summary>A name and the option values it sets: everything in <see cref="PrintSettings"/> but the printer, the task, copies, the page selection and the order.</summary>
public sealed record UserPreset
{
    public string Name { get; set; } = "";
    public PrintSettings Settings { get; set; } = new();
}

public enum PresetNameCheck
{
    Ok,
    Empty,
    /// <summary>The name is a built-in preset's.</summary>
    BuiltIn,
    /// <summary>The name is another user preset's.</summary>
    Exists,
}

public static class UserPresets
{
    /// <summary>The names the built-in presets (the tasks) go by.</summary>
    private static IEnumerable<string> BuiltInNames => TaskCatalog.All.Select(d => d.Title);

    /// <summary>
    /// Whether <paramref name="name"/> can name a preset: not empty once trimmed, not a built-in preset's, and not another user
    /// preset's, ignoring case. <paramref name="renaming"/> is the preset being renamed, which may keep its own name.
    /// </summary>
    public static PresetNameCheck Check(string? name, IEnumerable<UserPreset> presets, string? renaming = null)
    {
        var clean = name?.Trim() ?? "";
        if (clean.Length == 0) return PresetNameCheck.Empty;
        if (BuiltInNames.Any(n => Same(n, clean))) return PresetNameCheck.BuiltIn;
        bool taken = presets.Any(p => Same(p.Name, clean) && !(renaming is not null && Same(p.Name, renaming)));
        return taken ? PresetNameCheck.Exists : PresetNameCheck.Ok;
    }

    public static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    public static UserPreset? Find(IEnumerable<UserPreset> presets, string name) => presets.FirstOrDefault(p => Same(p.Name, name));

    /// <summary>The options of <paramref name="settings"/> under <paramref name="name"/> (trimmed).</summary>
    public static UserPreset Make(string name, PrintSettings settings) => new()
    {
        Name = name.Trim(),
        Settings = settings with { PrinterId = null, TaskId = null, Copies = 1, PageSelection = PageSelection.All, ReverseOrder = false },
    };

    /// <summary>The settings with the preset's options over them; the printer, copies, page selection and order stay, and no task is current.</summary>
    public static PrintSettings Apply(UserPreset preset, PrintSettings settings) => preset.Settings with
    {
        PrinterId = settings.PrinterId,
        TaskId = null,
        Copies = settings.Copies,
        PageSelection = settings.PageSelection,
        ReverseOrder = settings.ReverseOrder,
    };

    /// <summary>The settings still have every option the preset sets.</summary>
    public static bool Matches(UserPreset preset, PrintSettings settings) => Apply(preset, settings) == settings with { TaskId = null };
}
