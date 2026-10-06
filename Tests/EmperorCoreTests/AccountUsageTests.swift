import XCTest
@testable import EmperorCore

/// The usage meters, from the platform's `/billing/entitlements` response.
final class AccountUsageTests: XCTestCase {

    /// The shape the route returns for a metered account mid-month — trimmed of the pricing
    /// fields this client deliberately never reads.
    private static let metered = #"""
    {"success":true,"signedIn":true,"feeTier":"essential","planKey":"essential","planLabel":"Essential",
     "tier":"premium","expired":false,"cycle":"monthly",
     "limits":{"matters":-1,"storageGb":10,"documents":-1,"scannedPages":6000,"chatQueries":1000,"deepThinkingQueries":150,"support":"email"},
     "usage":{"period":"2026-10","resetsAt":"2026-10-31T18:30:00.000Z","chatQueries":812,"deepThinkingQueries":150,
              "scannedPages":120,"documents":44,"matters":7,"storageUsedBytes":2400000000,"storageAllowanceBytes":10000000000},
     "metered":true,"upgradable":true,"overageRates":{"chatQuery":2}}
    """#

    private func decode(_ json: String) throws -> AccountUsage {
        try JSONDecoder().decode(EntitlementsResponse.self, from: Data(json.utf8)).usageModel
    }

    private func meter(_ usage: AccountUsage, _ kind: AccountUsage.Meter.Kind) -> AccountUsage.Meter? {
        usage.meters.first { $0.kind == kind }
    }

    func testAMeteredAccountReadsAsItsAllowances() throws {
        let usage = try decode(Self.metered)
        XCTAssertEqual(usage.planLabel, "Essential")
        XCTAssertTrue(usage.isMetered)
        XCTAssertEqual(usage.renewsOn.map(WireDate.dayKey), "2026-11-01")

        let questions = try XCTUnwrap(meter(usage, .questions))
        XCTAssertEqual(questions.summary, "812 of 1,000")
        XCTAssertTrue(questions.isRunningLow)
        XCTAssertFalse(questions.isExhausted)

        let thinking = try XCTUnwrap(meter(usage, .deepThinking))
        XCTAssertTrue(thinking.isExhausted)
        XCTAssertNotNil(thinking.note, "a sub-allowance is said to be one")

        XCTAssertEqual(meter(usage, .storage)?.summary, "2.4 GB of 10 GB")
    }

    /// `-1` is the platform's word for "no limit" (`planLimits.UNLIMITED`). Reading it as a limit
    /// of minus one would draw a meter that is always over.
    func testMinusOneMeansNoLimit() throws {
        let usage = try decode(Self.metered)
        let documents = try XCTUnwrap(meter(usage, .documents))
        XCTAssertNil(documents.limit)
        XCTAssertNil(documents.fraction)
        XCTAssertEqual(documents.summary, "44 this month")
        XCTAssertEqual(meter(usage, .matters)?.summary, "7", "a running total, not a monthly count")
    }

    /// Staff and demo accounts are not metered; the platform shows them usage without limits
    /// rather than limits they are not held to.
    func testAnUnmeteredAccountShowsNoLimits() throws {
        let usage = try decode(Self.metered.replacingOccurrences(
            of: #""metered":true"#, with: #""metered":false"#))
        XCTAssertFalse(usage.isMetered)
        XCTAssertTrue(usage.meters.allSatisfy { $0.limit == nil })
    }

    func testAZeroLimitMeansNotIncluded() {
        let meter = AccountUsage.Meter(kind: .scannedPages, used: 0, limit: 0)
        XCTAssertFalse(meter.isIncluded)
        XCTAssertEqual(meter.summary, "Not included")
        XCTAssertNil(meter.fraction)
        XCTAssertNil(meter.statusLabel, "nothing to run out of")
    }

    /// A meter's state is said in words as well as drawn in colour, so it reaches VoiceOver and
    /// anyone who cannot tell the red from the amber — and only when there is something to say.
    func testAMetersStateIsSaidInWords() throws {
        let usage = try decode(Self.metered)
        XCTAssertEqual(meter(usage, .questions)?.statusLabel, "Running low", "812 of 1,000")
        XCTAssertEqual(meter(usage, .deepThinking)?.statusLabel, "Used up", "150 of 150")
        XCTAssertNil(meter(usage, .scannedPages)?.statusLabel, "120 of 6,000 is not worth a word")
        XCTAssertNil(meter(usage, .documents)?.statusLabel, "no limit, so nothing to run low on")

        // The edges: four-fifths is low, one short of the limit is still only low, and past the
        // limit — a server that let one through — is used up, never something odder.
        XCTAssertNil(AccountUsage.Meter(kind: .questions, used: 799, limit: 1000).statusLabel)
        XCTAssertEqual(
            AccountUsage.Meter(kind: .questions, used: 800, limit: 1000).statusLabel, "Running low")
        XCTAssertEqual(
            AccountUsage.Meter(kind: .questions, used: 999, limit: 1000).statusLabel, "Running low")
        XCTAssertEqual(
            AccountUsage.Meter(kind: .questions, used: 1001, limit: 1000).statusLabel, "Used up")
    }

    /// A field the route stops sending must not cost the screen.
    func testASparseResponseStillDecodes() throws {
        let usage = try decode(#"{"success":true,"metered":true}"#)
        XCTAssertEqual(usage.meters.first?.summary, "0 this month")
        XCTAssertNil(usage.renewsOn)
    }

    func testStorageReadsTheWayPeopleSayIt() {
        XCTAssertEqual(AccountUsage.bytes(850_000_000), "850 MB")
        XCTAssertEqual(AccountUsage.bytes(2_400_000_000), "2.4 GB")
        XCTAssertEqual(AccountUsage.bytes(10_000_000_000), "10 GB")
        XCTAssertEqual(AccountUsage.bytes(12_000), "12 KB")
    }
}

@MainActor
private func loadedModel(_ usage: AccountUsage?, error: Error? = nil) async -> AccountUsageViewModel {
    let model = AccountUsageViewModel(service: FakeUsage(usage: usage, error: error))
    await model.load()
    return model
}

private struct FakeUsage: UsageProviding {
    var usage: AccountUsage?
    var error: Error?
    func usage() async throws -> AccountUsage {
        if let error { throw error }
        return usage!
    }
}

final class AccountUsageViewModelTests: XCTestCase {

    func testTheRenewalLineSaysWhatIsTrue() async {
        let renew = WireDate.parse("2026-10-31T18:30:00.000Z")
        func line(_ usage: AccountUsage) async -> String? {
            await loadedModel(usage).renewalLine
        }
        let ended = await line(AccountUsage(
            planLabel: nil, isMetered: true, hasExpired: true, renewsOn: renew, meters: []))
        let unmetered = await line(AccountUsage(
            planLabel: nil, isMetered: false, hasExpired: false, renewsOn: renew, meters: []))
        let metered = await line(AccountUsage(
            planLabel: "Essential", isMetered: true, hasExpired: false, renewsOn: renew, meters: []))
        XCTAssertEqual(ended, "This account's plan has ended.")
        XCTAssertEqual(unmetered, "No usage limits apply to this account.")
        XCTAssertEqual(metered, "Monthly allowances renew on 1 November.")
    }

    /// A meter the plan does not include, with nothing used against it, is noise.
    func testOnlyMeaningfulMetersAreShown() async {
        let usage = AccountUsage(
            planLabel: nil, isMetered: true, hasExpired: false, renewsOn: nil,
            meters: [.init(kind: .questions, used: 3, limit: 30),
                     .init(kind: .scannedPages, used: 0, limit: 0)])
        let kinds = await loadedModel(usage).visibleMeters.map(\.kind)
        XCTAssertEqual(kinds, [.questions])
    }

    func testAFailedLoadIsAFailureNotAnEmptyScreen() async {
        let state = await loadedModel(nil, error: APIError.transport("The request timed out.")).state
        XCTAssertNotNil(state.failure)
    }
}
