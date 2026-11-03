#if os(macOS)
import LazyPrintKit
import SwiftUI

/// "Add printer by address": checks that a printer answers Get-Printer-Attributes at the typed address (asking first when it
/// presents a certificate to trust), then lists it and uses it. Twin of the Windows `AddPrinterWindow`.
struct AddPrinterView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var message: String?
    @State private var isProblem = false
    @State private var checking = false
    @State private var certificate: IppCertificateError?
    @State private var waiter = Waiter()
    @State private var closed = false
    @FocusState private var focused: Bool

    /// Holds the check while the user decides about a certificate.
    private final class Waiter {
        var continuation: CheckedContinuation<Bool, Never>?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a network printer")
                .font(.title3.weight(.semibold))
            Text("Most network printers appear on their own. The address is on the printer's screen, its network settings page or a configuration page it prints.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Address")
                    .font(.callout)
                TextField("e.g. 192.168.1.50 or printer.local", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .disabled(checking)
                    .onSubmit { Task { await add() } }
                    .onChange(of: text) { _, _ in
                        if !checking { message = nil }
                    }
                    .help("For example 192.168.1.50, printer.local, 192.168.1.50:8631 or ipps://192.168.1.50")
            }
            if let message {
                HStack(alignment: .top, spacing: 8) {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if isProblem {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { focused = true }
        .onDisappear {
            closed = true
            answer(false)
        }
        .modifier(CertificateAlert(certificate: certificate, printer: "the printer at \(certificate?.authority ?? "")",
                                   trustTitle: "Trust and add", decide: answer))
    }

    private func progress(_ text: String) {
        isProblem = false
        message = text
    }

    private func problem(_ text: String) {
        isProblem = true
        message = text
    }

    private func confirm(_ asked: IppCertificateError) async -> Bool {
        certificate = asked
        return await withCheckedContinuation { waiter.continuation = $0 }
    }

    private func answer(_ trusted: Bool) {
        certificate = nil
        waiter.continuation?.resume(returning: trusted)
        waiter.continuation = nil
    }

    /// Checks the address and adds the printer; the sheet closes once it is added.
    private func add() async {
        guard !checking else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parseError = ""
        guard var address = PrinterAddress.tryParse(typed, error: &parseError) else {
            problem(parseError)
            focused = true
            return
        }
        let secure = address.httpsFallback(typed: typed)
        let network = state.networkPrinters
        checking = true
        defer { checking = false }

        progress("Connecting to \(address)\u{2026}")
        var result = await network.check(address, firstUse: nil)
        // A bare host that did not answer over plain ipp may serve ipps.
        if result.capabilities == nil, result.certificate == nil, let secure {
            address = secure
            progress("Connecting to \(address)\u{2026}")
            result = await network.check(address, firstUse: nil)
        }
        if closed { return }

        // A new certificate is trusted once the printer's UUID shows it is not a changed certificate of a printer
        // trusted before; a changed one is asked about as such.
        var firstUseAsked = false
        var trusted = false
        while !trusted, let found = result.certificate, found.canTrust {
            progress("Confirm the printer's certificate to continue.")
            guard await confirm(found), !closed else {
                if !closed { problem("The printer was not added, because its certificate was not trusted.") }
                return
            }
            progress("Connecting to \(address)\u{2026}")
            if found.verdict == .unknown && !firstUseAsked {
                firstUseAsked = true
                result = await network.check(address, firstUse: found.fingerprint)
            } else {
                network.trust(found, deviceUuid: nil, name: found.deviceName)
                trusted = true
                result = await network.check(address, firstUse: nil)
            }
            if closed { return }
        }

        if let capabilities = result.capabilities {
            // The address that answered: the client may have moved from ipp to ipps on its own.
            network.add(result.address, capabilities: capabilities)
            await state.selectAdded(result.address)
            dismiss()
            return
        }
        problem(result.certificate?.message ?? result.error ?? "No printer answered at \(address).")
    }
}
#endif
