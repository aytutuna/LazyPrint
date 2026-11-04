#if os(iOS)
import LazyPrintKit
import SwiftUI

/// The alert that asks whether to trust a printer's certificate: a new one is trusted on first use, as Lazy Scan does; a
/// changed one is asked about with a warning, and Cancel is the safe answer.
struct CertificateAlert: ViewModifier {
    let certificate: IppCertificateError?
    /// The printer as the text names it: its name, or "the printer at host:port" when it was typed.
    let printer: String
    /// The trust button's text for a certificate not seen before: "Trust and connect", "Trust and add".
    let trustTitle: String
    let decide: (Bool) -> Void

    private var changed: Bool { certificate?.verdict == .changed }

    func body(content: Content) -> some View {
        content.alert(changed ? "Printer certificate changed" : "Trust \(printer)?",
                      isPresented: Binding(get: { certificate != nil }, set: { (_: Bool) in }),
                      presenting: certificate) { (certificate: IppCertificateError) in
            if certificate.verdict == .changed {
                Button("Cancel", role: .cancel) { decide(false) }
                Button("Trust the new certificate", role: .destructive) { decide(true) }
            } else {
                Button(trustTitle) { decide(true) }
                Button("Cancel", role: .cancel) { decide(false) }
            }
        } message: { (certificate: IppCertificateError) in
            Text(message(certificate))
        }
    }

    private func message(_ certificate: IppCertificateError) -> String {
        var text: String
        if certificate.verdict == .changed {
            let trustedOn: String = certificate.previous?.trusted.map { " on " + $0.formatted(date: .numeric, time: .omitted) } ?? ""
            text = "The certificate of \(printer) has changed. It identified itself with a different certificate from the one "
                + "you trusted\(trustedOn). A firmware update or a reset of the printer can change it, but so can another "
                + "device on the network that pretends to be your printer. Trust the new certificate only if you know why it "
                + "changed. Otherwise choose Cancel and check the printer."
        } else {
            text = "This printer offers an encrypted connection and identifies itself with a certificate it made itself. "
                + "iOS cannot vouch for such certificates; that is normal for printers. Trust it if this is your printer. "
                + "Lazy Print remembers the certificate and warns you if it ever changes."
        }
        text += "\n\nAddress: \(certificate.authority)"
        if !certificate.subject.isEmpty { text += "\nIssued to: \(certificate.subject)" }
        text += "\n\(certificate.verdict == .changed ? "New fingerprint" : "Fingerprint"):\n"
            + IppCertificates.format(certificate.fingerprint, bytesPerLine: 16)
        return text
    }
}

extension View {
    /// The question about a printer's certificate during a print or a choice, on the view in front: a sheet is a
    /// presentation of its own, and an alert of the screen behind it would not show.
    func printCertificateAlert(_ state: AppState) -> some View {
        modifier(CertificateAlert(certificate: state.certificateRequest?.certificate, printer: state.certificateRequest?.name ?? "",
                                  trustTitle: "Trust and connect") { (trusted: Bool) in
            if trusted {
                Task { await state.trustCertificate() }
            } else {
                state.declineCertificate()
            }
        })
    }
}
#endif
