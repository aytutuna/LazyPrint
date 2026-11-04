#if os(iOS)
import LazyPrintKit
import SwiftUI

/// What the add screen says that the Mac's sheet does not: the system refuses plain `ipp://` to a name with dots that is
/// not a `.local` name (App Transport Security allows local networking only for addresses, unqualified names and
/// `.local`). The screen tries `ipps://` for such a name, and says so before trying only when there is no ipps to try.
enum AddPrinterText {
    static let useAddress = "Use the printer's IP address or its .local name."
    static let localNetworkOff = "Local Network access is off. Turn it on for Lazy Print in Settings."

    /// `useAddress` for an address iOS would refuse, else nil.
    static func problem(for address: PrinterAddress) -> String? {
        guard !address.secure else { return nil }
        let host: String = address.host.lowercased()
        let isNumber: Bool = host.contains(":") || host.allSatisfy { (c: Character) -> Bool in c.isNumber || c == "." }
        if isNumber || !host.contains(".") || host.hasSuffix(".local") { return nil }
        return useAddress
    }

    /// An error of the session about App Transport Security (-1022) reads the same.
    static func message(for error: String) -> String {
        error.contains("-1022") || error.localizedCaseInsensitiveContains("App Transport Security") ? useAddress : error
    }
}

/// "Add printer by address": checks that a printer answers Get-Printer-Attributes at the typed address (asking first when
/// it presents a certificate to trust), then lists it and uses it. Pushed on the printers' stack and the troubleshooter's.
struct AddPrinterScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var message: String?
    @State private var isProblem = false
    @State private var denied = false
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
        Form {
            Section {
                TextField("e.g. 192.168.1.50 or printer.local", text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .disabled(checking)
                    .onSubmit { Task { await add() } }
                    .onChange(of: text) { (_: String, _: String) in
                        if !checking {
                            message = nil
                            denied = false
                        }
                    }
                    .accessibilityIdentifier("add.address")
            } header: {
                Text("Address")
            } footer: {
                Text("Most network printers appear on their own. The address is on the printer's screen, its network settings page or a configuration page it prints.")
            }
            if let message {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        if checking {
                            ProgressView()
                        } else if isProblem {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .accessibilityHidden(true)
                        }
                        Text(message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("add.message")
                }
            }
            if denied {
                Section {
                    Button("Open Settings") { Task { await state.perform(.openAppSettings) } }
                        .accessibilityIdentifier("add.settings")
                }
            }
            Section {
                Button("Add") { Task { await add() } }
                    .disabled(checking || text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("add.button")
            }
        }
        .navigationTitle("Add a printer")
        .navigationBarTitleDisplayMode(.inline)
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
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiter.continuation = continuation
        }
    }

    private func answer(_ trusted: Bool) {
        certificate = nil
        waiter.continuation?.resume(returning: trusted)
        waiter.continuation = nil
    }

    /// True when the system keeps the app off the local network: the browser says so, or a connection to the address waits
    /// for access that was refused.
    private func localNetworkRefused(_ address: PrinterAddress) async -> Bool {
        if state.networkPrinters.discovery == .denied { return true }
        return await IOSLocalNetworkProbe().isDenied(host: address.host, port: address.port)
    }

    /// Checks the address and adds the printer; the screen closes once it is added.
    private func add() async {
        guard !checking else { return }
        let typed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parseError: String = ""
        guard var address = PrinterAddress.tryParse(typed, error: &parseError) else {
            problem(parseError)
            focused = true
            return
        }
        let secure: PrinterAddress? = address.httpsFallback(typed: typed)
        if let refused = AddPrinterText.problem(for: address) {
            // The system refuses plain ipp to this name, but ipps is not refused.
            guard let secure else {
                problem(refused)
                focused = true
                return
            }
            address = secure
        }
        let network: any NetworkPrinters = state.networkPrinters
        checking = true
        denied = false
        defer { checking = false }

        progress("Connecting to \(address)\u{2026}")
        var result: AddressCheck = await network.check(address, firstUse: nil)
        if result.capabilities == nil, result.certificate == nil, await localNetworkRefused(address) {
            denied = true
            problem(AddPrinterText.localNetworkOff)
            return
        }
        // A bare host that did not answer over plain ipp may serve ipps.
        if result.capabilities == nil, result.certificate == nil, let secure, address != secure {
            address = secure
            progress("Connecting to \(address)\u{2026}")
            result = await network.check(address, firstUse: nil)
        }
        if closed { return }

        // A new certificate is trusted once the printer's UUID shows it is not a changed certificate of a printer
        // trusted before; a changed one is asked about as such.
        var firstUseAsked: Bool = false
        var trusted: Bool = false
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
        problem(result.certificate?.message ?? AddPrinterText.message(for: result.error ?? "No printer answered at \(address)."))
    }
}
#endif
