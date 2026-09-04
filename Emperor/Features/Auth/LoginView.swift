import SwiftUI

struct LoginView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegistering = false
    @State private var isAskingForReset = false
    @FocusState private var focused: Field?

    private enum Field { case name, email, password }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (!isRegistering || !name.isEmpty)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Emperor")
                    .font(.system(.largeTitle, design: .serif, weight: .semibold))
                Text("For Indian litigation and corporate practice")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                if isRegistering {
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                        .focused($focused, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focused = .email }
                }

                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }

                SecureField("Password", text: $password)
                    .textContentType(isRegistering ? .newPassword : .password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            if let error = session.signInError {
                Text(error)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.danger)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }

            Button(action: submit) {
                if session.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(isRegistering ? "Create account" : "Sign in")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit || session.isWorking)

            Button(isRegistering ? "I already have an account" : "Create an account") {
                withAnimation { isRegistering.toggle() }
            }
            .font(.brand(.footnote))

            if !isRegistering {
                Button("Forgot your password?") { isAskingForReset = true }
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer()
        }
        .padding(28)
        .animation(.default, value: session.signInError)
        .animation(.default, value: isRegistering)
        .sheet(isPresented: $isAskingForReset) {
            PasswordResetSheet(email: email)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = nil
        Task {
            if isRegistering {
                await session.register(name: name, email: email, password: password)
            } else {
                await session.signIn(email: email, password: password)
            }
        }
    }
}
