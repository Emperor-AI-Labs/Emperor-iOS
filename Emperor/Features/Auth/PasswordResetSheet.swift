import SwiftUI

/// Asking for a password-reset link.
///
/// Worded carefully, because three things here are not what a user would assume:
///
/// 1. The route answers 200 whether or not the address has an account — deliberately, so it
///    never leaks which emails exist. So the confirmation cannot be conditional.
/// 2. The link is a **web** URL, so the reset finishes in a browser rather than here.
/// 3. An account made with Google has no password to reset — the notice points it at a
///    one-time code instead.
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
        let flow = session.signInFlow
        NavigationStack {
            Form {
                if flow.passwordResetSent {
                    Section {
                        Label {
                            Text(SignInFlow.passwordResetNotice)
                                .font(.brand(.callout))
                                .foregroundStyle(theme.textPrimary)
                        } icon: {
                            Image(systemName: "envelope.badge")
                                .foregroundStyle(theme.accentText)
                        }
                    }
                    .listRowBackground(theme.surface)
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
                        Text("We'll email a link to reset your password. It opens in your browser.")
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                }

                if let error = flow.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.brand(.footnote))
                            .foregroundStyle(theme.danger)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.passwordResetSent ? "Done" : "Cancel") {
                        session.signInFlow.clearPasswordReset()
                        dismiss()
                    }
                }
                if !flow.passwordResetSent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send", action: send)
                            .disabled(!SignInFlow.isPlausibleEmail(email) || flow.isWorking)
                    }
                }
            }
            .onAppear { isFocused = email.isEmpty }
        }
    }

    private func send() {
        let flow = session.signInFlow
        let address = email
        Task { await flow.requestPasswordReset(email: address) }
    }
}
