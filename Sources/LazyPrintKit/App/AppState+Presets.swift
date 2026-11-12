import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Presets.cs: the presets the user saved.

extension AppState {
    /// The preset's menu item is checked: it was the last applied and the settings still have its options.
    public func isCurrent(_ preset: UserPreset) -> Bool {
        guard let applied = appliedPreset, UserPresets.same(applied, preset.name) else { return false }
        return UserPresets.matches(preset, settings)
    }

    /// Keeps the current options as a preset. `.exists` means a preset of that name is there and `replace` was not set, so
    /// nothing was saved; `.empty` and `.builtIn` refuse the name. `.ok` saved it, and it is the one applied.
    public func savePreset(named name: String, replace: Bool = false) -> PresetNameCheck {
        let check = UserPresets.check(name, among: userPresets)
        guard check == .ok || (check == .exists && replace) else { return check }
        let preset = UserPresets.make(name, from: settings)
        if let at = userPresets.firstIndex(where: { UserPresets.same($0.name, preset.name) }) {
            userPresets[at] = preset
        } else {
            userPresets.append(preset)
        }
        SettingsStore.savePresets(userPresets, in: files.settingsDirectory)
        appliedPreset = preset.name
        task = nil
        settings.taskId = nil
        return .ok
    }

    /// Sets the preset's options; documents, range and copies stay, and the printer's own paper, sides, color and quality
    /// are replaced by the preset's (and kept for it, as any change is).
    public func applyPreset(named name: String) {
        guard let preset = UserPresets.find(name, in: userPresets) else { return }
        clearMessages()
        task = nil
        sidesPickedBlind = nil
        appliedPreset = preset.name
        settings = UserPresets.apply(preset, to: settings)
    }

    /// `.exists` and the other refusals leave the preset as it was.
    public func renamePreset(_ name: String, to newName: String) -> PresetNameCheck {
        guard let at = userPresets.firstIndex(where: { UserPresets.same($0.name, name) }) else { return .ok }
        let check = UserPresets.check(newName, among: userPresets, renaming: name)
        guard check == .ok else { return check }
        let wasApplied = appliedPreset.map { UserPresets.same($0, name) } ?? false
        userPresets[at].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsStore.savePresets(userPresets, in: files.settingsDirectory)
        if wasApplied { appliedPreset = userPresets[at].name }
        return .ok
    }

    public func deletePreset(named name: String) {
        userPresets.removeAll { UserPresets.same($0.name, name) }
        SettingsStore.savePresets(userPresets, in: files.settingsDirectory)
        if let applied = appliedPreset, UserPresets.same(applied, name) { appliedPreset = nil }
    }
}
