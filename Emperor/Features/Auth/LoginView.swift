import SwiftUI

/// Signing in: the "Emperor AI" screen — the mark in its tile, the Password / Sign in with code
/// choice, the six-box code, and the paths around them.
///
/// The password leads, the way the design's screen opens; "Sign in with code" swaps it for an
/// address and a one-time code with nothing to remember. Creating an account, resetting a
/// password and — where a build carries them — social providers stay on the same screen.
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
    /// Which way the sign-in step is showing: the password, which leads, or the one-time code
    /// behind its own segment.
    @State private var usesPassword = true
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
        .onChange(of: usesPassword) { _, uses in
            // Switching ways in clears what either way said and hands the keyboard to the
            // field the new way starts with. The segment animates the swap itself.
            session.signInFlow.clearMessages()
            focused = uses ? .password : .email
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
            header
                .padding(.bottom, Spacing.xxl)

            RecordSegmentedControl(
                label: "Sign-in method",
                options: [
                    (value: true, title: "Password"),
                    (value: false, title: "Sign in with code"),
                ],
                selection: $usesPassword
            )

            labelled("Email", hint: judgesEmail ? flow.emailProblem : nil, hintIsError: true) {
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
            .padding(.top, Spacing.lg)

            if usesPassword {
                passwordRow(flow)
                    .padding(.top, Spacing.md)
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                if isOffline {
                    OfflineStrip(message: usesPassword
                        ? "You're offline. Connect to sign in."
                        : "You're offline. Connect to get a sign-in code.")
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

            // Where the build carries them, the providers sit under their own divider. Off in
            // a normal build (`SocialSignInConfig`); the UI test that shows them switches it on.
            if flow.social.offersAny {
                orDivider("or")
                SocialSignInButtons(config: flow.social)
            }

            Spacer(minLength: Spacing.xxl)

            switchLink(prompt: "Don't have an account?", action: "Create new account") {
                session.signInFlow.show(.createAccount)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.xxl)
        }
    }

    /// "Password" with the way to reset it beside it, over the field, as the design has it.
    private func passwordRow(_ flow: SignInFlow) -> some View {
        @Bindable var flow = flow

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The field below carries this name for VoiceOver, so only the eye hears it.
                Text("Password")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                Spacer(minLength: Spacing.sm)
                Button("Forgot password?") {
                    isAskingForReset = true
                }
                .font(.brand(.footnote, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(minHeight: 44)
                .padding(.vertical, -8)
                .contentShape(Rectangle())
            }
            passwordField(
                $flow.password, label: "Password", field: .password, isNew: false,
                submit: { run { await $0.signIn() } })
        }
    }

    /// The mark in its tile, "Emperor AI" in the serif, and what the app is — centred, as the
    /// design's sign-in sits.
    private var header: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: Radius.dialog, style: .continuous)
                .fill(theme.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.dialog, style: .continuous)
                        .strokeBorder(theme.separator, lineWidth: 1))
                .frame(width: 76, height: 76)
                .overlay(RecordMarkView(height: 40))
                .accessibilityHidden(true)

            Text("Emperor AI")
                .font(.display(size: 42, relativeTo: .largeTitle))
                .foregroundStyle(theme.textPrimary)
                .padding(.top, Spacing.lg)
                .accessibilityAddTraits(.isHeader)

            Text("Sign in to your legal workspace")
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textFaint)
                .padding(.top, Spacing.xs)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
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
