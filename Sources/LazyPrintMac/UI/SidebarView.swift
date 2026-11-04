#if os(macOS)
import LazyPrintKit
import SwiftUI

/// Left column: the printers. Each row has the printer's name, a state dot, a one-line problem when it has one and its ink
/// or toner as thin bars; the demo printer is last, with a menu of switches. Twin of the Windows side pane.
struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Binding var showTroubleshooter: Bool
    @Binding var showAddPrinter: Bool
    @Binding var showPhone: Bool

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(state.printers) { printer in
                    PrinterRow(printer: printer)
                        .tag(printer.id)
                        .contextMenu {
                            if printer.route == .demo {
                                Toggle("Prints both sides", isOn: Binding(
                                    get: { state.demo.duplex },
                                    set: { on in Task { await state.setDemoDuplex(on) } }))
                                Toggle("Out of paper", isOn: Binding(
                                    get: { state.demo.outOfPaper },
                                    set: { on in state.setDemoOutOfPaper(on) }))
                            }
                        }
                }
                if !state.hasRealPrinters {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No other printer found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button {
                            showTroubleshooter = true
                        } label: {
                            Text("Troubleshoot").underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .font(.callout)
                        .help("Why isn't my printer listed?")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Printers")
                    Spacer()
                    // Until a printer is listed, the Troubleshoot link in the list is the one way in.
                    if state.hasRealPrinters {
                        Button {
                            showTroubleshooter = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Why isn't my printer listed?")
                        .accessibilityLabel("Why isn't my printer listed?")
                    }
                    Button {
                        showPhone = true
                    } label: {
                        Image(systemName: "iphone")
                    }
                    .buttonStyle(.borderless)
                    .help("Print from your phone")
                    .accessibilityLabel("Print from your phone")
                    Button {
                        showAddPrinter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a printer by its address")
                    .accessibilityLabel("Add printer by address")
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The printer in use; picking another reads what it can do and lays the job out again.
    private var selection: Binding<String?> {
        Binding(
            get: { state.selectedPrinter?.id },
            set: { id in
                guard let id else { return }
                Task { await state.selectPrinter(id) }
            })
    }
}

private struct PrinterRow: View {
    let printer: PrinterInfo

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: printer.route == .demo ? "sparkles.rectangle.stack" : "printer")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if printer.route == .demo {
                    Text("Demo (no hardware)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let problem = printer.problems.first {
                    Text(problem.title)
                        .font(.caption)
                        .foregroundStyle(problem.isError ? Color.red : Color.orange)
                        .lineLimit(1)
                }
                if !printer.supplies.isEmpty {
                    SupplyBars(supplies: printer.supplies)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            Circle()
                .fill(dot)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var dot: Color {
        switch printer.state {
        case .idle: return .green
        case .printing: return .blue
        case .stopped: return .red
        case .offline, .unknown: return .gray
        }
    }

    private var label: String {
        var text = printer.name
        if printer.route == .demo { text += ", demo, no hardware" }
        if let problem = printer.problems.first { text += ", " + problem.title }
        return text
    }
}

/// A thin bar for each ink or toner, in its color and filled to its level.
private struct SupplyBars: View {
    let supplies: [Supply]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // A supply whose level is not known has no bar, as on Windows.
        let known = supplies.filter { $0.level != nil }
        HStack(spacing: 3) {
            ForEach(known.indices, id: \.self) { index in
                bar(known[index])
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private func bar(_ supply: Supply) -> some View {
        let color = supply.isLow ? Color(red: 0xE0 / 255, green: 0x9B / 255, blue: 0) : fill(supply.color)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
            GeometryReader { geometry in
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(supply.level ?? 0) / 100)
            }
        }
    }

    /// "#RRGGBB" as the printers report it; gray for anything else. Black ink would vanish into a dark sidebar, so a
    /// color that dark is drawn as a mid gray there.
    private func fill(_ text: String?) -> Color {
        guard let text, text.hasPrefix("#"), text.count == 7, let value = UInt32(text.dropFirst(), radix: 16) else {
            return .gray
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        if scheme == .dark && 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.15 { return Color(white: 0.6) }
        return Color(red: red, green: green, blue: blue)
    }
}
#endif
