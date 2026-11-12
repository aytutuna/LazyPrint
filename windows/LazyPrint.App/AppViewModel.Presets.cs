using LazyPrint.Core;

namespace LazyPrint.App;

// The presets the user saved. Twin of Sources/LazyPrintKit/App/AppState+Presets.swift.
public sealed partial class AppViewModel
{
    /// <summary>The preset's menu item is checked: it was the last applied and the settings still have its options.</summary>
    public bool IsCurrent(UserPreset preset) =>
        AppliedPreset is { } applied && UserPresets.Same(applied, preset.Name) && UserPresets.Matches(preset, Settings);

    /// <summary>
    /// Keeps the current options as a preset. <see cref="PresetNameCheck.Exists"/> means a preset of that name is there and
    /// <paramref name="replace"/> was not set, so nothing was saved; Empty and BuiltIn refuse the name. Ok saved it, and it is the one applied.
    /// </summary>
    public PresetNameCheck SavePreset(string name, bool replace = false)
    {
        var check = UserPresets.Check(name, Presets);
        if (check != PresetNameCheck.Ok && !(check == PresetNameCheck.Exists && replace)) return check;
        var preset = UserPresets.Make(name, Settings);
        int at = Presets.FindIndex(p => UserPresets.Same(p.Name, preset.Name));
        if (at >= 0) Presets[at] = preset;
        else Presets.Add(preset);
        SettingsStore.SavePresets(Presets, _directory);
        AppliedPreset = preset.Name;
        SelectedTask = null;
        Settings.TaskId = null;
        SettingsEdited();
        return PresetNameCheck.Ok;
    }

    /// <summary>
    /// Sets the preset's options; documents, range and copies stay, and the printer's own paper, sides, color and quality
    /// are replaced by the preset's (and kept for it, as any change is).
    /// </summary>
    public void ApplyPreset(string name)
    {
        if (UserPresets.Find(Presets, name) is not { } preset) return;
        ClearMessages();
        Settings = UserPresets.Apply(preset, Settings);
        SelectedTask = null;
        _sidesPickedBlind = null;
        AppliedPreset = preset.Name;
        SettingsEdited();
    }

    /// <summary>Exists and the other refusals leave the preset as it was.</summary>
    public PresetNameCheck RenamePreset(string name, string newName)
    {
        int at = Presets.FindIndex(p => UserPresets.Same(p.Name, name));
        if (at < 0) return PresetNameCheck.Ok;
        var check = UserPresets.Check(newName, Presets, renaming: name);
        if (check != PresetNameCheck.Ok) return check;
        bool wasApplied = AppliedPreset is { } applied && UserPresets.Same(applied, name);
        Presets[at] = Presets[at] with { Name = newName.Trim() };
        SettingsStore.SavePresets(Presets, _directory);
        if (wasApplied) AppliedPreset = Presets[at].Name;
        NotifyAll();
        return PresetNameCheck.Ok;
    }

    public void DeletePreset(string name)
    {
        Presets.RemoveAll(p => UserPresets.Same(p.Name, name));
        SettingsStore.SavePresets(Presets, _directory);
        if (AppliedPreset is { } applied && UserPresets.Same(applied, name)) AppliedPreset = null;
        NotifyAll();
    }
}
