#if os(iOS)
import LazyPrintKit
import SwiftUI

/// The alert that asks for the password of a locked PDF. Cancel leaves the file out.
struct PasswordAlert: ViewModifier {
    let request: PasswordRequest?
    let answer: (String?) -> Void
    @State private var password: String = ""

    func body(content: Content) -> some View {
        content.alert(DocumentText.passwordTitle, isPresented: Binding(get: { request != nil }, set: { (_: Bool) in }),
                      presenting: request) { (_: PasswordRequest) in
            SecureField("Password", text: $password)
            Button("Open") {
                answer(password)
                password = ""
            }
            Button("Cancel", role: .cancel) {
                answer(nil)
                password = ""
            }
        } message: { (request: PasswordRequest) in
            Text(DocumentText.passwordMessage(request.name, wrong: request.wrong))
        }
    }
}

extension View {
    /// The question about a locked PDF, on the view in front: a sheet holds an alert of the screen behind it.
    func passwordAlert(_ state: AppState) -> some View {
        modifier(PasswordAlert(request: state.passwordRequest) { (password: String?) in
            if let password {
                state.submitPassword(password)
            } else {
                state.skipPassword()
            }
        })
    }
}
#endif
