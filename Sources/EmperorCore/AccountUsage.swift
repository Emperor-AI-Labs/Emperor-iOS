import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Observation
#endif

/// This month's allowances and how much of each is used — the platform's usage meters.
///
/// Read from `GET /billing/entitlements`, which the web's usage page draws from. **Read only,
/// and nothing here sells anything.** The route also returns prices, overage rates and an
/// `upgradable` flag; none of it is decoded, because this app takes no money and links to
/// nothing that does. What a person gets from this screen is the answer to "why was that
/// refused?" before it happens: how many questions are left, and when they renew.
struct AccountUsage: Equatable, Sendable {

    /// One allowance.
    struct Meter: Equatable, Sendable, Identifiable {
        enum Kind: String, Equatable, Sendable, CaseIterable {
            case questions, deepThinking, documents, scannedPages, storage, matters
        }

        var kind: Kind
        var used: Double
        /// `nil` when the plan sets no limit. The platform writes "unlimited" as `-1` or omits
        /// it (`planLimits.unlimited`), and both become `nil` here.
        var limit: Double?

        var id: Kind { kind }

        /// 0…1 of the allowance used, or nil when there is no limit to measure against.
        var fraction: Double? {
            guard let limit, limit > 0 else { return nil }
            return min(1, max(0, used / limit))
        }

        /// A limit of zero means the plan does not include it at all.
        var isIncluded: Bool { limit != 0 }

        var isExhausted: Bool {
            guard let limit, limit > 0 else { return false }
            return used >= limit
        }

        /// Most of it gone: worth drawing differently before it runs out.
        var isRunningLow: Bool { (fraction ?? 0) >= 0.8 && !isExhausted }

        /// The meter's state in words — "Used up", "Running low" — or `nil` when there is
        /// nothing to say.
        ///
        /// The bar and the figures already change colour, but a colour is not a statement: it
        /// says nothing to VoiceOver, and little to anyone who cannot tell the danger red from
        /// the warning amber. So the row also says it.
        var statusLabel: String? {
            if isExhausted { return "Used up" }
            if isRunningLow { return "Running low" }
            return nil
        }

        var title: String {
            switch kind {
            case .questions: return "Questions"
            case .deepThinking: return "Thinking-mode questions"
            case .documents: return "Documents uploaded"
            case .scannedPages: return "Scanned pages read"
            case .storage: return "Storage"
            case .matters: return "Matters tracked"
            }
        }

        /// "120 of 1,000", "2.4 GB of 10 GB", "37 this month".
        var summary: String {
            guard isIncluded else { return "Not included" }
            let usedText = format(used)
            guard let limit else {
                return kind == .storage || kind == .matters ? usedText : "\(usedText) this month"
            }
            return "\(usedText) of \(format(limit))"
        }

        /// Deep-thinking questions are a sub-allowance *inside* the questions allowance, not
        /// an extra (`planLimits.DEEP_THINKING_DRAWS_FROM_CHAT_POOL`). Said once, under the row,
        /// so nobody reads the two meters as two separate pools.
        var note: String? {
            kind == .deepThinking ? "Counted within your questions. Once these are used, "
                + "thinking-mode questions are answered in quick mode." : nil
        }

        private func format(_ value: Double) -> String {
            if kind == .storage { return AccountUsage.bytes(value) }
            return DisplayText.grouped(Int(value.rounded()))
        }
    }

    var planLabel: String?
    /// Whether limits are enforced on this account. Staff and demo accounts are not metered, and
    /// are shown their usage with no limits rather than limits they are not held to.
    var isMetered: Bool
    /// The plan's dated period has ended.
    var hasExpired: Bool
    /// When this month's allowances start again — midnight in India on the 1st.
    var renewsOn: Date?
    var meters: [Meter]

    /// Storage the way people read it: "850 MB", "2.4 GB". Decimal units, as the platform
    /// states its allowances ("10 GB").
    static func bytes(_ value: Double) -> String {
        let gb = value / 1_000_000_000
        if gb >= 1 {
            let rounded = (gb * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded)) GB" : String(format: "%.1f GB", rounded)
        }
        let mb = value / 1_000_000
        if mb >= 1 { return "\(Int(mb.rounded())) MB" }
        return "\(Int((value / 1000).rounded())) KB"
    }
}

// MARK: - Wire

/// The parts of `/billing/entitlements` this client reads. Everything optional: the response
/// is wide, changes often, and a field it stops sending must not cost the whole screen.
struct EntitlementsResponse: Decodable, Sendable {
    var success: Bool?
    var signedIn: Bool?
    var planLabel: String?
    var expired: Bool?
    var metered: Bool?
    var limits: Limits?
    var usage: Usage?

    struct Limits: Decodable, Sendable {
        var matters: Double?
        var storageGb: Double?
        var documents: Double?
        var scannedPages: Double?
        var chatQueries: Double?
        var deepThinkingQueries: Double?
    }

    struct Usage: Decodable, Sendable {
        var resetsAt: String?
        var chatQueries: Double?
        var deepThinkingQueries: Double?
        var scannedPages: Double?
        var documents: Double?
        var matters: Double?
        var storageUsedBytes: Double?
        var storageAllowanceBytes: Double?
    }

    /// Converts to the screen's model. Limits are dropped for an unmetered account, which is
    /// what the platform's own meters do.
    var usageModel: AccountUsage {
        let metered = metered ?? false
        func limit(_ raw: Double?) -> Double? {
            guard metered, let raw, raw >= 0 else { return nil }
            return raw
        }
        let storageAllowance = usage?.storageAllowanceBytes
            ?? limits?.storageGb.map { $0 * 1_000_000_000 }

        var meters: [AccountUsage.Meter] = [
            .init(kind: .questions, used: usage?.chatQueries ?? 0, limit: limit(limits?.chatQueries)),
            .init(kind: .deepThinking, used: usage?.deepThinkingQueries ?? 0,
                  limit: limit(limits?.deepThinkingQueries)),
            .init(kind: .documents, used: usage?.documents ?? 0, limit: limit(limits?.documents)),
            .init(kind: .scannedPages, used: usage?.scannedPages ?? 0,
                  limit: limit(limits?.scannedPages)),
            .init(kind: .storage, used: usage?.storageUsedBytes ?? 0, limit: limit(storageAllowance)),
        ]
        // Matters are a running total, not a monthly count, and only some plans cap them.
        if let matters = usage?.matters {
            meters.append(.init(kind: .matters, used: matters, limit: limit(limits?.matters)))
        }
        return AccountUsage(
            planLabel: planLabel,
            isMetered: metered,
            hasExpired: expired ?? false,
            renewsOn: WireDate.parse(usage?.resetsAt),
            meters: meters)
    }
}

protocol UsageProviding: Sendable {
    func usage() async throws -> AccountUsage
}

struct UsageService: UsageProviding {
    let client: APIClient

    func usage() async throws -> AccountUsage {
        let request = try await client.makeRequest("GET", "/billing/entitlements")
        return try await client.send(request, as: EntitlementsResponse.self).usageModel
    }
}

// MARK: - View model

#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AccountUsageViewModel {
    private(set) var usage: AccountUsage?
    private(set) var state: LoadState = .idle

    private let service: any UsageProviding

    init(service: any UsageProviding) {
        self.service = service
    }

    func load() async {
        state = .loading
        do {
            usage = try await service.usage()
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    /// The line under the plan's name.
    var renewalLine: String? {
        guard let usage else { return nil }
        if usage.hasExpired { return "This account's plan has ended." }
        guard usage.isMetered else { return "No usage limits apply to this account." }
        return usage.renewsOn.map { "Monthly allowances renew on \(DisplayText.renewalDay($0))." }
    }

    /// The meters worth a row. One the plan does not include, with nothing used, is noise.
    var visibleMeters: [AccountUsage.Meter] {
        (usage?.meters ?? []).filter { $0.isIncluded || $0.used > 0 }
    }
}
