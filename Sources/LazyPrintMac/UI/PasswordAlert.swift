#if os(macOS)
import LazyPrintKit
import SwiftUI

/// The alert that asks for the password of a locked PDF. Cancel leaves the file out.
struct PasswordAlert: ViewModifier {
    let request: PasswordRequest?
    let answer: (String?) -> Void
    @State private var password = ""

    func body(content: Content) -> some View {
        content.alert(DocumentText.passwordTitle, isPresented: Binding(get: { request != nil }, set: { _ in }),
                      presenting: request) { _ in
            SecureField("Password", text: $password)
            Button("Open") {
                answer(password)
                password = ""
            }
            Button("Cancel", role: .cancel) {
                answer(nil)
                password = ""
            }
        } message: { request in
            Text(DocumentText.passwordMessage(request.name, wrong: request.wrong))
        }
    }
}

extension View {
    func passwordAlert(_ state: AppState) -> some View {
        modifier(PasswordAlert(request: state.passwordRequest) { password in
            if let password {
                state.submitPassword(password)
            } else {
                state.skipPassword()
            }
        })
    }
}
#endif
