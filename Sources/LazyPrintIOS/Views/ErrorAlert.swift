#if os(iOS)
import LazyPrintKit
import SwiftUI

/// The error as an alert, for the screens that sit over the root view's error bar (the printers, the two-sided card): a
/// sheet hides the bar, and an error that comes while the sheet is up must not wait behind it. Only an error that arrives
/// while the view is on screen is shown, so opening a sheet does not bring up one the bar already shows. OK clears it;
/// Troubleshoot, when the error is about reaching a printer and the screen can open it, clears it and opens it.
struct ErrorAlert: ViewModifier {
    @EnvironmentObject private var state: AppState
    let onTroubleshoot: (() -> Void)?
    @State private var shown: AppError?

    func body(content: Content) -> some View {
        content
            .onChange(of: state.error) { (_: AppError?, error: AppError?) in
                if let error {
                    shown = error
                }
            }
            .alert(shown?.title ?? "", isPresented: Binding(get: { shown != nil }, set: { (on: Bool) in
                if !on { shown = nil }
            }), presenting: shown) { (error: AppError) in
                if error.suggestsTroubleshooter, let onTroubleshoot {
                    Button("Troubleshoot") {
                        state.dismissError()
                        onTroubleshoot()
                    }
                }
                Button("OK", role: .cancel) {
                    state.dismissError()
                }
            } message: { (error: AppError) in
                Text(error.detail)
            }
    }
}

extension View {
    func errorAlert(onTroubleshoot: (() -> Void)? = nil) -> some View {
        modifier(ErrorAlert(onTroubleshoot: onTroubleshoot))
    }
}
#endif
