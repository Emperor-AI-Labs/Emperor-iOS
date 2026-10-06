import Foundation

/// What this device may tell the person, and when.
///
/// ## Off until asked for
///
/// `isEnabled` starts false and the system's permission prompt is shown only when the person
/// turns it on in Settings — never at launch. A prompt that arrives before the app has said what
/// it would send is the one most people refuse, and iOS asks only once.
///
/// Everything under the master switch defaults **on**: someone who has just turned
/// notifications on has said what they want, and making them find three more switches before
/// anything arrives would read as the feature not working.
///
/// ## Times are Indian times
///
/// `briefingMinutes` and `reminderMinutes` are minutes after midnight **in India**, whatever the
/// device's zone. A briefing is about a court day, and court days are Indian days (`WireDate`);
/// an advocate in London still wants the list before the court sits at 10:30 IST, not before
/// their own 10:30. The settings screen says "IST" beside each time for that reason.
///
/// ## Stored as one value
///
/// One JSON string under one key rather than a key per switch. `PreferenceStore.bool` reads an
/// absent key as `false`, which cannot express "on unless turned off" — and a value written
/// whole cannot be read back half old and half new.
struct NotificationPreferences: Codable, Equatable, Sendable {
    /// The master switch. Nothing is scheduled while it is off, whatever the rest say.
    var isEnabled = false
    /// The morning briefing on a day with listings.
    var morningBriefing = true
    /// When it arrives, as minutes after midnight IST. 08:00 by default — the time the web's
    /// daily email goes (`lib/dailyNotify.js`, `NOTIF_TIME`).
    var briefingMinutes = 8 * 60
    /// The reminder the evening before a day with listings.
    var eveningReminder = true
    /// When it arrives, as minutes after midnight IST, on the day before.
    var reminderMinutes = 19 * 60
    /// New items in the account's own notification feed — the Updates screen.
    var updates = true

    static let storageKey = "notifications.preferences.v1"

    init() {}

    /// Reads the stored choice, falling back to the defaults for an absent or unreadable value.
    static func stored(in store: any PreferenceStore) -> NotificationPreferences {
        guard let raw = store.string(for: storageKey),
              let decoded = try? JSONDecoder().decode(
                NotificationPreferences.self, from: Data(raw.utf8))
        else { return NotificationPreferences() }
        return decoded
    }

    func save(to store: any PreferenceStore) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.setString(String(decoding: data, as: UTF8.self), for: Self.storageKey)
    }

    /// Lenient: a key this build does not find keeps its default, so a value written by an older
    /// build — before a switch existed — still reads, rather than resetting every choice.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotificationPreferences()
        func flag(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        func time(_ key: CodingKeys, _ fallback: Int) -> Int {
            Self.validMinutes(try? container.decodeIfPresent(Int.self, forKey: key)) ?? fallback
        }
        isEnabled = flag(.isEnabled, defaults.isEnabled)
        morningBriefing = flag(.morningBriefing, defaults.morningBriefing)
        eveningReminder = flag(.eveningReminder, defaults.eveningReminder)
        updates = flag(.updates, defaults.updates)
        briefingMinutes = time(.briefingMinutes, defaults.briefingMinutes)
        reminderMinutes = time(.reminderMinutes, defaults.reminderMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, morningBriefing, briefingMinutes, eveningReminder, reminderMinutes, updates
    }

    // MARK: - Times

    /// A time of day as minutes after midnight, or `nil` when it is not one. A stored value
    /// outside the day would schedule a briefing on the wrong date.
    static func validMinutes(_ minutes: Int?) -> Int? {
        guard let minutes, (0..<(24 * 60)).contains(minutes) else { return nil }
        return minutes
    }

    /// "08:00" — the 24-hour form the platform writes its own `NOTIF_TIME` in.
    static func clock(_ minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        let hours = clamped / 60
        let mins = clamped % 60
        return (hours < 10 ? "0" : "") + "\(hours):" + (mins < 10 ? "0" : "") + "\(mins)"
    }

    /// Reads the platform's "HH:MM" back into minutes, or `nil` for anything else.
    static func minutes(fromClock text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hours = Int(parts[0]), let mins = Int(parts[1]),
              (0..<24).contains(hours), (0..<60).contains(mins)
        else { return nil }
        return hours * 60 + mins
    }

    /// The instant a time of day falls at on a court day: `minutes` after midnight IST on `day`.
    ///
    /// Plain arithmetic on top of `WireDate.parseDay`, which is exact because India keeps no
    /// daylight saving — every Indian day is 86,400 seconds long.
    static func instant(minutes: Int, on day: String) -> Date? {
        guard let midnight = WireDate.parseDay(day), validMinutes(minutes) != nil else {
            return nil
        }
        return midnight.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// The time of day an instant falls at in India, as minutes after midnight — what a time
    /// picker showing IST hands back.
    static func minutesInIndia(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = WireDate.india
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// The feed items this device has already accounted for, so the next look at the feed can tell
/// what is new.
///
/// Kept per account: a different person signing in on the same phone starts from nothing, which
/// the diff reads as a first look rather than a backlog to announce (`UpdateAlerts`).
struct SeenUpdates: Codable, Equatable, Sendable {
    let userID: Int
    /// Newest first, as the feed orders them, and bounded — see `UpdateAlerts.rememberedLimit`.
    var ids: [String]

    static let storageKey = "notifications.updates.seen.v1"

    /// The ids seen for this account, or `nil` when this account has never been looked at here.
    static func stored(in store: any PreferenceStore, userID: Int) -> [String]? {
        guard let raw = store.string(for: storageKey),
              let decoded = try? JSONDecoder().decode(SeenUpdates.self, from: Data(raw.utf8)),
              decoded.userID == userID
        else { return nil }
        return decoded.ids
    }

    func save(to store: any PreferenceStore) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        store.setString(String(decoding: data, as: UTF8.self), for: Self.storageKey)
    }

    /// Forgets what was seen, so the next look is a first look and announces nothing.
    ///
    /// `PreferenceStore` has no removal, so an empty string stands for "nothing stored" — it
    /// does not decode, which is exactly how an absent value reads.
    static func forget(in store: any PreferenceStore) {
        store.setString("", for: storageKey)
    }
}
