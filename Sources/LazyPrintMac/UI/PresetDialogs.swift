#if os(macOS)
import LazyPrintKit
import SwiftUI

/// Which name a preset dialog is asking for.
enum PresetDialog: Equatable {
    case save
    case rename(String)
}

/// The alerts of the presets in the Task menu: the name to save the options under or to rename a preset to, and the
/// question when a saved name is used again. A name that will not do shows what is wrong and asks again.
struct PresetDialogs: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var dialog: PresetDialog?
    @State private var name = ""
    @State private var note = ""
    @State private var retrying = false
    @State private var replacing: String?

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } })) {
                TextField(PrintText.presetNamePrompt, text: $name)
                Button("Save") { commit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(note)
            }
            .confirmationDialog(PrintText.replacePresetTitle(replacing ?? ""),
                                isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                                titleVisibility: .visible) {
                Button(PrintText.replaceButton, role: .destructive) {
                    if let replacing { _ = state.savePreset(named: replacing, replace: true) }
                }
            } message: {
                Text(PrintText.replacePresetMessage)
            }
            .onChange(of: dialog) { _, shown in
                guard let shown else { return }
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

    private func commit() {
        guard let asked = dialog else { return }
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

/// The presets of the Task menu: the saved ones, checked while the options still equal the one applied last, and the ways to
/// save, rename and delete them.
struct PresetMenuSection: View {
    @EnvironmentObject private var state: AppState
    @Binding var dialog: PresetDialog?

    var body: some View {
        Section(PrintText.presetsHeading) {
            ForEach(state.userPresets, id: \.name) { preset in
                Toggle(preset.name, isOn: Binding(get: { state.isCurrent(preset) }, set: { _ in state.applyPreset(named: preset.name) }))
            }
            Button(PrintText.savePresetItem) { dialog = .save }
            if !state.userPresets.isEmpty {
                Menu(PrintText.renamePresetItem) {
                    ForEach(state.userPresets, id: \.name) { preset in
                        Button(preset.name) { dialog = .rename(preset.name) }
                    }
                }
                Menu(PrintText.deletePresetItem) {
                    ForEach(state.userPresets, id: \.name) { preset in
                        Button(preset.name, role: .destructive) { state.deletePreset(named: preset.name) }
                    }
                }
            }
        }
    }
}
#endif
