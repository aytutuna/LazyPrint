#if os(macOS)
import LazyPrintKit
import SwiftUI

/// The two-sided card: where a job done by hand waits for the stack to go back in the tray, and the one-sheet check that
/// teaches the app how this printer takes it. Escape only moves to Cancel: the fronts are already printed, and a sheet
/// that closed on its own would lose the backs. Twin of the Windows overlay.
struct DuplexSheet: View {
    @EnvironmentObject var state: AppState
    @FocusState private var cancelFocused: Bool

    var body: some View {
        if let card = state.duplexCard {
            content(card)
        }
    }

    private func content(_ card: DuplexCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: picture(card))
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.duplexTitle)
                        .font(.title3.weight(.semibold))
                    Text(card.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if state.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                buttons(card)
                Button("Cancel") { state.cancelManualDuplex() }
                    .focused($cancelFocused)
            }
            .disabled(state.isBusy)
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
        .onExitCommand { cancelFocused = true }
        .printCertificateAlert(state)
    }

    @ViewBuilder
    private func buttons(_ card: DuplexCard) -> some View {
        switch card.step {
        case .reload:
            Button("Check with one sheet") { Task { await state.checkDuplex() } }
                .help("Prints a numbered sheet to learn how this printer takes the stack back")
            Button(ManualDuplexText.backsTitle) { Task { await state.printBacks() } }
                .keyboardShortcut(.defaultAction)
        case .checkBack:
            Button("Print the back") { Task { await state.printCheckBack() } }
                .keyboardShortcut(.defaultAction)
        case .checkAnswer:
            ForEach([DuplexCheckAnswer.bothOnOneSide, .oppositeEdges, .sameEdge], id: \.self) { answer in
                Button(ManualDuplexText.answer(answer)) { state.answerDuplexCheck(answer) }
            }
        }
    }

    /// Turn the stack over, or put it back as it lies.
    private func picture(_ card: DuplexCard) -> String {
        switch card.step {
        case .reload: return state.duplexPaperPath.turnStackOver ? "arrow.triangle.2.circlepath" : "tray.and.arrow.down"
        case .checkBack: return "tray.and.arrow.down"
        case .checkAnswer: return "questionmark.circle"
        }
    }
}
#endif
