#if os(iOS)
import LazyPrintKit
import SwiftUI

/// "Why isn't my printer listed?": one line saying what is listed and how many problems and warnings there are
/// (`Troubleshooter.overview`), then the checks: a card for each one to look at, with its status, one line, the buttons that
/// help and "More help" with the rest; a compact row for each check that passed. Copy diagnostics and Refresh are at the
/// foot. Shown as a sheet from the printers and from an error about a printer; Add by address pushes its screen.
struct TroubleshooterScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// What the foot says after Copy diagnostics or a button that opens something.
    @State private var footer: String?
    @State private var refreshing = false
    @State private var showAdd = false
    /// An action that changes something, waiting for the user's yes.
    @State private var asking: Asked?

    private struct Asked: Identifiable {
        let action: TroubleshootAction
        let check: TroubleshootCheck
        var id: String { check.id + action.rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Why isn't my printer listed?")
                            .font(.title3.weight(.semibold))
                        Text(refreshing ? "Looking for printers\u{2026}" : Troubleshooter.overview(state.snapshot, checks: state.troubleshootChecks))
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("troubleshooter.headline")
                }
                Section {
                    ForEach(state.troubleshootChecks, id: \.id) { (check: TroubleshootCheck) in
                        CheckRow(check: check) { (action: TroubleshootAction) in
                            act(action, check)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                foot
            }
            .navigationTitle("Troubleshoot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("troubleshooter.done")
                }
            }
            .navigationDestination(isPresented: $showAdd) {
                AddPrinterScreen()
            }
            .onChange(of: showAdd) { (_: Bool, shown: Bool) in
                if !shown { Task { await state.openTroubleshooter() } }
            }
            .task { await state.openTroubleshooter() }
            .confirmationDialog(asking.map { Troubleshooter.label($0.action, platform: .ios) + "?" } ?? "",
                                isPresented: Binding(get: { asking != nil }, set: { (on: Bool) in
                                    if !on { asking = nil }
                                }),
                                titleVisibility: .visible, presenting: asking) { (asked: Asked) in
                Button(Troubleshooter.label(asked.action, platform: .ios)) {
                    Task { await run(asked.action, asked.check) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { (asked: Asked) in
                Text(asked.check.title + ".")
            }
        }
    }

    /// Copy diagnostics and Refresh, and under them what the last button said, on a ground of their own so that the list
    /// does not show through.
    private var foot: some View {
        VStack(spacing: 6) {
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("troubleshooter.footer")
            }
            HStack {
                Button(Troubleshooter.label(.copyDiagnostics, platform: .ios)) {
                    Task { await copyDiagnostics() }
                }
                .accessibilityIdentifier("troubleshooter.copy")
                Spacer()
                Button(Troubleshooter.label(.refresh, platform: .ios)) {
                    Task { await refresh() }
                }
                .accessibilityIdentifier("troubleshooter.refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
    }

    private func act(_ action: TroubleshootAction, _ check: TroubleshootCheck) {
        switch action {
        case .refresh:
            Task { await refresh() }
        case .copyDiagnostics:
            Task { await copyDiagnostics() }
        case .addByAddress:
            showAdd = true
        case .clearStuckJobs, .resumePrinter:
            asking = Asked(action: action, check: check)
        default:
            Task { await run(action, check) }
        }
    }

    private func run(_ action: TroubleshootAction, _ check: TroubleshootCheck) async {
        if action == .printTestPage, let block = state.testPageBlock {
            footer = block
            return
        }
        let before: Int = state.errorsShown
        await state.perform(action, for: check)
        footer = state.errorDetail(since: before) ?? (action == .printTestPage ? state.sentMessage : nil)
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await state.perform(.refresh)
        refreshing = false
    }

    private func copyDiagnostics() async {
        let before: Int = state.errorsShown
        await state.perform(.copyDiagnostics)
        footer = state.errorDetail(since: before) ?? "Copied to the clipboard."
    }
}

/// One check: the status symbol (named for VoiceOver), the title, the detail, its buttons and "More help" with the rest. A
/// check that passed and offers nothing to do is a compact row: its title, with what it found as its hint.
private struct CheckRow: View {
    let check: TroubleshootCheck
    let perform: (TroubleshootAction) -> Void

    /// The buttons of the card: every action but Refresh, which is the foot's.
    private var actions: [TroubleshootAction] { check.actions.filter { $0 != .refresh } }

    var body: some View {
        Group {
            if check.status == .ok && actions.isEmpty {
                passedRow
            } else {
                card
            }
        }
        .accessibilityIdentifier("troubleshooter.check." + check.id)
    }

    private var passedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(check.title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Troubleshooter.statusLabel(check.status)): \(check.title)")
        .accessibilityHint(Text(check.fullDetail))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(check.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(check.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Troubleshooter.statusLabel(check.status)): \(check.title). \(check.detail)")
            ForEach(actions, id: \.self) { (action: TroubleshootAction) in
                Button(Troubleshooter.label(action, platform: .ios)) { perform(action) }
                    .buttonStyle(.bordered)
                    .accessibilityHint(Text("\(Troubleshooter.statusLabel(check.status)): \(check.title)"))
                    .accessibilityIdentifier("troubleshooter.action." + action.rawValue)
            }
            if !check.more.isEmpty {
                DisclosureGroup("More help") {
                    Text(check.more)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel(Text("More help: \(check.title)"))
            }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch check.status {
        case .problem: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .ok: return "checkmark.circle.fill"
        case .tip: return "lightbulb"
        }
    }

    private var color: Color {
        switch check.status {
        case .problem: return .red
        case .warning: return .yellow
        case .ok: return .green
        case .tip: return .accentColor
        }
    }
}
#endif
