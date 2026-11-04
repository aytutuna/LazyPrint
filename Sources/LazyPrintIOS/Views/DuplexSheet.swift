#if os(iOS)
import LazyPrintKit
import SwiftUI

/// The two-sided card: where a job done by hand waits for the stack to go back in the tray, and the one-sheet check that
/// teaches the app how this printer takes it. It cannot be swiped away: the fronts are already printed, and a sheet that
/// closed on its own would lose the backs; Cancel is the way out, and while a pass runs it stops the pass. Twin of the
/// Mac's card.
struct DuplexSheet: View {
    @EnvironmentObject private var state: AppState
    @State private var showTroubleshooter = false

    var body: some View {
        if let card = state.duplexCard {
            content(card)
        }
    }

    private func content(_ card: DuplexCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: picture(card))
                        .font(.largeTitle)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.duplexTitle)
                            .font(.title3.weight(.semibold))
                            .accessibilityIdentifier("duplex.title")
                        Text(card.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("duplex.text")
                    }
                }
                VStack(spacing: 10) {
                    if state.isBusy {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(state.status)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("duplex.status")
                        }
                    }
                    VStack(spacing: 10) {
                        buttons(card)
                    }
                    .disabled(state.isBusy)
                    Button("Cancel") {
                        if state.isBusy {
                            state.cancelJob()
                        } else {
                            state.cancelManualDuplex()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("duplex.cancel")
                }
            }
            .padding(20)
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium, .large])
        .printCertificateAlert(state)
        .errorAlert(onTroubleshoot: { showTroubleshooter = true })
        .sheet(isPresented: $showTroubleshooter) {
            TroubleshooterScreen()
        }
    }

    @ViewBuilder
    private func buttons(_ card: DuplexCard) -> some View {
        switch card.step {
        case .reload:
            Button(ManualDuplexText.backsTitle) { Task { await state.printBacks() } }
                .buttonStyle(.borderedProminent)
                .tint(Color("PrintFill"))
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("duplex.printBacks")
            Button("Check with one sheet") { Task { await state.checkDuplex() } }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("duplex.check")
        case .checkBack:
            Button("Print the back") { Task { await state.printCheckBack() } }
                .buttonStyle(.borderedProminent)
                .tint(Color("PrintFill"))
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("duplex.printBack")
        case .checkAnswer:
            ForEach([DuplexCheckAnswer.bothOnOneSide, .oppositeEdges, .sameEdge], id: \.self) { (answer: DuplexCheckAnswer) in
                Button(ManualDuplexText.answer(answer)) { state.answerDuplexCheck(answer) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("duplex.answer." + answer.rawValue)
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
