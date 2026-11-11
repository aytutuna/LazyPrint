#if os(iOS)
import LazyPrintKit
import SwiftUI

/// The red, green and blue of a supply as a printer reports it ("#RRGGBB").
enum SupplyColor {
    typealias Components = (red: Double, green: Double, blue: Double)

    /// Each of the three from 0 to 1; nil for anything but "#" and six hex digits.
    static func components(_ text: String?) -> Components? {
        guard let text, text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else { return nil }
        return (red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255)
    }

    /// Black ink would vanish into a dark screen, so a color this dark is drawn as a mid gray there.
    static func isNearBlack(_ color: Components) -> Bool {
        0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue < 0.15
    }
}

/// The state dot's color.
func stateColor(_ state: PrinterState) -> Color {
    switch state {
    case .idle: return .green
    case .printing: return .blue
    case .stopped: return .red
    case .offline, .unknown: return .gray
    }
}

/// A printer as the lists show it: its icon, name, a one-line problem, its ink or toner as thin bars and its state dot;
/// the demo printer says it is no hardware.
struct PrinterLabel: View {
    let printer: PrinterInfo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: printer.route == .demo ? "sparkles.rectangle.stack" : "printer")
                .foregroundStyle(.secondary)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(printer.name)
                    .lineLimit(2)
                if printer.route == .demo {
                    Text("Demo (no hardware)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let problem = printer.problems.first {
                    Text(problem.title)
                        .font(.caption)
                        .foregroundStyle(problem.isError ? Color.red : Color.orange)
                        .lineLimit(2)
                }
                if !printer.supplies.isEmpty {
                    SupplyBars(supplies: printer.supplies)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            Circle()
                .fill(stateColor(printer.state))
                .frame(width: 10, height: 10)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        var text: String = printer.name
        if printer.route == .demo { text += ", demo, no hardware" }
        if let problem = printer.problems.first { text += ", " + problem.title }
        return text
    }
}

/// A thin bar for each ink or toner, in its color and filled to its level. A supply whose level is not known has none.
struct SupplyBars: View {
    let supplies: [Supply]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let known: [Supply] = supplies.filter { $0.level != nil }
        HStack(spacing: 3) {
            ForEach(known.indices, id: \.self) { (index: Int) in
                bar(known[index])
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func bar(_ supply: Supply) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
            GeometryReader { (geometry: GeometryProxy) in
                Capsule()
                    .fill(SupplyBars.color(supply, dark: scheme == .dark))
                    .frame(width: geometry.size.width * CGFloat(supply.level ?? 0) / 100)
            }
        }
    }

    static func color(_ supply: Supply, dark: Bool) -> Color {
        if supply.isLow { return Color(red: 0xE0 / 255, green: 0x9B / 255, blue: 0) }
        guard let rgb = SupplyColor.components(supply.color) else { return .gray }
        if dark && SupplyColor.isNearBlack(rgb) { return Color(white: 0.6) }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// The printer in use, at the top of the Start and Print screens; it opens the printers.
struct PrinterButton: View {
    @EnvironmentObject private var state: AppState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let printer = state.selectedPrinter {
                    PrinterLabel(printer: printer)
                } else {
                    Label(state.missingPrinterMessage ?? "No printer", systemImage: "printer")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .accessibilityIdentifier("printer.button")
        .accessibilityHint("Shows the printers")
    }
}

/// The printers: the one in use is ticked, and a row opens the printer's page. Below them the AirPrint printer picker,
/// Add by address and the troubleshooter, then My computer: pairing, the paired computer's state and Forget. Shown as a
/// sheet.
struct PrintersScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    /// The AirPrint printer the phone chose last; nil where it is not offered (the demo printer alone).
    let airPrint: IOSPrinterSystem?
    /// Looks for the paired computer on the network while its screen is open; nil under `-demoPrinter`.
    let companion: IOSCompanionBrowser?
    /// A pairing link that was opened: My computer opens with it, as with a scanned code.
    @Binding var pairingLink: String?
    @State private var showTroubleshooter = false
    @State private var showAdd = false
    @State private var showComputer = false
    @State private var confirmingForget = false
    @State private var infoId: String?
    /// A printer was picked whose certificate is being asked about: the sheet closes with the answer.
    @State private var closeWhenAnswered = false
    /// Why the AirPrint picker did not open.
    @State private var pickerProblem: String?
    /// The AirPrint row's own view, which the system's picker comes out of on an iPad.
    @State private var pickerAnchor: UIView?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(state.printers) { (printer: PrinterInfo) in
                        row(printer)
                    }
                    if !state.hasRealPrinters {
                        Text("No other printer found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("printers.none")
                    }
                } header: {
                    Text("Printers")
                }
                if state.networkPrinters.discovery == .denied {
                    Section {
                        Button {
                            Task { await state.perform(.openAppSettings) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Local Network is off")
                                    .foregroundStyle(.primary)
                                Text("Turn it on in Settings to find printers.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("printers.localNetwork")
                    }
                }
                Section {
                    if let airPrint {
                        Button("Choose an AirPrint printer\u{2026}") {
                            Task { await choose(airPrint) }
                        }
                        .accessibilityIdentifier("printers.airprint")
                        .background(AnchorView(view: $pickerAnchor))
                        if let pickerProblem {
                            Text(pickerProblem)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("printers.airprint.problem")
                        }
                    }
                    Button("Add by address") { showAdd = true }
                        .accessibilityIdentifier("printers.add")
                    Button("Troubleshoot") { showTroubleshooter = true }
                        .accessibilityIdentifier("printers.troubleshoot")
                }
                Section {
                    computerRows
                } header: {
                    Text(IOSCompanionText.title)
                }
            }
            .navigationTitle("Printers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("printers.done")
                }
            }
            .navigationDestination(item: $infoId) { (id: String) in
                PrinterScreen(printerId: id, close: { dismiss() })
            }
            .navigationDestination(isPresented: $showAdd) {
                AddPrinterScreen()
            }
            .navigationDestination(isPresented: $showComputer) {
                CompanionScreen(state: state, browser: companion, link: $pairingLink)
            }
        }
        .onChange(of: pairingLink, initial: true) { (_: String?, link: String?) in
            if link != nil { showComputer = true }
        }
        .sheet(isPresented: $showTroubleshooter) {
            TroubleshooterScreen()
        }
        .printCertificateAlert(state)
        .errorAlert(onTroubleshoot: { showTroubleshooter = true })
        .task {
            if state.companionDesktop != nil, state.companionStatus == .checking {
                await state.checkDesktop()
            }
        }
        .onChange(of: state.certificateRequest) { (_: CertificateRequest?, request: CertificateRequest?) in
            if request == nil && closeWhenAnswered {
                closeWhenAnswered = false
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var computerRows: some View {
        if let desktop = state.companionDesktop {
            Button {
                showComputer = true
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(desktop.name)
                            .foregroundStyle(.primary)
                        Text(IOSCompanionText.status(state.companionStatus))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("printers.computer")
            Button(IOSCompanionText.forgetButton, role: .destructive) {
                confirmingForget = true
            }
            .accessibilityIdentifier("printers.computer.forget")
            .confirmForget(of: desktop.name, isPresented: $confirmingForget, identifier: "printers.computer.forget.confirm") {
                Task { await state.unpairDesktop() }
            }
        } else {
            Button(IOSCompanionText.pairTitle) { showComputer = true }
                .accessibilityIdentifier("printers.computer.pair")
        }
    }

    /// Closes the sheet, unless the printer picked has a certificate to ask about: the question is this sheet's to show.
    private func finish() {
        if state.certificateRequest == nil {
            dismiss()
        } else {
            closeWhenAnswered = true
        }
    }

    private func row(_ printer: PrinterInfo) -> some View {
        let selected: Bool = printer.id == state.selectedPrinter?.id
        return HStack(spacing: 8) {
            Button {
                Task {
                    await state.selectPrinter(printer.id)
                    finish()
                }
            } label: {
                HStack(spacing: 8) {
                    PrinterLabel(printer: printer)
                    if selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("printers.row." + printer.id)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button {
                infoId = printer.id
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About \(printer.name)")
            .accessibilityIdentifier("printers.info." + printer.id)
        }
    }

    /// The system's printer picker; the printer chosen is the one used.
    private func choose(_ airPrint: IOSPrinterSystem) async {
        pickerProblem = nil
        let picked: Bool
        do {
            picked = try await airPrint.choose(from: pickerAnchor)
        } catch {
            pickerProblem = error.localizedDescription
            return
        }
        guard picked else { return }
        await state.refreshPrinters()
        await state.selectPrinter("system:" + airPrint.queueName)
        finish()
    }
}

/// Hands back the UIView behind a row, since a rectangle from SwiftUI's global space is not the window's inside a sheet.
private struct AnchorView: UIViewRepresentable {
    @Binding var view: UIView?

    func makeUIView(context: Context) -> UIView {
        let made: UIView = UIView()
        made.isUserInteractionEnabled = false
        DispatchQueue.main.async { view = made }
        return made
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
