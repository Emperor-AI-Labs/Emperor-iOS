import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The Limitation Radar's form and its answer.
///
/// The form is the web's: the nature of the suit, the date time began to run, the filing date,
/// and optionally when Section 12A mediation was applied for and concluded. Dates are held as the
/// bare `YYYY-MM-DD` the route takes; `date(forDay:)` and `day(for:)` turn them into and out of a
/// date picker's `Date` in India's zone, so the day picked is the day sent wherever the phone is.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class LimitationRadarViewModel {
    var profileKey = LimitationProfile.defaultKey
    var causeOfAction = ""
    var intendedFiling = ""
    var mediationStart = ""
    var mediationEnd = ""

    private(set) var isRunning = false
    private(set) var result: LimitationAudit?
    private(set) var error: String?

    private let service: any LimitationRadarProviding

    init(service: any LimitationRadarProviding) {
        self.service = service
    }

    var profile: LimitationProfile { LimitationProfile.profile(for: profileKey) }
    var profiles: [LimitationProfile] { LimitationProfile.all }

    /// The web's own check before anything is sent — "Enter the date time began to run and the
    /// filing date." — or `nil` when both required dates are there.
    var incompleteMessage: String? {
        let missing = [
            Self.blank(causeOfAction) ? "date time began to run" : nil,
            Self.blank(intendedFiling) ? "filing date" : nil,
        ].compactMap { $0 }
        return missing.isEmpty ? nil : "Enter the \(missing.joined(separator: " and the "))."
    }

    /// What the button says.
    var runLabel: String { isRunning ? "Running limitation audit…" : "Run Limitation Audit" }

    static let unreachableMessage =
        "The limitation audit service could not be reached. Check your connection and try again."

    func run() async {
        guard !isRunning else { return }
        if let incompleteMessage {
            result = nil
            error = incompleteMessage
            return
        }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            result = try await service.audit(LimitationRequest(
                profile: profileKey,
                causeOfAction: causeOfAction,
                intendedFiling: intendedFiling,
                mediationStart: mediationStart,
                mediationEnd: mediationEnd))
        } catch let failure as APIError {
            result = nil
            if case .transport = failure {
                error = Self.unreachableMessage
            } else {
                error = failure.errorDescription ?? Self.unreachableMessage
            }
        } catch {
            result = nil
            self.error = Self.unreachableMessage
        }
    }

    // MARK: - Days

    /// The picker's `Date` for a stored day: midnight that day in India.
    nonisolated static func date(forDay day: String) -> Date? { WireDate.parseDay(day) }

    /// The stored day for a picker's `Date`, read in India — the zone the picker is shown in.
    nonisolated static func day(for date: Date) -> String { WireDate.dayKey(date) }

    /// The day a date field starts on when it is first filled: today, in India.
    nonisolated static func today(now: Date = Date()) -> String { WireDate.todayKey(now: now) }

    private static func blank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
