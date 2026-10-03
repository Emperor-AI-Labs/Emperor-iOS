import SwiftUI

/// Signing in, creating an account, confirming an address and using a one-time code.
///
/// Every decision — which step comes next, what a refusal means, when another email may be
/// sent — is `SignInFlow`'s, in the tested core. This view lays out whichever step it is on,
/// inside one card under the brand mark, so moving between steps reads as one place changing
/// rather than a series of screens.
struct LoginView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @FocusState private var focused: Field?
    @State private var isAskingForReset = false
    @State private var showsPassword = false

    private enum Field: Hashable { case name, email, phone, password, confirm, code }

    var body: some View {
        let flow = session.signInFlow
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 0)
                    header
                    card(flow)
                    footer(flow)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.canvas.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.22), value: flow.step)
        .animation(.easeInOut(duration: 0.15), value: flow.error)
        .onChange(of: flow.step) { _, step in
            showsPassword = false
            switch step {
            case .enterCode: focused = .code
            case .checkInbox: focused = nil
            case .createAccount: focused = .name
            case .signIn: focused = flow.email.isEmpty ? .email : .password
            }
        }
        .sheet(isPresented: $isAskingForReset) {
            PasswordResetSheet(email: flow.email)
        }
    }

    // MARK: - Brand

    private var header: some View {
        VStack(spacing: 16) {
            Image("EmperorMark")
                .resizable()
                .scaledToFit()
                .frame(height: 56)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Emperor")
                    .font(.brand(.largeTitle, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("For Indian litigation and corporate practice")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - The card

    private func card(_ flow: SignInFlow) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            switch flow.step {
            case .signIn:
                signIn(flow)
            case .createAccount:
                createAccount(flow)
            case .checkInbox(let email):
                checkInbox(flow, email: email)
            case .enterCode(let email):
                enterCode(flow, email: email)
            }
        }
        .padding(Spacing.xxl)
        .panel()
        .transition(.opacity)
    }

    private func title(_ text: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.brand(.title2, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func messages(_ flow: SignInFlow) -> some View {
        if let notice = flow.notice {
            AuthMessage(text: notice, tone: .info)
        }
        if let error = flow.error {
            AuthMessage(text: error, tone: .error)
        }
    }

    // MARK: Sign in

    private func signIn(_ flow: SignInFlow) -> some View {
        @Bindable var flow = flow

        return Group {
            title("Sign in", "Welcome back.")

            if flow.social.offersAny {
                SocialSignInButtons(config: flow.social)
                orDivider("or sign in with email")
            }

            VStack(spacing: 14) {
                labelled("Email") {
                    emailField($flow.email, submit: { focused = .password })
                }
                labelled("Password") {
                    passwordField(
                        $flow.password, label: "Password", field: .password, isNew: false,
                        submit: { run { await $0.signIn() } })
                }
            }

            messages(flow)

            AuthPrimaryButton(title: "Sign in", isWorking: flow.isWorking) {
                focused = nil
                run { await $0.signIn() }
            }
            .disabled(!flow.canSignIn)

            VStack(spacing: 2) {
                // Every account can use a code — and it is the only way in for one made with
                // Google, so it is offered prominently once the server has said that is the case.
                AuthLinkButton(
                    title: flow.offersCode ? "Email me a sign-in code" : "Sign in with an email code",
                    systemImage: "envelope.badge"
                ) {
                    focused = nil
                    run { await $0.requestCode() }
                }
                AuthLinkButton(title: "Forgot your password?") {
                    isAskingForReset = true
                }
            }
        }
    }

    // MARK: Create an account

    private func createAccount(_ flow: SignInFlow) -> some View {
        @Bindable var flow = flow

        return Group {
            title("Create your account", "We'll email you a link to confirm your address.")

            if flow.social.offersAny {
                SocialSignInButtons(config: flow.social)
                orDivider("or sign up with email")
            }

            // The web's sign-up fields, labels, placeholders and required set (`Register.jsx`):
            // full name, email, password and its confirmation — plus an optional mobile number.
            VStack(spacing: 14) {
                labelled("Full name") {
                    TextField("Full name", text: $flow.name, prompt: Text(verbatim: "John Doe"))
                        .accessibilityIdentifier("Full name")
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .focused($focused, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focused = .email }
                        .authField("person", isFocused: focused == .name)
                }

                labelled("Email") {
                    emailField($flow.email, submit: { focused = .phone })
                }

                labelled("Mobile number", detail: "Optional",
                         hint: flow.phoneHint, hintIsWarning: flow.phoneHint != nil) {
                    phoneField(flow)
                }

                labelled("Password",
                         hint: flow.passwordHint ?? "At least \(SignInFlow.minimumPasswordLength) characters.",
                         hintIsWarning: flow.passwordHint != nil) {
                    passwordField(
                        $flow.password, label: "Password", field: .password, isNew: true,
                        submit: { focused = .confirm })
                }

                labelled("Confirm password") {
                    passwordField(
                        $flow.confirmPassword, label: "Confirm password", field: .confirm,
                        isNew: true, submit: { run { await $0.createAccount() } })
                }
            }

            messages(flow)

            AuthPrimaryButton(title: "Create account", isWorking: flow.isWorking) {
                focused = nil
                run { await $0.createAccount() }
            }
            .disabled(!flow.canCreateAccount)
        }
    }

    // MARK: Confirm the address

    private func checkInbox(_ flow: SignInFlow, email: String) -> some View {
        Group {
            IconCircle(systemImage: "envelope.open")

            title(
                "Confirm your email",
                "We've sent a link to \(email). Open it to confirm your address, then sign in here.")

            messages(flow)

            // The quicker way: a code confirms the address too, without leaving the app.
            AuthPrimaryButton(title: "Use a code instead", isWorking: flow.isWorking) {
                run { await $0.requestCode() }
            }

            VStack(spacing: 2) {
                resendButton(flow, email: email, label: "Send the email again") {
                    run { await $0.resendConfirmation() }
                }
                AuthLinkButton(title: "Back to sign in", systemImage: "chevron.left") {
                    session.signInFlow.backToSignIn()
                }
            }
        }
    }

    // MARK: Enter a code

    private func enterCode(_ flow: SignInFlow, email: String) -> some View {
        Group {
            title("Enter your code", "We emailed a \(SignInFlow.codeLength)-digit code to \(email).")

            TextField("\(SignInFlow.codeLength)-digit code", text: Binding(
                get: { flow.code },
                set: { flow.setCode($0) }
            ))
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .font(.system(.title2, design: .monospaced, weight: .semibold))
            .multilineTextAlignment(.center)
            .focused($focused, equals: .code)
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(theme.surfaceElevated))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(focused == .code ? theme.accent : theme.separator,
                                  lineWidth: focused == .code ? 1.5 : 1))
            .accessibilityLabel("Sign-in code")
            // Six digits is a complete code: going on without a tap is what a code field does
            // everywhere else on the phone, including when iOS fills it from Mail.
            .onChange(of: flow.code) { _, code in
                if code.count == SignInFlow.codeLength {
                    run { await $0.verifyCode() }
                }
            }

            messages(flow)

            AuthPrimaryButton(title: "Continue", isWorking: flow.isWorking) {
                run { await $0.verifyCode() }
            }
            .disabled(!flow.canVerifyCode)

            VStack(spacing: 2) {
                resendButton(flow, email: email, label: "Send a new code") {
                    run { await $0.requestCode() }
                }
                AuthLinkButton(title: "Use a different email", systemImage: "chevron.left") {
                    session.signInFlow.backToSignIn()
                }
            }
        }
    }

    /// "Send again", counting down while another email would not be sent.
    private func resendButton(
        _ flow: SignInFlow, email: String, label: String, action: @escaping () -> Void
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = flow.nextSendAllowed(for: email)
                .map { max(0, Int($0.timeIntervalSince(context.date).rounded(.up))) } ?? 0
            AuthLinkButton(
                title: wait > 0 ? "\(label) in \(wait)s" : label,
                systemImage: "arrow.clockwise",
                action: action)
            .disabled(wait > 0 || flow.isWorking)
            .opacity(wait > 0 ? 0.5 : 1)
        }
    }

    // MARK: - Shared fields

    private func emailField(_ text: Binding<String>, submit: @escaping () -> Void) -> some View {
        TextField("Email", text: text, prompt: Text(verbatim: "name@firm.com"))
            .accessibilityIdentifier("Email")
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: .email)
            .submitLabel(.next)
            .onSubmit(submit)
            .authField("envelope", isFocused: focused == .email)
    }

    private func passwordField(
        _ text: Binding<String>, label: String, field: Field, isNew: Bool,
        submit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if showsPassword {
                    TextField(label, text: text, prompt: Text(verbatim: "••••••••"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(label, text: text, prompt: Text(verbatim: "••••••••"))
                }
            }
            .accessibilityIdentifier(label)
            .textContentType(isNew ? .newPassword : .password)
            .focused($focused, equals: field)
            .submitLabel(field == .confirm || !isNew ? .go : .next)
            .onSubmit(submit)

            Button {
                showsPassword.toggle()
            } label: {
                Image(systemName: showsPassword ? "eye.slash" : "eye")
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
        }
        .authField("lock", isFocused: focused == field)
    }

    /// The mobile number: India's code beside the field, the number grouped as it is written.
    private func phoneField(_ flow: SignInFlow) -> some View {
        HStack(spacing: 10) {
            Text("+91")
                .font(.brand(.body, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1, height: 20)
                .accessibilityHidden(true)
            TextField("Mobile number", text: Binding(
                get: { flow.phoneDisplay },
                set: { flow.setPhone($0) }
            ), prompt: Text(verbatim: "98765 43210"))
            .accessibilityIdentifier("Mobile number")
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .focused($focused, equals: .phone)
        }
        .authField("phone", isFocused: focused == .phone)
    }

    /// A field with its label above it, as the web lays out its forms. The label is for the eye:
    /// the field carries the same name for VoiceOver, so it is not read twice.
    private func labelled<Content: View>(
        _ label: String, detail: String? = nil, hint: String? = nil, hintIsWarning: Bool = false,
        @ViewBuilder field: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .accessibilityHidden(true)
            field()
            if let hint {
                Text(hint)
                    .font(.brand(.caption))
                    .foregroundStyle(hintIsWarning ? theme.warning : theme.textTertiary)
                    .padding(.leading, 4)
            }
        }
    }

    /// "or sign up with email", between the providers and the form — the web's divider.
    private func orDivider(_ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.separator).frame(height: 1)
            Text(text)
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
            Rectangle().fill(theme.separator).frame(height: 1)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ flow: SignInFlow) -> some View {
        switch flow.step {
        case .signIn:
            switchLink(prompt: "New to Emperor?", action: "Create an account") {
                session.signInFlow.show(.createAccount)
            }
        case .createAccount:
            switchLink(prompt: "Already have an account?", action: "Sign in instead") {
                session.signInFlow.show(.signIn)
            }
        case .checkInbox, .enterCode:
            EmptyView()
        }
    }

    private func switchLink(prompt: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(prompt)
                .foregroundStyle(theme.textSecondary)
            Button(action, action: perform)
                .fontWeight(.semibold)
                .foregroundStyle(theme.accentText)
        }
        .font(.brand(.subheadline))
    }

    // MARK: - Plumbing

    /// Runs a flow action on the main actor. Takes the action as a function of the flow rather
    /// than capturing a local, so no `@Bindable` wrapper is ever captured by the task.
    private func run(_ action: @escaping @MainActor @Sendable (SignInFlow) async -> Void) {
        let flow = session.signInFlow
        Task { await action(flow) }
    }
}
