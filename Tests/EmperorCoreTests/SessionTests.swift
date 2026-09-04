import XCTest
@testable import EmperorCore

/// Sign-in state across launches.
///
/// `signIn` and `register` are not exercised here: both go through a real `APIClient`, and
/// `Session` deliberately does not expose a seam for the URL session. What they add over the
/// service beneath them is the error wording — which is `DisplayText.message(for:)`, tested
/// separately — and adopting the response, which `restore` covers from the other side.
final class SessionTests: XCTestCase {

    private static func encoded(_ user: User) -> String {
        String(decoding: try! JSONEncoder().encode(user), as: UTF8.self)
    }

    /// The whole point of persisting the token: reopening the app must not ask for a password.
    func testRestoreSignsInFromStoredCredentials() async {
        let user = User(id: 42, email: "adv@example.test", name: "R. Iyer")
        let store = InMemoryCredentialStore([
            "auth.token": "tok-abc",
            "auth.user": Self.encoded(user),
        ])

        await withSession(store) { session in
            await session.restore()

            XCTAssertEqual(session.state, .signedIn(user))
            XCTAssertEqual(session.currentUser?.id, 42)
        }
    }

    /// The token is sent on every request, so restoring must put it on the client and not only
    /// in the state enum — otherwise the UI looks signed in and every call 401s.
    func testRestoreAdoptsCredentialsOntoTheClient() async {
        let user = User(id: 7)
        let store = InMemoryCredentialStore([
            "auth.token": "tok-xyz",
            "auth.user": Self.encoded(user),
        ])

        await withSession(store) { session in
            await session.restore()
            let credentials = await session.client.currentCredentials()

            XCTAssertEqual(credentials, Credentials(token: "tok-xyz", userID: 7))
        }
    }

    func testRestoreWithNothingStoredSignsOut() async {
        await withSession(InMemoryCredentialStore()) { session in
            await session.restore()
            XCTAssertEqual(session.state, .signedOut)
        }
    }

    /// A token with no user row cannot be used: every request needs the `userId` too. Half a
    /// credential must be treated as none rather than as a usable session.
    func testRestoreWithATokenButNoUserSignsOut() async {
        let store = InMemoryCredentialStore(["auth.token": "tok-abc"])

        await withSession(store) { session in
            await session.restore()
            XCTAssertEqual(session.state, .signedOut)
        }
    }

    /// A stored row from an older build may no longer decode. Falling back to signed-out asks
    /// for a password; failing to handle it would trap on the force-unwrap of a decode.
    func testRestoreWithAnUndecodableUserSignsOut() async {
        let store = InMemoryCredentialStore([
            "auth.token": "tok-abc",
            "auth.user": "{\"id\":\"not-a-number\"}",
        ])

        await withSession(store) { session in
            await session.restore()
            XCTAssertEqual(session.state, .signedOut)
        }
    }

    /// Signing out is purely local, so the one thing it must get right is leaving nothing
    /// behind on the device.
    func testSignOutClearsStoredCredentials() async {
        let store = InMemoryCredentialStore([
            "auth.token": "tok-abc",
            "auth.user": Self.encoded(User(id: 42)),
        ])

        await withSession(store) { session in
            await session.restore()
            await session.signOut()

            XCTAssertEqual(session.state, .signedOut)
            XCTAssertNil(store.string(for: "auth.token"))
            XCTAssertNil(store.string(for: "auth.user"))
            let credentials = await session.client.currentCredentials()
            XCTAssertNil(credentials)
        }
    }
}

/// Free function, not a method: an `XCTestCase` is not `Sendable`, so calling an instance
/// helper from a `@MainActor` closure makes Swift 6 reject the capture of `self`.
@MainActor
private func withSession(
    _ store: InMemoryCredentialStore,
    _ body: @MainActor (Session) async -> Void
) async {
    await body(Session(store: store))
}
