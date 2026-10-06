import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// Settings → Edit profile: what is sent, what is refused, and what the session keeps.
///
/// The route writes every profile column from what it is sent, so the property that matters most
/// is that a save never leaves one out — editing the title must not clear the photo.
@MainActor
final class ProfileEditorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        HTTPStub.reset()
    }

    override func tearDown() {
        HTTPStub.reset()
        super.tearDown()
    }

    private static let photo = "data:image/jpeg;base64," + Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()

    private static let user = User(
        id: 42, email: "adv@example.test", name: "R. Iyer", avatar: photo,
        title: "Advocate", organization: "Iyer Chambers", preferredModel: "fast",
        plan: "lite", planLabel: "Lite", phone: "+919876543210")

    private func editor(
        _ user: User = ProfileEditorTests.user, service: FakeProfileService = FakeProfileService()
    ) -> (ProfileEditor, FakeProfileService, AdoptedBox) {
        let adopted = AdoptedBox()
        let editor = ProfileEditor(user: user, service: service) { adopted.users.append($0) }
        return (editor, service, adopted)
    }

    // MARK: - Every field, every time

    /// The wire body carries all four profile fields and the caller, and nothing else — in
    /// particular no `phone`, which the route only touches when the key is present.
    func testTheRequestCarriesEveryFieldAndNoPhone() async throws {
        let session = await signedInSession()
        HTTPStub.always(.json(#"{"success":true,"user":{"id":42,"name":"R. Iyer"}}"#))

        _ = try await session.profile.update(
            name: "R. Iyer", avatar: "", title: "", organization: "")

        let sent = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(sent.url?.path, "/api/update-profile")
        XCTAssertEqual(sent.httpMethod, "POST")
        let body = sent.bodyJSON
        XCTAssertEqual(Set(body.keys), ["userId", "name", "avatar", "title", "organization"])
        XCTAssertEqual(body["userId"] as? String, "42")
        // Empty, not absent and not null: the web's own encoding for "none".
        XCTAssertEqual(body["avatar"] as? String, "")
        XCTAssertEqual(body["title"] as? String, "")
        XCTAssertEqual(body["organization"] as? String, "")
        XCTAssertNil(body["phone"], "the mobile number is never written from here")
    }

    /// Changing one field sends the others as they stood. A request with only the new title
    /// would clear the photo and the organisation.
    func testEditingOneFieldSendsTheOthersAsTheyWere() async {
        let (editor, service, _) = editor()
        editor.title = "Senior Advocate"

        await editor.save()

        XCTAssertEqual(service.calls.count, 1)
        let call = service.calls[0]
        XCTAssertEqual(call.name, "R. Iyer")
        XCTAssertEqual(call.avatar, Self.photo, "the photo goes back unchanged")
        XCTAssertEqual(call.title, "Senior Advocate")
        XCTAssertEqual(call.organization, "Iyer Chambers")
    }

    /// A photo carried over from Google is an `https:` address, and goes back exactly as it came.
    func testARemotePhotoIsSentBackUntouched() async {
        var user = Self.user
        user.avatar = "https://lh3.googleusercontent.com/a/abc=s96-c"
        let (editor, service, _) = editor(user)
        editor.organization = "Iyer & Co."

        await editor.save()

        XCTAssertEqual(service.calls.first?.avatar, "https://lh3.googleusercontent.com/a/abc=s96-c")
    }

    /// An account that has never had a title or an organisation sends them as empty strings.
    func testMissingFieldsAreSentEmptyRatherThanLeftOut() async {
        let (editor, service, _) = editor(User(id: 7, email: "a@b.test", name: "A"))
        editor.name = "A. Person"

        await editor.save()

        let call = service.calls.first
        XCTAssertEqual(call?.avatar, "")
        XCTAssertEqual(call?.title, "")
        XCTAssertEqual(call?.organization, "")
    }

    // MARK: - Trimming and validation

    func testFieldsAreTrimmedBeforeSending() async {
        let (editor, service, _) = editor()
        editor.name = "  Radha Iyer \n"
        editor.title = "   "
        editor.organization = "\tIyer Chambers, Chennai  "

        await editor.save()

        let call = service.calls.first
        XCTAssertEqual(call?.name, "Radha Iyer")
        XCTAssertEqual(call?.title, "", "a title of only spaces is no title")
        XCTAssertEqual(call?.organization, "Iyer Chambers, Chennai")
        XCTAssertEqual(editor.name, "Radha Iyer", "the form shows what was saved")
    }

    /// An empty name is refused here. The route would store it, and the account would then have
    /// no name at all.
    func testAnEmptyNameIsRefusedWithoutARequest() async {
        let (editor, service, adopted) = editor()
        editor.name = "   "

        XCTAssertEqual(editor.nameProblem, ProfileEditor.Copy.nameRequired)
        XCTAssertFalse(editor.canSave)
        let saved = await editor.save()

        XCTAssertFalse(saved)
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertTrue(adopted.users.isEmpty)
        XCTAssertEqual(editor.saveError, ProfileEditor.Copy.nameRequired)
    }

    /// Save lights up only for a real change — not for a space typed and deleted.
    func testNothingToSaveUntilSomethingReallyChanges() async {
        let (editor, _, _) = editor()
        XCTAssertFalse(editor.hasChanges)
        XCTAssertFalse(editor.canSave)

        editor.title = "Advocate  "
        XCTAssertFalse(editor.hasChanges, "trailing spaces are not a change")

        editor.title = "Advocate-on-Record"
        XCTAssertTrue(editor.canSave)
    }

    func testTheFormStartsFromTheAccount() async {
        let (editor, _, _) = editor()
        XCTAssertEqual(editor.name, "R. Iyer")
        XCTAssertEqual(editor.title, "Advocate")
        XCTAssertEqual(editor.organization, "Iyer Chambers")
        XCTAssertEqual(editor.email, "adv@example.test")
        XCTAssertEqual(editor.phone, "+919876543210")
        XCTAssertTrue(editor.hasPhoto)
    }

    // MARK: - The photo

    /// Removing the photo is sent as the web sends it: an empty string.
    func testRemovingThePhotoSendsAnEmptyAvatar() async {
        let (editor, service, _) = editor()
        editor.removePhoto()
        XCTAssertFalse(editor.hasPhoto)
        XCTAssertTrue(editor.canSave)

        await editor.save()

        XCTAssertEqual(service.calls.first?.avatar, "")
    }

    func testANewPhotoIsSentAsAJPEGDataURL() async {
        let (editor, service, _) = editor()
        let jpeg = Data(repeating: 0xAB, count: 20_000)
        XCTAssertTrue(editor.setPhoto { _ in jpeg })

        await editor.save()

        XCTAssertEqual(service.calls.first?.avatar, "data:image/jpeg;base64," + jpeg.base64EncodedString())
    }

    /// The first quality small enough is used: the web's 0.85 when it fits, a lower one only
    /// when it does not.
    func testTheEncodingStepsDownUntilItFits() async {
        var tried: [Double] = []
        let url = ProfilePhoto.encode { quality in
            tried.append(quality)
            return Data(repeating: 1, count: quality > 0.6 ? ProfilePhoto.maxBytes + 1 : 1000)
        }
        XCTAssertEqual(tried, [0.85, 0.7, 0.55])
        XCTAssertEqual(url, "data:image/jpeg;base64," + Data(repeating: 1, count: 1000).base64EncodedString())
    }

    /// The cap is inclusive, and one byte over it is refused.
    func testTheSizeCapIsExact() async {
        XCTAssertNotNil(ProfilePhoto.dataURL(fromJPEG: Data(repeating: 0, count: ProfilePhoto.maxBytes)))
        XCTAssertNil(ProfilePhoto.dataURL(fromJPEG: Data(repeating: 0, count: ProfilePhoto.maxBytes + 1)))
        XCTAssertNil(ProfilePhoto.dataURL(fromJPEG: Data()), "nothing to send")
    }

    /// A photo too large at every quality is refused, and the photo on the account stays.
    func testAPhotoTooLargeAtEveryQualityIsRefused() async {
        let (editor, _, _) = editor()
        let taken = editor.setPhoto { _ in Data(repeating: 1, count: ProfilePhoto.maxBytes * 2) }

        XCTAssertFalse(taken)
        XCTAssertEqual(editor.photoError, ProfileEditor.Copy.photoTooLarge)
        XCTAssertEqual(editor.avatar, Self.photo)
        XCTAssertFalse(editor.hasChanges)
    }

    func testAnUnreadablePhotoSaysSo() async {
        let (editor, _, _) = editor()
        XCTAssertFalse(editor.setPhoto { _ in nil })
        XCTAssertEqual(editor.photoError, ProfileEditor.Copy.photoUnreadable)
    }

    /// The web's crop: scaled to cover the square, centred, the long side trimmed evenly.
    func testThePhotoIsCroppedToTheCentreSquare() async throws {
        let landscape = try XCTUnwrap(ProfilePhoto.drawRect(forImageWidth: 1024, height: 512))
        XCTAssertEqual(landscape.width, 512)
        XCTAssertEqual(landscape.height, 256)
        XCTAssertEqual(landscape.x, -128)
        XCTAssertEqual(landscape.y, 0)

        let portrait = try XCTUnwrap(ProfilePhoto.drawRect(forImageWidth: 100, height: 400))
        XCTAssertEqual(portrait.width, 256)
        XCTAssertEqual(portrait.height, 1024)
        XCTAssertEqual(portrait.x, 0)
        XCTAssertEqual(portrait.y, -384)

        XCTAssertNil(ProfilePhoto.drawRect(forImageWidth: 0, height: 400))
    }

    func testStoredPhotosAreReadByKind() async {
        XCTAssertEqual(ProfilePhoto.source(of: Self.photo), .embedded(Data([0xFF, 0xD8, 0xFF, 0xD9])))
        XCTAssertEqual(
            ProfilePhoto.source(of: "https://example.test/me.png"),
            .remote(URL(string: "https://example.test/me.png")!))
        XCTAssertNil(ProfilePhoto.source(of: "http://example.test/me.png"), "only https is fetched")
        XCTAssertNil(ProfilePhoto.source(of: ""))
        XCTAssertNil(ProfilePhoto.source(of: nil))
        XCTAssertNil(ProfilePhoto.source(of: "data:text/plain;base64,aGk="), "not an image")
        XCTAssertNil(ProfilePhoto.source(of: "data:image/png,rawbytes"), "not base64")
    }

    func testTheMonogramFollowsTheWeb() async {
        XCTAssertEqual(ProfilePhoto.monogram(name: "radha", email: "x@y.z"), "R")
        XCTAssertEqual(ProfilePhoto.monogram(name: "  ", email: "adv@example.test"), "A")
        XCTAssertEqual(ProfilePhoto.monogram(name: nil, email: nil), "U")
    }

    // MARK: - What the session keeps

    /// The account the server stored is adopted, persisted, and shown — and the parts of the
    /// account the reply does not carry are kept.
    func testTheSavedAccountIsAdoptedIntoTheSession() async throws {
        let session = await signedInSession()
        HTTPStub.always(.json(#"""
        {"success":true,"user":{"id":42,"email":"adv@example.test","name":"Radha Iyer",
         "avatar":"","title":"Senior Advocate","organization":"Iyer Chambers",
         "phone":"+919876543210","practice_role":"litigator","plan":"lite",
         "plan_source":"admin","plan_expires_at":null,"suspended":false,"suspended_reason":null,
         "needsPlan":false,"suspendedReason":null}}
        """#))
        let user = try XCTUnwrap(session.currentUser)
        let editor = ProfileEditor(user: user, service: session.profile) { session.adoptProfile($0) }
        editor.name = "Radha Iyer"
        editor.title = "Senior Advocate"
        editor.removePhoto()

        let saved = await editor.save()

        XCTAssertTrue(saved)
        XCTAssertTrue(editor.didSave)
        let account = try XCTUnwrap(session.currentUser)
        XCTAssertEqual(account.name, "Radha Iyer")
        XCTAssertEqual(account.title, "Senior Advocate")
        XCTAssertEqual(account.avatar, "")
        XCTAssertEqual(account.planLabel, "Lite", "kept: the reply does not carry it")
        XCTAssertEqual(account.preferredModel, "fast", "kept: the reply does not carry it")

        // Persisted, so the next launch restores the saved profile.
        let stored = try XCTUnwrap(credentialStore.string(for: "auth.user"))
        let restored = try JSONDecoder().decode(User.self, from: Data(stored.utf8))
        XCTAssertEqual(restored.name, "Radha Iyer")
        XCTAssertEqual(restored.title, "Senior Advocate")
    }

    /// The fields are what the row now holds — an empty title from the server replaces the old.
    func testAnEmptiedFieldIsAdoptedAsEmpty() async throws {
        let session = await signedInSession()
        session.adoptProfile(User(id: 42, name: "R. Iyer", avatar: "", title: "", organization: ""))
        XCTAssertEqual(session.currentUser?.title, "")
        XCTAssertEqual(session.currentUser?.organization, "")
        XCTAssertEqual(session.currentUser?.email, "adv@example.test", "absent from the reply: kept")
    }

    /// A reply about another account is never adopted.
    func testAReplyForAnotherAccountIsIgnored() async {
        let session = await signedInSession()
        session.adoptProfile(User(id: 99, name: "Somebody Else"))
        XCTAssertEqual(session.currentUser?.name, "R. Iyer")
    }

    /// A reply that confirms the save but carries no account shows what was sent.
    func testASuccessWithoutAnAccountShowsWhatWasSent() async throws {
        let session = await signedInSession()
        HTTPStub.always(.json(#"{"success":true}"#))
        let user = try XCTUnwrap(session.currentUser)
        let editor = ProfileEditor(user: user, service: session.profile) { session.adoptProfile($0) }
        editor.organization = "  New Chambers "

        await editor.save()

        XCTAssertEqual(session.currentUser?.organization, "New Chambers")
        XCTAssertEqual(session.currentUser?.avatar, Self.photo)
    }

    // MARK: - Failures

    /// The route's own failure sentence is not shown; this client's is. Nothing is adopted.
    func testAServerFailureIsWordedCalmlyAndChangesNothing() async throws {
        let session = await signedInSession()
        HTTPStub.always(.json(#"{"error":"Profile update failed"}"#, status: 500))
        let user = try XCTUnwrap(session.currentUser)
        let editor = ProfileEditor(user: user, service: session.profile) { session.adoptProfile($0) }
        editor.name = "Radha Iyer"

        let saved = await editor.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(editor.saveError, ProfileEditor.Copy.notSaved)
        XCTAssertEqual(session.currentUser?.name, "R. Iyer")
        XCTAssertFalse(editor.isSaving)
        XCTAssertTrue(editor.canSave, "the edit is still there to try again")
    }

    /// A 200 that says it did not save is not saved.
    func testASuccessFalseIsNotASave() async throws {
        let session = await signedInSession()
        HTTPStub.always(.json(#"{"success":false}"#))
        let user = try XCTUnwrap(session.currentUser)
        let editor = ProfileEditor(user: user, service: session.profile) { session.adoptProfile($0) }
        editor.name = "Radha Iyer"

        await editor.save()

        XCTAssertEqual(editor.saveError, ProfileEditor.Copy.notSaved)
        XCTAssertEqual(session.currentUser?.name, "R. Iyer")
    }

    func testOfflineSaysOffline() async {
        let service = FakeProfileService()
        service.error = APIError.transport("The Internet connection appears to be offline.")
        let (editor, _, _) = editor(service: service)
        editor.name = "Radha Iyer"

        await editor.save()

        XCTAssertEqual(editor.saveError, DisplayText.offlineMessage)
    }

    // MARK: - Helpers

    private var credentialStore = InMemoryCredentialStore()

    private func signedInSession() async -> Session {
        let encoded = String(decoding: try! JSONEncoder().encode(Self.user), as: UTF8.self)
        credentialStore = InMemoryCredentialStore(["auth.token": "tok", "auth.user": encoded])
        let session = Session(
            store: credentialStore, cache: ResponseCache(store: InMemoryCacheStore()),
            urlSession: HTTPStub.session())
        await session.restore()
        return session
    }
}

/// Records what the editor sent. Test-only.
final class FakeProfileService: ProfileUpdating, @unchecked Sendable {
    struct Call: Equatable {
        let name: String
        let avatar: String
        let title: String
        let organization: String
    }

    var calls: [Call] = []
    var error: Error?
    /// What the "server" answers; `nil` echoes what was sent.
    var reply: User?

    func update(name: String, avatar: String, title: String, organization: String) async throws -> User? {
        calls.append(Call(name: name, avatar: avatar, title: title, organization: organization))
        if let error { throw error }
        return reply ?? User(id: 42, name: name, avatar: avatar, title: title, organization: organization)
    }
}

final class AdoptedBox: @unchecked Sendable {
    var users: [User] = []
}
