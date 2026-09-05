import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a court needs before it can be searched.
///
/// The platform answers this per court rather than publishing a table, and the shape of the form
/// follows from it: whether a bench must be chosen, where the case types come from, and — for the
/// district consumer commissions — whether the bench list has to be reached a state at a time.
///
/// Fetched rather than hardcoded because it genuinely moves. A tribunal that gains a second bench
/// changes its contract, and a client carrying its own copy would keep offering the old shape and
/// send searches that cannot succeed.
struct CourtContract: Equatable, Sendable {
    /// The court cannot be searched without a bench, commission or zone.
    var needsBench = false
    /// The bench list is reached state by state rather than published flat. DCDRC only.
    var benchCascade = false
    /// Benches already known — some contracts carry them, others need a second call.
    var benches: [CourtOption] = []
    /// Case types already known. Empty means "ask for them once a bench is chosen", which is not
    /// the same as "this court has none": the consumer fora genuinely have none, and say so with
    /// `takesCaseType == false`.
    var caseTypes: [CourtOption] = []
    /// Whether a case type is part of this court's identity at all.
    var takesCaseType = true
    /// Whether the platform can search this court. False for anything whose adapter is absent.
    var isSupported = true

    /// What a court the platform cannot reach looks like.
    static let unsupported = CourtContract(takesCaseType: false, isSupported: false)

    /// The contract for a court that publishes its catalogue rather than serving it.
    ///
    /// Four of the seven families do, and for them there is nothing to ask and no round trip to
    /// make: the Supreme Court's case types, NCLT's fifteen benches and NCLAT's two are fixed
    /// lists the platform ships in its own source. Returning `nil` means "this one has to be
    /// fetched".
    ///
    /// A property of the court, not of the transport — which is why it lives here rather than
    /// inside the service. A screen driven by a stand-in provider gets the same answer the real
    /// one would, because for these four there is no provider involved either way.
    static func published(for family: CourtFamily) -> CourtContract? {
        switch family {
        case .supremeCourt:
            return CourtContract(caseTypes: CourtCatalogue.supremeCourtCaseTypes)
        case .nclt:
            return CourtContract(
                needsBench: true,
                benches: CourtCatalogue.ncltBenches,
                caseTypes: CourtCatalogue.ncltCaseTypes)
        case .nclat:
            return CourtContract(
                needsBench: true,
                benches: CourtCatalogue.nclatBenches,
                caseTypes: CourtCatalogue.nclatCaseTypes)
        case .districtCourt:
            return .unsupported
        case .highCourt, .tribunal, .consumerForum:
            return nil
        }
    }
}

/// The dropdown catalogues behind the search form.
///
/// Separate from `CourtSearching` because these are metadata rather than lookups: they are fast,
/// idempotent, safe to retry, and a screen faking them wants a plain table rather than a court.
protocol CourtMetadataProviding: Sendable {
    func contract(for court: Court) async throws -> CourtContract
    /// eCourts benches for a High Court, by its state code.
    func highCourtBenches(stateCode: String) async throws -> [CourtOption]
    func highCourtCaseTypes(stateCode: String, courtCode: String) async throws -> [CourtOption]
    func tribunalCaseTypes(courtID: String, bench: String) async throws -> [CourtOption]
    func consumerStates() async throws -> [CourtOption]
    func consumerDistricts(stateID: String) async throws -> [CourtOption]
}

struct CourtMetadataService: CourtMetadataProviding {
    let client: APIClient

    /// These open a live session with the court's own site to read a dropdown, so they are slower
    /// than they look — but nothing like a search, which additionally solves a captcha and reads
    /// a case. Long enough to succeed on a slow court, short enough that a dead one does not hold
    /// a form open.
    static let timeout: TimeInterval = 30

    // MARK: - Decoding
    //
    // Every one of these answers `200 { success: false }` on failure, so `success` is the only
    // signal and the status code is never consulted.

    private struct OptionsResponse: Decodable {
        var success: Bool?
        var error: String?
        var benches: [CourtOption]?
        var caseTypes: [CourtOption]?
        /// **`/court/forum/districts` answers under `benches`, not `districts`.** Only
        /// `/court/forum/states` uses its own noun. Decoding districts from a `districts` key
        /// would yield an empty list on a successful call, which reads as "this state has no
        /// commissions".
        var states: [CourtOption]?
    }

    private struct ContractResponse: Decodable {
        var success: Bool?
        var kind: String?
        var stateCode: String?
        var benches: [CourtOption]?
        var caseTypes: [CourtOption]?
        var contract: Contract?

        struct Contract: Decodable {
            var needsBench: Bool?
            var needsCaptcha: Bool?
            var caseTypeSource: String?
            var benchCascade: Bool?
        }
    }

    private func get<T: Decodable>(
        _ path: String, _ query: [String: String] = [:], as type: T.Type
    ) async throws -> T {
        var request = try await client.makeRequest("GET", path, query: query)
        request.timeoutInterval = Self.timeout
        let (data, _) = try await client.perform(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func options(
        _ path: String, _ query: [String: String], _ key: KeyPath<OptionsResponse, [CourtOption]?>
    ) async throws -> [CourtOption] {
        let response = try await get(path, query, as: OptionsResponse.self)
        guard response.success == true else {
            throw APIError.server(
                status: 200, message: response.error ?? "That list could not be loaded.")
        }
        return response[keyPath: key] ?? []
    }

    // MARK: - The contract

    func contract(for court: Court) async throws -> CourtContract {
        // The four that publish their own catalogues never reach the network. Kept total rather
        // than made a precondition so this stays safe to call for any court.
        if let published = CourtContract.published(for: court.family) { return published }

        switch court.family {
        case .supremeCourt, .nclt, .nclat, .districtCourt:
            return .unsupported   // unreachable: handled above

        case .highCourt:
            let response = try await get(
                "/court/hc/config", ["courtId": court.id], as: ContractResponse.self)
            guard response.success == true, response.kind != "unsupported" else {
                return .unsupported
            }
            // A dedicated portal hands back both lists at once; a generic eCourts court hands
            // back neither and needs `/court/hc/benches` then `/court/hc/casetypes`.
            return CourtContract(
                needsBench: response.contract?.needsBench ?? (response.kind == "generic"),
                benches: response.benches ?? [],
                caseTypes: response.caseTypes ?? [])

        case .tribunal:
            let response = try await get(
                "/court/tribunal/config", ["courtId": court.id], as: ContractResponse.self)
            guard response.success == true, response.kind != "unsupported" else {
                return .unsupported
            }
            // `caseTypes` comes back empty when a bench is needed, because the types depend on
            // it. That is a second call, not an absence.
            return CourtContract(
                needsBench: response.contract?.needsBench ?? false,
                benches: response.benches ?? [],
                caseTypes: response.caseTypes ?? [])

        case .consumerForum:
            let response = try await get(
                "/court/forum/config", ["courtId": court.id], as: ContractResponse.self)
            guard response.success == true, response.kind != "unsupported" else {
                return .unsupported
            }
            return CourtContract(
                needsBench: response.contract?.needsBench ?? false,
                benchCascade: response.contract?.benchCascade ?? false,
                benches: response.benches ?? [],
                // e-Jagriti identifies a matter by its case number alone.
                takesCaseType: false)
        }
    }

    // MARK: - The dependent lists

    func highCourtBenches(stateCode: String) async throws -> [CourtOption] {
        try await options("/court/hc/benches", ["stateCode": stateCode], \.benches)
    }

    func highCourtCaseTypes(stateCode: String, courtCode: String) async throws -> [CourtOption] {
        try await options(
            "/court/hc/casetypes", ["stateCode": stateCode, "courtCode": courtCode], \.caseTypes)
    }

    func tribunalCaseTypes(courtID: String, bench: String) async throws -> [CourtOption] {
        try await options(
            "/court/tribunal/casetypes", ["courtId": courtID, "bench": bench], \.caseTypes)
    }

    func consumerStates() async throws -> [CourtOption] {
        try await options("/court/forum/states", [:], \.states)
    }

    /// - Important: reads the **`benches`** key. See `OptionsResponse.states`.
    func consumerDistricts(stateID: String) async throws -> [CourtOption] {
        try await options("/court/forum/districts", ["stateId": stateID], \.benches)
    }
}
