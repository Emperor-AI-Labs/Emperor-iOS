import AppIntents
import SwiftUI

// Siri and Shortcuts: "What's listed today?", "What's listed tomorrow?" and "Open my calendar".
//
// They run in the app's own process, so they answer from the cause list the app last cached —
// no network, no wait, and the same rows the Calendar shows. The wording is `ListedDayAnswer`'s,
// in the core, where it is tested; these only fetch the inputs and hand back what it says.
//
// No capability or entitlement is needed: App Shortcuts are declared in code and work in a build
// signed by a free Apple ID.

/// "What's listed today in Emperor?"
struct WhatsListedTodayIntent: AppIntent {
    static var title: LocalizedStringResource { "What's Listed Today" }
    static var description: IntentDescription {
        IntentDescription("Says which of your matters are listed today, with court and item.")
    }
    /// The answer names clients' matters, so Siri asks for the phone to be unlocked first rather
    /// than reading them out from a locked one.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let answer = await ListedDayLookup.answer(for: .today)
        return .result(
            dialog: IntentDialog(stringLiteral: answer.dialog),
            view: ListedDaySnippet(answer: answer))
    }
}

/// "What's listed tomorrow in Emperor?" — tomorrow in India.
struct WhatsListedTomorrowIntent: AppIntent {
    static var title: LocalizedStringResource { "What's Listed Tomorrow" }
    static var description: IntentDescription {
        IntentDescription("Says which of your matters are listed tomorrow, with court and item.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let answer = await ListedDayLookup.answer(for: .tomorrow)
        return .result(
            dialog: IntentDialog(stringLiteral: answer.dialog),
            view: ListedDaySnippet(answer: answer))
    }
}

/// "Open my calendar in Emperor" — the Calendar tab, on today in India.
struct OpenCalendarIntent: AppIntent {
    static var title: LocalizedStringResource { "Open My Calendar" }
    static var description: IntentDescription {
        IntentDescription("Opens Emperor on today in your Calendar.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        // The same path a widget tap takes — see `AppLinks`.
        AppLinks.open(.calendar(day: nil))
        return .result()
    }
}

/// The phrases Siri and Spotlight offer without any setup. Every phrase carries the app's name,
/// as App Shortcuts require.
struct EmperorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsListedTodayIntent(),
            phrases: [
                "What's listed today in \(.applicationName)",
                "What's listed today on \(.applicationName)",
                "What's on my \(.applicationName) cause list today",
                "My hearings today in \(.applicationName)",
            ],
            shortTitle: "Listed Today",
            systemImageName: "calendar")
        AppShortcut(
            intent: WhatsListedTomorrowIntent(),
            phrases: [
                "What's listed tomorrow in \(.applicationName)",
                "What's listed tomorrow on \(.applicationName)",
                "My hearings tomorrow in \(.applicationName)",
            ],
            shortTitle: "Listed Tomorrow",
            systemImageName: "calendar.badge.clock")
        AppShortcut(
            intent: OpenCalendarIntent(),
            phrases: [
                "Open my calendar in \(.applicationName)",
                "Show my \(.applicationName) calendar",
            ],
            shortTitle: "Open My Calendar",
            systemImageName: "calendar.circle")
    }
}

/// Reads what the answer needs from the app's session: who is signed in, and the cached cause
/// list with when it was fetched.
@MainActor
enum ListedDayLookup {
    static func answer(for day: ListedDayAnswer.Day) async -> ListedDayAnswer {
        guard let session = AppNotifications.shared.session else {
            return ListedDayAnswer.make(
                day: day, isSignedIn: false, listings: nil, fetchedAt: nil, now: Date())
        }
        // Run with no screen — Siri can start the app just for this — nothing has restored the
        // session yet. Reading the Keychain is local; the intent's authentication policy has
        // already had the phone unlocked, so the token is readable.
        if session.state == .loading {
            await session.restore()
        }
        let isSignedIn = session.currentUser != nil
        let cached = isSignedIn ? session.cache.load([CauseListing].self, for: .causeList) : nil
        return ListedDayAnswer.make(
            day: day, isSignedIn: isSignedIn, listings: cached?.value,
            fetchedAt: cached?.storedAt, now: Date())
    }
}

/// What Shortcuts and Siri show under the spoken answer: the day, its first few matters with
/// where each is heard, and how old the list is when that matters.
struct ListedDaySnippet: View {
    let answer: ListedDayAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let day = answer.day {
                Text(IndianDay.long(day))
                    .font(.headline)
            } else {
                // Signed out, or nothing loaded yet: the spoken answer says what to do, and the
                // snippet is only the app's mark rather than an empty box.
                Label("Emperor", systemImage: "calendar")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if !answer.matters.isEmpty {
                ForEach(answer.matters) { matter in
                    row(matter)
                }
                if let more = TodayCopy.more(shown: answer.matters.count, of: answer.total) {
                    Text(more)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let next = answer.next {
                Text(TodayCopy.next(next))
                    .font(.subheadline)
                ForEach(next.matters) { matter in
                    row(matter)
                }
            }
            if let age = answer.age {
                Text(age)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func row(_ matter: TodayMatter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(matter.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let place = place(matter) {
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Bombay High Court · Court 12 · Item 7 · 10:30 AM", as much of it as is known.
    private func place(_ matter: TodayMatter) -> String? {
        let parts = [matter.court, TodayCopy.location(matter)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
