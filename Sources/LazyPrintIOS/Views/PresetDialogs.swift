#if os(iOS)
import LazyPrintKit
import SwiftUI

/// Which name a preset dialog is asking for.
enum PresetDialog: Equatable {
    case save
    case rename(String)
    case delete(String)
}

/// The alerts of the presets in the Preset menu: the name to save the options under or to rename a preset to, the
/// question when a saved name is used again and the one before a preset is deleted. A name that will not do shows what is wrong and asks again.
struct PresetDialogs: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var dialog: PresetDialog?
    @State private var name = ""
    @State private var note = ""
    @State private var retrying = false
    @State private var replacing: String?

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding<Bool>(get: { asksForName }, set: { (on: Bool) in if !on, asksForName { dialog = nil } }),
                   presenting: asksForName ? dialog : nil) { (asked: PresetDialog) in
                TextField(PrintText.presetNamePrompt, text: $name)
                Button("Save") { commit(asked) }
                Button("Cancel", role: .cancel) {}
            } message: { (_: PresetDialog) in
                Text(note)
            }
            .confirmationDialog(PrintText.replacePresetTitle(replacing ?? ""),
                                isPresented: Binding<Bool>(get: { replacing != nil }, set: { (on: Bool) in if !on { replacing = nil } }),
                                titleVisibility: .visible, presenting: replacing) { (target: String) in
                Button(PrintText.replaceButton, role: .destructive) {
                    _ = state.savePreset(named: target, replace: true)
                }
            } message: { (_: String) in
                Text(PrintText.replacePresetMessage)
            }
            .confirmationDialog(PrintText.deletePresetTitle(deleting ?? ""),
                                isPresented: Binding<Bool>(get: { deleting != nil }, set: { (on: Bool) in if !on, deleting != nil { dialog = nil } }),
                                titleVisibility: .visible, presenting: deleting) { (target: String) in
                Button(PrintText.deleteButton, role: .destructive) {
                    state.deletePreset(named: target)
                }
                .accessibilityIdentifier("preset.delete.confirm")
            } message: { (_: String) in
                Text(PrintText.deletePresetMessage)
            }
            .onChange(of: dialog) { (_: PresetDialog?, shown: PresetDialog?) in
                guard let shown, asksForName else { return }
                if retrying {
                    retrying = false
                    return
                }
                note = ""
                if case .rename(let old) = shown { name = old } else { name = "" }
            }
    }

    private var title: String {
        if case .rename = dialog { return PrintText.renamePresetTitle }
        return PrintText.savePresetTitle
    }

    /// Save and rename ask for a name; delete asks a question of its own.
    private var asksForName: Bool {
        switch dialog {
        case .save, .rename: return true
        case .delete, nil: return false
        }
    }

    private var deleting: String? {
        if case .delete(let name) = dialog { return name }
        return nil
    }

    private func commit(_ asked: PresetDialog) {
        var check = PresetNameCheck.ok
        switch asked {
        case .save:
            check = state.savePreset(named: name)
            if check == .exists {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async { replacing = clean }
                return
            }
        case .rename(let old):
            check = state.renamePreset(old, to: name)
        case .delete:
            return
        }
        guard check != .ok else { return }
        note = PrintText.presetNameProblem(check)
        retrying = true
        DispatchQueue.main.async { dialog = asked }
    }
}

extension View {
    func presetDialogs(_ dialog: Binding<PresetDialog?>) -> some View {
        modifier(PresetDialogs(dialog: dialog))
    }
}

/// The presets of the Preset menu: the saved ones, checked while the options still equal the one applied last, and the ways to
/// save, rename and delete them.
struct PresetMenuSection: View {
    @EnvironmentObject private var state: AppState
    @Binding var dialog: PresetDialog?

    var body: some View {
        Section {
            ForEach(state.userPresets, id: \.name) { (preset: UserPreset) in
                Toggle(preset.name, isOn: Binding<Bool>(get: { state.isCurrent(preset) }, set: { (_: Bool) in state.applyPreset(named: preset.name) }))
            }
            Button(PrintText.savePresetItem) { dialog = .save }
                .accessibilityIdentifier("preset.save")
            if !state.userPresets.isEmpty {
                Menu(PrintText.renamePresetItem) {
                    ForEach(state.userPresets, id: \.name) { (preset: UserPreset) in
                        Button(preset.name) { dialog = .rename(preset.name) }
                    }
                }
                .accessibilityIdentifier("preset.rename")
                Menu(PrintText.deletePresetItem) {
                    ForEach(state.userPresets, id: \.name) { (preset: UserPreset) in
                        Button(preset.name, role: .destructive) { dialog = .delete(preset.name) }
                    }
                }
                .accessibilityIdentifier("preset.delete")
            }
        }
    }
}
#endif
