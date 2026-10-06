import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Observation
#endif

// MARK: - The wire

/// What `POST /update-profile` is sent: the four profile fields, **every one, every time**.
///
/// The route writes the photo, title and organisation columns from whatever it is given, and an
/// absent key clears its column rather than leaving it alone (`sync-server.js`, the
/// `/update-profile` handler). So there is no such thing as a partial update against it: a
/// request carrying only the new title would clear the photo and the organisation beside it.
/// The fields are therefore non-optional, and the only way to build one is from a complete
/// profile — the values edited, and the current values for everything that was not. (A missing
/// name is the one that keeps its old value; it is sent anyway, for the same reason.)
///
/// The mobile number is deliberately **not** a field. The route touches it only when the key is
/// present, so leaving it out is what keeps this screen from changing it.
struct ProfileUpdate: Encodable, Equatable, Sendable {
    let userId: String
    let name: String
    /// A `data:` URL, an `https:` URL (a photo carried over from Google), or `""` for none —
    /// the web's own encoding for a removed photo.
    let avatar: String
    let title: String
    let organization: String
}

/// Writes the signed-in account's profile.
///
/// - Returns: the account as the server stored it, or `nil` when the reply carried no account.
protocol ProfileUpdating: Sendable {
    func update(
        name: String, avatar: String, title: String, organization: String
    ) async throws -> User?
}

struct ProfileService: ProfileUpdating {
    let client: APIClient

    private struct Reply: Decodable {
        let success: Bool?
        let user: User?

        enum CodingKeys: String, CodingKey { case success, user }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decodeIfPresent(Bool.self, forKey: .success)
            // An account this build cannot read does not undo a save the server reports; the
            // editor shows what it sent instead.
            user = try? container.decodeIfPresent(User.self, forKey: .user)
        }
    }

    func update(
        name: String, avatar: String, title: String, organization: String
    ) async throws -> User? {
        guard let credentials = await client.currentCredentials() else {
            throw APIError.notAuthenticated
        }
        let payload = ProfileUpdate(
            userId: credentials.userIDString, name: name, avatar: avatar, title: title,
            organization: organization)
        let request = try await client.makeRequest("POST", "/update-profile", body: payload)
        let reply = try await client.send(request, as: Reply.self)
        // A 200 that says it did not save is not saved.
        guard reply.success == true else {
            throw APIError.server(status: 200, message: ProfileEditor.Copy.notSaved)
        }
        return reply.user
    }
}

// MARK: - The photo

/// The rules for a profile photo, matching the web's.
///
/// The web reads the picked image, crops it to the centre square, scales it to 256 points and
/// stores it as a JPEG `data:` URL at 0.85 quality (`fileToAvatar`, `src/pages/Settings.jsx`) —
/// small enough to live in the account row, which is read back with every sign-in. The app
/// stores the same thing, so a photo set on either client looks the same on the other.
///
/// Drawing the image needs UIKit and lives in the app; what to draw, at what quality, and what
/// is too big to send are decided here.
enum ProfilePhoto {
    /// The side of the square the photo is drawn into, in pixels — the web's `size`.
    static let side: Double = 256

    /// The qualities tried in turn, the web's 0.85 first. A 256-pixel square almost always fits
    /// at the first; the rest are for the rare photo so busy that it does not.
    static let qualities: [Double] = [0.85, 0.7, 0.55, 0.4]

    /// The most JPEG bytes this client will send as a photo.
    ///
    /// The account row, photo included, comes back with every sign-in and every launch's
    /// account reading, so a large photo is paid for on every one of them. A 256-pixel JPEG is
    /// typically 15–40 KB; this leaves generous room while refusing anything that would make the
    /// account noticeably heavier to read.
    static let maxBytes = 150 * 1024

    /// Where the image is drawn inside the 256-pixel square: scaled to cover it and centred, so
    /// the overflow on the long side is cropped evenly — the web's `drawImage` arithmetic.
    ///
    /// `nil` for an image with no area, which cannot be drawn.
    static func drawRect(
        forImageWidth width: Double, height: Double
    ) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        let scale = max(side / width, side / height)
        let w = width * scale
        let h = height * scale
        return ((side - w) / 2, (side - h) / 2, w, h)
    }

    /// Encodes with the first quality that comes in under the cap.
    ///
    /// - Parameter jpeg: draws the photo at a given quality, or `nil` if it cannot.
    /// - Returns: the `data:` URL to store, or `nil` when no quality is small enough — or the
    ///   image could not be encoded at all.
    static func encode(_ jpeg: (Double) -> Data?) -> String? {
        for quality in qualities {
            guard let data = jpeg(quality) else { return nil }
            if let url = dataURL(fromJPEG: data) { return url }
        }
        return nil
    }

    /// A JPEG as the `data:` URL the web stores, or `nil` if it is empty or over the cap.
    static func dataURL(fromJPEG data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// Where a stored photo comes from.
    enum Source: Equatable, Sendable {
        /// Bytes carried in the account itself — the web's and this app's own photos.
        case embedded(Data)
        /// A photo on the web, such as one carried over from a Google sign-in.
        case remote(URL)
    }

    /// Reads the account's `avatar`. `nil` for none, and for anything that is neither an image
    /// `data:` URL nor an `https:` address — a value this client cannot show is shown as no photo
    /// rather than guessed at.
    static func source(of avatar: String?) -> Source? {
        let value = avatar?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        if value.lowercased().hasPrefix("data:image/") {
            guard let comma = value.firstIndex(of: ","),
                  value[..<comma].lowercased().hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...]),
                                  options: .ignoreUnknownCharacters),
                  !data.isEmpty
            else { return nil }
            return .embedded(data)
        }
        if let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil {
            return .remote(url)
        }
        return nil
    }

    /// The letter shown in place of a photo: the name's first, else the email's — the web's
    /// `(name || email || 'U').slice(0, 1).toUpperCase()`.
    static func monogram(name: String?, email: String?) -> String {
        for candidate in [name, email] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let first = trimmed.first { return String(first).uppercased() }
        }
        return "U"
    }
}

// MARK: - The editor

/// Settings → Edit profile: name, title, organisation and photo.
///
/// The web's profile card (`src/pages/Settings.jsx`), with two differences that are both about
/// not losing anything:
///
/// - **Every field is sent on every save** (`ProfileUpdate`). Change only the title, and the
///   name, photo and organisation go too, as they stood.
/// - **A name is required.** The web will save an empty one, which the route stores as an empty
///   name rather than keeping the old; an account with no name then greets its owner as nobody.
///
/// What the server stores is what is shown afterwards: the reply's account is adopted into the
/// session, so Settings reads back the saved values rather than the ones typed.
///
/// Email and mobile are shown, not edited — the address is the sign-in, and the number is
/// changed where it was given.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class ProfileEditor {

    enum Copy {
        static let title = "Edit profile"
        static let namePlaceholder = "Your name"
        static let titlePlaceholder = "e.g. Advocate, Delhi High Court"
        static let organizationPlaceholder = "Chambers, firm or company"
        static let nameRequired = "Enter your name to save your profile."
        static let notSaved = "Your profile wasn't saved. Try again in a moment."
        static let photoTooLarge = "That photo couldn't be made small enough to use. Try another."
        static let photoUnreadable = "That photo couldn't be read. Try another."
        static let readOnlyFooter = "Your email is how you sign in, so it can't be changed here."
        static let photoFooter = "Shown in Settings here and on the web."
    }

    var name: String
    var title: String
    var organization: String
    /// The photo as it will be sent: a `data:` URL, the account's own value carried over
    /// unchanged, or `""` for none.
    private(set) var avatar: String

    let email: String?
    let phone: String?

    private(set) var isSaving = false
    /// Why the last save failed, worded for the person. Cleared by the next attempt.
    var saveError: String?
    /// Why the last photo could not be used. Cleared by the next photo.
    var photoError: String?
    /// Set once a save has landed and the session holds the result.
    private(set) var didSave = false

    private let original: (name: String, avatar: String, title: String, organization: String)
    private let service: any ProfileUpdating
    private let adopt: @MainActor (User) -> Void
    private let accountID: Int

    /// - Parameters:
    ///   - user: the signed-in account, which the form starts from.
    ///   - adopt: receives the account as saved — `Session.adoptProfile`.
    init(user: User, service: any ProfileUpdating, adopt: @escaping @MainActor (User) -> Void) {
        self.accountID = user.id
        self.name = user.name ?? ""
        self.title = user.title ?? ""
        self.organization = user.organization ?? ""
        self.avatar = user.avatar ?? ""
        self.email = user.email
        self.phone = user.phone
        self.original = (user.name ?? "", user.avatar ?? "", user.title ?? "", user.organization ?? "")
        self.service = service
        self.adopt = adopt
    }

    // MARK: - What is shown

    var photo: ProfilePhoto.Source? { ProfilePhoto.source(of: avatar) }

    var hasPhoto: Bool { !avatar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var monogram: String { ProfilePhoto.monogram(name: name, email: email) }

    /// Shown under the name field once the name has been cleared, not before anything is typed.
    var nameProblem: String? {
        trimmed(name).isEmpty ? Copy.nameRequired : nil
    }

    /// Whether anything differs from the account as it was opened, once trimmed — so a stray
    /// space typed and deleted does not light up Save.
    var hasChanges: Bool {
        trimmed(name) != trimmed(original.name)
            || trimmed(title) != trimmed(original.title)
            || trimmed(organization) != trimmed(original.organization)
            || avatar != original.avatar
    }

    var canSave: Bool { hasChanges && nameProblem == nil && !isSaving }

    // MARK: - The photo

    /// Takes a newly drawn photo. `jpeg` draws it at a given quality — see `ProfilePhoto.encode`.
    ///
    /// - Returns: whether the photo was taken.
    @discardableResult
    func setPhoto(_ jpeg: (Double) -> Data?) -> Bool {
        photoError = nil
        guard let encoded = ProfilePhoto.encode(jpeg) else {
            // Told apart, because the remedy differs: an unreadable file is the wrong file, an
            // oversized one is the right file at the wrong size.
            let unreadable = jpeg(ProfilePhoto.qualities[0]) == nil
            photoError = unreadable ? Copy.photoUnreadable : Copy.photoTooLarge
            return false
        }
        avatar = encoded
        return true
    }

    /// The picker handed over something that is not an image.
    func photoCouldNotBeRead() {
        photoError = Copy.photoUnreadable
    }

    func removePhoto() {
        photoError = nil
        avatar = ""
    }

    // MARK: - Saving

    /// Sends the whole profile, and on success hands the stored account to the session.
    ///
    /// - Returns: whether it saved.
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        guard nameProblem == nil else {
            saveError = Copy.nameRequired
            return false
        }
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        let sent = (
            name: trimmed(name), avatar: avatar, title: trimmed(title),
            organization: trimmed(organization))
        do {
            let stored = try await service.update(
                name: sent.name, avatar: sent.avatar, title: sent.title,
                organization: sent.organization)
            // A reply with no account still means the row was written exactly as sent — the
            // route stores what it is given — so the sent values are what to show.
            var account = stored ?? User(id: accountID)
            if stored == nil {
                account.name = sent.name
                account.avatar = sent.avatar
                account.title = sent.title
                account.organization = sent.organization
            }
            adopt(account)
            name = sent.name
            title = sent.title
            organization = sent.organization
            didSave = true
            return true
        } catch {
            saveError = Self.message(for: error)
            return false
        }
    }

    /// The server's own failure sentence for this route is "Profile update failed", which says
    /// nothing a person can act on; offline and refusals keep their usual wording.
    static func message(for error: Error) -> String {
        if case APIError.server = error { return Copy.notSaved }
        if case APIError.decoding = error { return Copy.notSaved }
        return DisplayText.message(for: error)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
