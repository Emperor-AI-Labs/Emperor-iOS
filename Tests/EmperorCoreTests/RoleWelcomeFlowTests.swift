import XCTest
@testable import EmperorCore

/// The welcome's two steps: the role, then chambers and designation saved through the profile.
private final class WelcomeProfileFake: ProfileUpdating, @unchecked Sendable {
    var sent: [(name: String, avatar: String, title: String, organization: String)] = []
    var error: Error?

    func update(name: String, avatar: String, title: String, organization: String) async throws -> User? {
        sent.append((name, avatar, title, organization))
        if let error { throw error }
        var user = User(id: 7)
        user.name = name
        user.avatar = avatar
        user.title = title
        user.organization = organization
        return user
    }
}

@MainActor
private final class Adopted { var users: [User] = [] }

@MainActor
private func withFlow(
    name: String? = "Asha Rao",
    title: String? = nil,
    organization: String? = nil,
    avatar: String? = "https://example.test/a.jpg",
    _ body: @MainActor (RoleWelcomeFlow, WelcomeProfileFake, Adopted) async -> Void
) async {
    var user = User(id: 7)
    user.name = name
    user.title = title
    user.organization = organization
    user.avatar = avatar
    let fake = WelcomeProfileFake()
    let adopted = Adopted()
    let flow = RoleWelcomeFlow(user: user, service: fake, adopt: { adopted.users.append($0) })
    await body(flow, fake, adopted)
}

final class RoleWelcomeFlowTests: XCTestCase {

    func testContinueNeedsARoleAndBackKeepsIt() async {
        await withFlow { flow, _, _ in
            XCTAssertEqual(flow.step, .role)
            XCTAssertFalse(flow.canContinue)
            flow.continueToDetails()
            XCTAssertEqual(flow.step, .role, "Continue without a role went on")

            flow.chosen = .litigator
            flow.continueToDetails()
            XCTAssertEqual(flow.step, .details)

            flow.back()
            XCTAssertEqual(flow.step, .role)
            XCTAssertEqual(flow.chosen, .litigator)
        }
    }

    func testNothingTypedSavesNothing() async {
        await withFlow { flow, fake, adopted in
            flow.chosen = .litigator
            flow.continueToDetails()
            let done = await flow.finishWithDetails()
            XCTAssertTrue(done)
            XCTAssertTrue(fake.sent.isEmpty)
            XCTAssertTrue(adopted.users.isEmpty)
        }
    }

    /// `/update-profile` clears what it is not sent, so the name and photo go too, as they were.
    func testTheDetailsAreSavedWithEveryOtherProfileField() async {
        await withFlow { flow, fake, adopted in
            flow.chosen = .litigator
            flow.continueToDetails()
            flow.profile.organization = "  Chambers of R. Mehta "
            flow.profile.title = "Advocate, Delhi High Court"
            let done = await flow.finishWithDetails()

            XCTAssertTrue(done)
            XCTAssertEqual(fake.sent.count, 1)
            XCTAssertEqual(fake.sent.first?.name, "Asha Rao")
            XCTAssertEqual(fake.sent.first?.avatar, "https://example.test/a.jpg")
            XCTAssertEqual(fake.sent.first?.organization, "Chambers of R. Mehta")
            XCTAssertEqual(fake.sent.first?.title, "Advocate, Delhi High Court")
            XCTAssertEqual(adopted.users.first?.organization, "Chambers of R. Mehta")
        }
    }

    /// What the account already holds is shown, and saving it unchanged writes nothing.
    func testTheFormStartsFromTheAccount() async {
        await withFlow(title: "Senior Advocate", organization: "Mehta & Co") { flow, fake, _ in
            XCTAssertEqual(flow.profile.title, "Senior Advocate")
            XCTAssertEqual(flow.profile.organization, "Mehta & Co")
            XCTAssertFalse(flow.asksForName)
            let done = await flow.finishWithDetails()
            XCTAssertTrue(done)
            XCTAssertTrue(fake.sent.isEmpty)
        }
    }

    func testAFailedSaveSaysWhyAndStays() async {
        await withFlow { flow, fake, adopted in
            fake.error = APIError.server(status: 500, message: "Profile update failed")
            flow.chosen = .paralegal
            flow.continueToDetails()
            flow.profile.title = "Paralegal"
            let done = await flow.finishWithDetails()

            XCTAssertFalse(done)
            XCTAssertEqual(flow.step, .details)
            XCTAssertEqual(flow.saveError, ProfileEditor.Copy.notSaved)
            XCTAssertTrue(adopted.users.isEmpty)

            flow.back()
            XCTAssertNil(flow.saveError)
        }
    }

    /// An account with no name is asked for one, because a nameless profile save is refused.
    func testAnAccountWithNoNameIsAskedForOne() async {
        await withFlow(name: "  ") { flow, fake, _ in
            XCTAssertTrue(flow.asksForName)
            flow.profile.title = "Advocate"
            let refused = await flow.finishWithDetails()
            XCTAssertFalse(refused)
            XCTAssertEqual(flow.saveError, ProfileEditor.Copy.nameRequired)
            XCTAssertTrue(fake.sent.isEmpty)

            flow.profile.name = "Asha"
            let done = await flow.finishWithDetails()
            XCTAssertTrue(done)
            XCTAssertEqual(fake.sent.first?.name, "Asha")
            XCTAssertNil(flow.saveError)
        }
    }
}
