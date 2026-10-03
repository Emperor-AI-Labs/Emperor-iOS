import AuthenticationServices
import SwiftUI

/// "Sign in with Apple" and "Continue with Google", for the steps that start a session.
///
/// Drawn only when `SocialSignInConfig` allows — the build must carry a Google iOS client id and
/// turn `EMPEROR_SOCIAL_SIGN_IN` on, and the platform must have the two token routes. Apple
/// comes first and is the same size as Google: App Review asks for Sign in with Apple to be
/// offered at least as prominently as any other third-party sign-in (guideline 4.8).
struct SocialSignInButtons: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(Session.self) private var session

    let config: SocialSignInConfig

    var body: some View {
        VStack(spacing: 10) {
            if config.offersApple {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    finishApple(result)
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(Capsule())
            }
            if config.offersGoogle, let clientID = config.googleClientID {
                GoogleSignInButton(clientID: clientID)
            }
        }
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) {
        let flow = session.signInFlow
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8)
            else {
                flow.socialSignInFailed(provider: "Apple", declined: false)
                return
            }
            // Apple shares the name on the first authorisation only, ever.
            let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
            Task { await flow.completeApple(idToken: token, name: name) }
        case .failure(let error):
            let declined = (error as? ASAuthorizationError)?.code == .canceled
            flow.socialSignInFailed(provider: "Apple", declined: declined)
        }
    }
}

/// Google's sign-in, in the system browser sheet — Google refuses it inside an embedded web view.
///
/// Drawn to Google's branding rules: the full-colour "G" on a neutral surface, the words
/// "Continue with Google", and nothing restyled.
private struct GoogleSignInButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(Session.self) private var session

    let clientID: String
    @State private var isWorking = false

    var body: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                } else {
                    Image("GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text("Continue with Google")
                    .font(.brand(.subheadline, weight: .semibold))
            }
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(theme.surfaceElevated, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityLabel("Continue with Google")
    }

    private func signIn() async {
        let flow = session.signInFlow
        guard let attempt = GoogleOAuth.begin(clientID: clientID) else {
            flow.socialSignInFailed(provider: "Google", declined: false)
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            // Ephemeral: nothing from this sign-in is left in the shared browser for the next
            // person to hold the phone.
            let callback = try await webAuthenticationSession.authenticate(
                using: attempt.url,
                callbackURLScheme: attempt.callbackScheme,
                preferredBrowserSession: .ephemeral)
            let code = try GoogleOAuth.code(from: callback, for: attempt)
            let token = try await GoogleOAuth.exchange(code: code, attempt: attempt, clientID: clientID)
            await flow.completeGoogle(idToken: token)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            flow.socialSignInFailed(provider: "Google", declined: true)
        } catch GoogleOAuth.Failure.declined {
            flow.socialSignInFailed(provider: "Google", declined: true)
        } catch {
            flow.socialSignInFailed(provider: "Google", declined: false)
        }
    }
}
