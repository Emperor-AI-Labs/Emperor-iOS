import SwiftUI

/// Signing in: the Record "Ask the *record*." screen, the six-box code, and the paths around them.
///
/// The way in the design leads with is an address and a one-time code — "Email me a sign-in
/// code", no password to remember. Every other way the platform offers stays reachable from the
/// same screen as a quieter option: a password, Google or Apple where the build has them, and
/// creating an account, with its confirmation step.
///
/// Every decision — which step comes next, what a refusal means, when another email may be
/// sent — is `SignInFlow`'s, in the tested core. This view lays out whichever step it is on.
struct LoginView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var focused: Field?
    @FocusState private var codeFocused: Bool
    @State private var isAskingForReset = false
    @State private var showsPassword = false
    /// Whether the sign-in step offers the password field — the quieter way in.
    @State private var usesPassword = false
    /// Whether an address that cannot be one has been said so, in red under the field. Set when
    /// the field is left or the button pressed — not on every keystroke of a half-typed address.
    @State private var judgesEmail = false
    @State private var isOffline = AppConnectivity.current.isOffline

    private enum Field: Hashable { case name, email, phone, password, confirm }

    var body: some View {
        let flow = session.signInFlow
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                .frame(maxWidth: 440, alignment: .leading)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxxxl)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                .transition(.opacity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(alignment: .topTrailing) {
            // The soft indigo light in the top corner the design's sign-in sits under.
            RadialGradient(
                colors: [theme.accentSoft, Color.clear],
                center: .topTrailing, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
                .accessibilityHidden(true)
        }
        .background(theme.canvas.ignoresSafeArea())
        // The step changes as a cross-fade; under Reduce Motion, the 150 ms one.
        .animation(Motion.adaptive(Motion.easeOut(0.22), reduceMotion: reduceMotion), value: flow.step)
        .animation(Motion.adaptive(Motion.easeOut(0.15), reduceMotion: reduceMotion), value: flow.error)
        // Said as well as shown. A refusal lands above the button, which is not where VoiceOver's
        // focus is after tapping it — without this a blind user hears nothing happen.
        .onChange(of: flow.error) { _, error in
            if let error { VoiceOver.announce("Error: \(error)") }
        }
        .onChange(of: flow.notice) { _, notice in
            if let notice { VoiceOver.announce(notice) }
        }
        .onChange(of: flow.step) { _, step in
            showsPassword = false
            judgesEmail = false
            switch step {
            case .enterCode:
                focused = nil
                codeFocused = true
            case .checkInbox: focused = nil
            case .createAccount: focused = .name
            case .signIn: focused = flow.email.isEmpty || !usesPassword ? .email : .password
            }
        }
        .onChange(of: focused) { old, _ in
            if old == .email { judgesEmail = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .emperorConnectivityChanged)) { _ in
            isOffline = AppConnectivity.current.isOffline
        }
        .sheet(isPresented: $isAskingForReset) {
            PasswordResetSheet(email: flow.email)
        }
    }

    // MARK: - Sign in

    private func signIn(_ flow: SignInFlow) -> some View {
        @Bindable var flow = flow

        return VStack(alignment: .leading, spacing: 0) {
            lockup
                .padding(.bottom, Spacing.xxxl + Spacing.xs)

            labelled("Work email", hint: judgesEmail ? flow.emailProblem : nil, hintIsError: true) {
                emailField(
                    $flow.email,
                    isInvalid: judgesEmail && flow.emailProblem != nil,
                    submit: {
                        if usesPassword {
                            focused = .password
                        } else {
                            sendCode(session.signInFlow)
                        }
                    })
            }

            if usesPassword {
                labelled("Password") {
                    passwordField(
                        $flow.password, label: "Password", field: .password, isNew: false,
                        submit: { run { await $0.signIn() } })
                }
                .padding(.top, Spacing.md)
                .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                if isOffline {
                    OfflineStrip(message: "You're offline. Connect to get a sign-in code.")
                }
                messages(flow)
            }
            .padding(.top, Spacing.md)

            Group {
                if usesPassword {
                    AuthPrimaryButton(title: "Sign in", isWorking: flow.isWorking) {
                        judgesEmail = true
                        focused = nil
                        run { await $0.signIn() }
                    }
                    .disabled(!flow.canSignIn || isOffline)
                } else {
                    // Fifty points tall whatever the text size, because the label is short.
                    AuthPrimaryButton(title: "Email me a sign-in code", isWorking: flow.isWorking) {
                        sendCode(session.signInFlow)
                    }
                    .disabled(flow.isWorking || isOffline)
                }
            }
            .padding(.top, Spacing.md)

            orDivider("or")

            VStack(spacing: Spacing.sm) {
                if flow.social.offersAny {
                    SocialSignInButtons(config: flow.social)
                }
                Button {
                    withAnimation(Motion.adaptive(Motion.easeOut(0.2), reduceMotion: reduceMotion)) {
                        usesPassword.toggle()
                    }
                    session.signInFlow.clearMessages()
                    focused = usesPassword ? .password : .email
                } label: {
                    Text(usesPassword ? "Email me a code instead" : "Sign in with a password")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondaryAction)

                if usesPassword {
                    AuthLinkButton(title: "Forgot your password?") {
                        isAskingForReset = true
                    }
                }
            }

            Spacer(minLength: Spacing.xxl)

            VStack(spacing: Spacing.xs) {
                switchLink(prompt: "New to Emperor?", action: "Create an account") {
                    session.signInFlow.show(.createAccount)
                }
                Text(usesPassword
                     ? "Your password is sent only to Emperor."
                     : "One-time code, no password to remember.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.xxl)
        }
    }

    /// The mark, "Ask the *record*." in the serif, and what Emperor is.
    private var lockup: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecordMarkView(height: 44)
            headline
                .font(.display(size: 46, relativeTo: .largeTitle))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel("Emperor. Ask the record.")
            Text("Your matters, judgments and drafts — read, searched and cited to the page.")
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Ask the *record*." — the one italic word in the accent.
    private var headline: Text {
        Text("Ask the ") + Text("record").italic().foregroundStyle(theme.accentText) + Text(".")
    }

    /// "We sent a 6-digit code to **aarti@kapoorlaw.in**."
    private func codeSentLine(_ email: String) -> Text {
        Text("We sent a \(SignInFlow.codeLength)-digit code to ")
            + Text(email).foregroundStyle(theme.textPrimary).fontWeight(.semibold)
            + Text(". It works for a few minutes.")
    }

    private func sendCode(_ flow: SignInFlow) {
        judgesEmail = true
        guard flow.canRequestCode else {
            focused = .email
            return
        }
        focused = nil
        run { await $0.requestCode() }
    }

    // MARK: - Create an account

    private func createAccount(_ flow: SignInFlow) -> some View {
        @Bindable var flow = flow

        return VStack(alignment: .leading, spacing: Spacing.lg) {
            backButton("Sign in") { session.signInFlow.show(.signIn) }

            SerifHeader(
                title: "Create your account",
                subtitle: "We'll email you a link to confirm your address.")

            if flow.social.offersAny {
                SocialSignInButtons(config: flow.social)
                orDivider("or sign up with email")
            }

            // The web's sign-up fields, labels, placeholders and required set (`Register.jsx`):
            // full name, email, password and its confirmation — plus an optional mobile number.
            VStack(spacing: 14) {
                labelled("Full name") {
                    TextField("Full name", text: $flow.name, prompt: placeholder("John Doe"))
                        .accessibilityIdentifier("Full name")
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .focused($focused, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focused = .email }
                        .authField(nil, isFocused: focused == .name)
                }

                labelled("Email", hint: judgesEmail ? flow.emailProblem : nil, hintIsError: true) {
                    emailField(
                        $flow.email, isInvalid: judgesEmail && flow.emailProblem != nil,
                        submit: { focused = .phone })
                }

                labelled("Mobile number", detail: "Optional",
                         hint: flow.phoneHint, hintIsError: flow.phoneHint != nil) {
                    phoneField(flow)
                }

                labelled("Password",
                         hint: flow.passwordHint ?? "At least \(SignInFlow.minimumPasswordLength) characters.",
                         hintIsError: flow.passwordHint != nil) {
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
            .disabled(!flow.canCreateAccount || isOffline)

            switchLink(prompt: "Already have an account?", action: "Sign in instead") {
                session.signInFlow.show(.signIn)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Confirm the address

    private func checkInbox(_ flow: SignInFlow, email: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            backButton("Back") { session.signInFlow.backToSignIn() }

            IconCircle(systemImage: "envelope.open")

            SerifHeader(
                title: "Confirm your email",
                subtitle: "We've sent a link to \(email). Open it to confirm your address, then sign in here.")

            messages(flow)

            // The quicker way: a code confirms the address too, without leaving the app.
            AuthPrimaryButton(title: "Use a code instead", isWorking: flow.isWorking) {
                run { await $0.requestCode() }
            }
            .disabled(isOffline)

            resendButton(flow, email: email, label: "Send the email again") {
                run { await $0.resendConfirmation() }
            }
        }
    }

    // MARK: - Enter a code

    private func enterCode(_ flow: SignInFlow, email: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton("Back") { session.signInFlow.backToSignIn() }
                .padding(.bottom, Spacing.md)

            Text("Check your email")
                .recordText(RecordTokens.Typography.largeTitle)
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            codeSentLine(email)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.xs)

            OneTimeCodeField(
                code: flow.code,
                length: SignInFlow.codeLength,
                isInvalid: flow.error != nil,
                isDisabled: flow.isWorking,
                focus: $codeFocused
            ) { typed in
                flow.setCode(typed)
            }
            .padding(.top, Spacing.xxl + 2)
            // Six digits is a complete code: going on without a tap is what a code field does
            // everywhere else on the phone, including when iOS fills it from Mail.
            .onChange(of: flow.code) { _, code in
                if code.count == SignInFlow.codeLength {
                    run { await $0.verifyCode() }
                }
            }

            Group {
                if flow.isWorking {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Checking the code…")
                    }
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textTertiary)
                } else if let error = flow.error {
                    Text(error)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error: \(error)")
                } else if let notice = flow.notice {
                    Text(notice)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Spacing.md)

            if isOffline {
                OfflineStrip(message: "You're offline. The code is checked once you're back.")
                    .padding(.top, Spacing.md)
            }

            HStack(spacing: Spacing.md) {
                resendButton(flow, email: email, label: "Send a new code") {
                    run { await $0.requestCode() }
                }
                Button("Use a different email") {
                    session.signInFlow.backToSignIn()
                }
                .buttonStyle(.quietAction)
            }
            .padding(.top, Spacing.xl)
            .padding(.leading, -Spacing.md)
        }
    }

    /// "Send again", counting down while another email would not be sent.
    private func resendButton(
        _ flow: SignInFlow, email: String, label: String, action: @escaping () -> Void
    ) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let wait = flow.nextSendAllowed(for: email)
                .map { max(0, Int($0.timeIntervalSince(context.date).rounded(.up))) } ?? 0
            Button(wait > 0 ? "\(label) in \(wait)s" : label, action: action)
                .buttonStyle(.quietAction)
                .monospacedDigit()
                .disabled(wait > 0 || flow.isWorking || isOffline)
        }
    }

    /// The design's back button at the head of a step: a chevron and a word, in the accent.
    private func backButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.brand(.body))
            }
            .foregroundStyle(theme.accentText)
            .frame(minHeight: Layout.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -Spacing.xl)
        .accessibilityLabel(title == "Back" ? "Back" : "Back to \(title)")
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

    // MARK: - Shared fields

    private func emailField(
        _ text: Binding<String>, isInvalid: Bool, submit: @escaping () -> Void
    ) -> some View {
        TextField("Email", text: text, prompt: placeholder("you@chambers.in"))
            .accessibilityIdentifier("Email")
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused, equals: .email)
            .submitLabel(usesPassword ? .next : .send)
            .onSubmit(submit)
            .authField(nil, isFocused: focused == .email, isInvalid: isInvalid)
    }

    private func passwordField(
        _ text: Binding<String>, label: String, field: Field, isNew: Bool,
        submit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if showsPassword {
                    TextField(label, text: text, prompt: placeholder("••••••••"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(label, text: text, prompt: placeholder("••••••••"))
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
        }
        .authField(nil, isFocused: focused == field)
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
            ), prompt: placeholder("98765 43210"))
            .accessibilityIdentifier("Mobile number")
            .accessibilityHint("Optional. An Indian number; +91 is added for you.")
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            .focused($focused, equals: .phone)
        }
        .authField(nil, isFocused: focused == .phone)
    }

    /// A field's example text, in the palette's caption colour rather than the system's
    /// placeholder grey, which is too faint to read for the people most likely to need it.
    private func placeholder(_ text: String) -> Text {
        Text(verbatim: text).foregroundStyle(theme.textTertiary)
    }

    /// A field with its label above it. The label is for the eye: the field carries the same
    /// name for VoiceOver, so it is not read twice. A hint under it — in red when it is an error.
    private func labelled<Content: View>(
        _ label: String, detail: String? = nil, hint: String? = nil, hintIsError: Bool = false,
        @ViewBuilder field: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
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
                    .font(.brand(size: 12.5, relativeTo: .caption))
                    .foregroundStyle(hintIsError ? theme.danger : theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(hintIsError ? "Error: \(hint)" : hint)
            }
        }
    }

    /// "or", between the main way in and the others — the design's divider.
    private func orDivider(_ text: String) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(theme.separator).frame(height: 1)
            Text(text)
                .font(.brand(.caption, weight: .semibold))
                .tracking(0.7)
                .textCase(.uppercase)
                .foregroundStyle(theme.textTertiary)
                .fixedSize()
            Rectangle().fill(theme.separator).frame(height: 1)
        }
        .padding(.vertical, 18)
        .accessibilityHidden(true)
    }

    /// The question and its answer on one line while they fit; the answer under the question
    /// once a large text size would push it off the edge.
    private func switchLink(prompt: String, action: String, perform: @escaping () -> Void) -> some View {
        let question = Text(prompt).foregroundStyle(theme.textSecondary)
        let answer = Button(action: perform) {
            Text(action)
                .fontWeight(.semibold)
                .foregroundStyle(theme.accentText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                question
                answer
            }
            VStack(spacing: 0) {
                question
                    .multilineTextAlignment(.center)
                answer
            }
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

/// The six boxes of a one-time code.
///
/// One real text field under the boxes holds the code, so everything a code field does on iOS
/// still works: Mail's suggestion above the keyboard (`oneTimeCode`), paste filling all six,
/// typing advancing box by box, Backspace stepping back. The boxes only draw what it holds, the
/// next one to fill ringed in the accent.
struct OneTimeCodeField: View {
    @Environment(\.theme) private var theme

    let code: String
    let length: Int
    var isInvalid = false
    var isDisabled = false
    var focus: FocusState<Bool>.Binding
    let onChange: (String) -> Void

    @ScaledMetric(relativeTo: .title2) private var boxHeight: CGFloat = 56

    var body: some View {
        ZStack {
            TextField("", text: Binding(get: { code }, set: { onChange($0) }))
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused(focus)
                .disabled(isDisabled)
                .foregroundStyle(Color.clear)
                .tint(Color.clear)
                .frame(maxWidth: .infinity, minHeight: boxHeight)
                .accessibilityLabel("Sign-in code")
                .accessibilityValue(code.isEmpty ? "Empty" : "\(code.count) of \(length) digits")

            HStack(spacing: Spacing.sm) {
                ForEach(0..<length, id: \.self) { index in
                    box(index)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = true }
    }

    private func box(_ index: Int) -> some View {
        let digits = Array(code)
        let digit = index < digits.count ? String(digits[index]) : ""
        let isNext = focus.wrappedValue && index == min(digits.count, length - 1)
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        let edge: Color = isInvalid ? theme.danger : (isNext ? theme.accentText : theme.borderStrong)
        return Text(digit)
            .font(.brand(size: 22, weight: .semibold, relativeTo: .title2))
            .monospacedDigit()
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: boxHeight)
            .background(theme.surface, in: shape)
            .overlay(shape.strokeBorder(edge, lineWidth: 1))
            .background(
                RoundedRectangle(cornerRadius: Radius.control + 3, style: .continuous)
                    .fill(isNext && !isInvalid ? theme.accentSoft : Color.clear)
                    .padding(-3))
    }
}
