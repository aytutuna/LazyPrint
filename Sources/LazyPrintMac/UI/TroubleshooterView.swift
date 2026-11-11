#if os(macOS)
import LazyPrintKit
import SwiftUI

/// "Why isn't my printer listed?": one line saying what is listed and how many problems and warnings there are
/// (`Troubleshooter.overview`), then the checks: a card for each one to look at, with its status, one line, the buttons that
/// help and "More help" with the rest; a compact row for each check that passed. Copy Diagnostics and Refresh are in the
/// footer. Shown as a sheet from the sidebar and from an error about a printer. Twin of the Windows `TroubleshooterWindow`.
struct TroubleshooterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Add by address is the add sheet's own: the caller is told, and opens it once this one has closed.
    var onAddByAddress: () -> Void = {}

    /// What the footer says after Copy Diagnostics or a button that opens something.
    @State private var footerMessage: String?
    @State private var refreshing = false
    /// An action that changes something, waiting for the user's yes.
    @State private var asking: Asked?

    private struct Asked: Identifiable {
        let action: TroubleshootAction
        let check: TroubleshootCheck
        var id: String { check.id + action.rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Why isn't my printer listed?")
                    .font(.title2.weight(.semibold))
                Text(refreshing ? "Looking for printers\u{2026}" : Troubleshooter.overview(state.snapshot, checks: state.troubleshootChecks))
                    .font(.headline)
                    .padding(.top, 4)
            }
            .padding(20)
            .accessibilityElement(children: .combine)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(state.troubleshootChecks, id: \.id) { check in
                        TroubleshootCheckCard(check: check) { action in act(action, check) }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await copyDiagnostics() }
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
                .help("Copy the results to send to support")
                if let footerMessage {
                    Text(footerMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(footerMessage)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Check again")
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 440, idealHeight: 620)
        .task { await state.openTroubleshooter() }
        .confirmationDialog(asking.map { Troubleshooter.label($0.action, platform: .mac) + "?" } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { asked in
            Button(Troubleshooter.label(asked.action, platform: .mac)) {
                Task { await run(asked.action, asked.check) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { asked in
            Text(asked.check.title + ".")
        }
        .printCertificateAlert(state)
    }

    private func act(_ action: TroubleshootAction, _ check: TroubleshootCheck) {
        switch action {
        case .refresh:
            Task { await refresh() }
        case .copyDiagnostics:
            Task { await copyDiagnostics() }
        case .addByAddress:
            onAddByAddress()
            dismiss()
        case .clearStuckJobs, .resumePrinter:
            asking = Asked(action: action, check: check)
        default:
            Task { await run(action, check) }
        }
    }

    private func run(_ action: TroubleshootAction, _ check: TroubleshootCheck) async {
        if action == .printTestPage, let block = state.testPageBlock {
            footerMessage = block
            return
        }
        let before = state.errorsShown
        await state.perform(action, for: check)
        footerMessage = state.errorDetail(since: before) ?? (action == .printTestPage ? state.sentMessage : nil)
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await state.perform(.refresh)
        refreshing = false
    }

    private func copyDiagnostics() async {
        let before = state.errorsShown
        await state.perform(.copyDiagnostics)
        footerMessage = state.errorDetail(since: before) ?? "Copied to the clipboard."
    }
}

/// One check: the status symbol (named for VoiceOver), the title, the one-line detail, its buttons and "More help" with the
/// rest. A check that passed and offers nothing to do is a compact row: its title, with what it found as its help.
struct TroubleshootCheckCard: View {
    let check: TroubleshootCheck
    let perform: (TroubleshootAction) -> Void

    /// The buttons of the card: every action but Refresh, which is the footer's.
    private var actions: [TroubleshootAction] { check.actions.filter { $0 != .refresh } }

    var body: some View {
        if check.status == .ok && actions.isEmpty {
            passedRow
        } else {
            card
        }
    }

    private var passedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityLabel(Troubleshooter.statusLabel(check.status))
            Text(check.title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .help(check.fullDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Troubleshooter.statusLabel(check.status)): \(check.title)")
        .accessibilityHint(Text(check.fullDetail))
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityLabel(Troubleshooter.statusLabel(check.status))
            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(check.detail)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.self) { action in
                            // The hint adds which check the button is for (several cards offer the same one).
                            Button(Troubleshooter.label(action, platform: .mac)) { perform(action) }
                                .accessibilityHint(Text("\(Troubleshooter.statusLabel(check.status)): \(check.title)"))
                        }
                    }
                    .padding(.top, 4)
                }
                if !check.more.isEmpty {
                    DisclosureGroup("More help") {
                        Text(check.more)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                    .padding(.top, 2)
                    .accessibilityLabel(Text("More help: \(check.title)"))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Troubleshooter.statusLabel(check.status)): \(check.title)")
        .accessibilityHint(Text(check.fullDetail))
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
