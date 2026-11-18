#if os(macOS)
import LazyPrintKit
import SwiftUI

/// One printer: its state, model, address, problems and supplies, the demo printer's switches and a test page. Twin of the
/// Windows `PrinterDetailsWindow` and of the iPhone's `PrinterScreen`.
struct PrinterDetailsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let printerId: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let printer = state.printers.first(where: { $0.id == printerId }) {
                content(printer)
            } else {
                Text("This printer is no longer listed.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Print a test page") {
                    Task {
                        await state.selectPrinter(printerId)
                        await state.printTestPage()
                        dismiss()
                    }
                }
                .disabled(state.printers.first(where: { $0.id == printerId }) == nil || state.isBusy || state.isAddingFiles || state.duplexCard != nil)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func content(_ printer: PrinterInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(printer.name)
                .font(.title3.weight(.semibold))
            row("State", Self.stateText(printer.state))
            if let model = printer.model {
                row("Model", model)
            }
            if let address = printer.address {
                row("Address", address)
            }
            if printer.id == state.selectedPrinter?.id {
                row("Two-sided by hand", state.selectedPrefs.paperPath.checked ? "Checked" : "Not checked yet")
            }
            ForEach(printer.problems.indices, id: \.self) { (index: Int) in
                let problem: PrinterProblem = printer.problems[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title)
                        .foregroundStyle(problem.isError ? Color.red : Color.orange)
                    Text(problem.advice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 4)
            }
            if !printer.supplies.isEmpty {
                Text("Supplies")
                    .font(.headline)
                    .padding(.top, 8)
                ForEach(printer.supplies.indices, id: \.self) { (index: Int) in
                    supply(printer.supplies[index])
                }
            }
            if printer.route == .demo {
                Text("Demo printer")
                    .font(.headline)
                    .padding(.top, 8)
                Toggle("Prints both sides", isOn: Binding(
                    get: { state.demo.duplex },
                    set: { (on: Bool) in Task { await state.setDemoDuplex(on) } }))
                Toggle("Out of paper", isOn: Binding(
                    get: { state.demo.outOfPaper },
                    set: { (on: Bool) in state.setDemoOutOfPaper(on) }))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
                    .tint(supply.isLow ? Color.orange : nil)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func stateText(_ state: PrinterState) -> String {
        switch state {
        case .idle: return "Ready"
        case .printing: return "Printing"
        case .stopped: return "Stopped"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}
#endif
