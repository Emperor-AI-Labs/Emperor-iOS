import SwiftUI

/// Asking for a password-reset link.
///
/// Worded carefully, because three things here are not what a user would assume:
///
/// 1. The route answers 200 whether or not the address has an account — deliberately, so it
///    never leaks which emails exist. So the confirmation cannot be conditional.
/// 2. The link is a **web** URL, so the reset finishes in a browser rather than here.
/// 3. Delivery depends on SMTP, which the platform ships **disabled**. If mail is not
///    configured nothing arrives and no error is raised anywhere — which is why the copy
///    points at the administrator rather than promising an inbox.
struct PasswordResetSheet: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var email: String
    @FocusState private var isFocused: Bool

    init(email: String) {
        _email = State(initialValue: email)
    }

    var body: some View {
        NavigationStack {
            Form {
                if session.passwordResetSent {
                    Section {
                        Label {
                            Text(Session.passwordResetNotice)
                                .font(.brand(.callout))
                        } icon: {
                            Image(systemName: "envelope")
                                .foregroundStyle(theme.accentText)
                        }
                    }
                } else {
                    Section {
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isFocused)
                            .submitLabel(.send)
                            .onSubmit(send)
                    } footer: {
                        Text("We will email a link to reset your password.")
                    }
                }

                if let error = session.signInError {
                    Section {
                        Text(error)
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.danger)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session.passwordResetSent ? "Done" : "Cancel") {
                        session.clearPasswordResetNotice()
                        dismiss()
                    }
                }
                if !session.passwordResetSent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", action: send)
                            .disabled(
                                email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || session.isWorking)
                    }
                }
            }
            .onAppear { isFocused = email.isEmpty }
        }
    }

    private func send() {
        Task { await session.requestPasswordReset(email: email) }
    }
}
