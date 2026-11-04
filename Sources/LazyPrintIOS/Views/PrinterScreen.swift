#if os(iOS)
import LazyPrintKit
import SwiftUI

/// One printer: its name, state, problems and supplies, the test page, the demo printer's switches, and for the printer in
/// use whether the check for two-sided printing by hand was done. `close` closes the printers' sheet, so the result of the
/// test page shows in the bars behind it.
struct PrinterScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme
    let printerId: String
    let close: () -> Void

    var body: some View {
        Group {
            if let printer = state.printers.first(where: { $0.id == printerId }) {
                form(printer)
            } else {
                Text("This printer is no longer listed.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(state.printers.first(where: { $0.id == printerId })?.name ?? "Printer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ printer: PrinterInfo) -> some View {
        Form {
            Section {
                LabeledContent("State", value: Self.stateText(printer.state))
                    .accessibilityIdentifier("printer.state")
                if let model = printer.model {
                    LabeledContent("Model", value: model)
                }
                if let address = printer.address {
                    LabeledContent("Address", value: address)
                }
                if printer.id == state.selectedPrinter?.id {
                    LabeledContent("Two-sided by hand", value: state.selectedPrefs.paperPath.checked ? "Checked" : "Not checked yet")
                }
            }
            if !printer.problems.isEmpty {
                Section {
                    ForEach(printer.problems.indices, id: \.self) { (index: Int) in
                        let problem: PrinterProblem = printer.problems[index]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(problem.title)
                                .foregroundStyle(problem.isError ? Color.red : Color.orange)
                            Text(problem.advice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !printer.supplies.isEmpty {
                Section("Supplies") {
                    ForEach(printer.supplies.indices, id: \.self) { (index: Int) in
                        supply(printer.supplies[index])
                    }
                }
            }
            if printer.route == .demo {
                DemoSwitches(demo: state.demo)
            }
            Section {
                Button("Print a test page") {
                    Task {
                        await state.selectPrinter(printer.id)
                        let before: Int = state.errorsShown
                        await state.printTestPage()
                        // A failure is shown by the alert of the sheet, which must stay to show it.
                        if state.errorsShown == before { close() }
                    }
                }
                .disabled(state.isBusy || state.duplexCard != nil)
                .accessibilityIdentifier("printer.testPage")
            }
        }
    }

    private func supply(_ supply: Supply) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(supply.name)
                Spacer(minLength: 8)
                Text(supply.level.map { "\($0) %" } ?? "Unknown")
                    .foregroundStyle(supply.isLow ? Color.orange : Color.secondary)
            }
            if let level = supply.level {
                ProgressView(value: Double(level), total: 100)
                    .tint(SupplyBars.color(supply, dark: scheme == .dark))
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func stateText(_ state: PrinterState) -> String {
        switch state {
        case .idle: return "Ready"
        case .printing: return "Printing"
        case .stopped: return "Stopped"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}

/// The demo printer's switches: two-sided or not, and out of paper, to try the two-sided card and the troubleshooter.
private struct DemoSwitches: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var demo: DemoPrinterState

    var body: some View {
        Section {
            Toggle("Prints both sides", isOn: Binding(get: { demo.duplex }, set: { (on: Bool) in
                Task { await state.setDemoDuplex(on) }
            }))
            .accessibilityIdentifier("printer.duplex")
            Toggle("Out of paper", isOn: Binding(get: { demo.outOfPaper }, set: { (on: Bool) in
                state.setDemoOutOfPaper(on)
            }))
            .accessibilityIdentifier("printer.outOfPaper")
        } header: {
            Text("Demo printer")
        }
    }
}
#endif
