import XCTest
@testable import EmperorCore

/// Every role card, checked against the platform's own output character for character.
///
/// The fixtures were produced by evaluating `src/roles/*Cards.js` and `src/tools/registry.js`
/// under Node — the same discipline `ToolGoldenTests` uses for the twenty-nine registry tools,
/// and for the same reason. These prompts carry guardrails, not decoration: a paralegal's output
/// is labelled a draft for advocate review and refuses independent advice, a student's teaches
/// rather than ghostwrites, legal aid anonymises, and an arbitral scaffold leaves the findings to
/// the arbitrator. A retyped template with one sentence dropped is a card that quietly stops
/// doing the thing it exists to do.
///
/// If one fails after a deliberate platform change, **regenerate it from source rather than
/// editing it to match**: the fixture is the contract and the Swift is the copy.
final class RoleCardGoldenTests: XCTestCase {

    /// Fixed, so nothing here can depend on the day it runs. No card reads it, but `ToolSpec`
    /// takes it and a test that passes a live clock is one that can fail overnight.
    private let today: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
        return calendar.date(from: components)!
    }()

    private func fixture(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "txt", subdirectory: "cards")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Every field answered, using its first option where it has one — the same rule that
    /// generated the fixtures, so both sides of the port are built alike.
    private func filled(_ tool: ToolSpec) -> ToolValues {
        var values: [String: String] = [:]
        for field in tool.inputs {
            if let first = field.options.first {
                values[field.key] = first
            } else {
                values[field.key] = "test \(field.key)"
            }
        }
        return ToolValues(values)
    }

    func testEveryCardMatchesThePlatformOnAnEmptyForm() throws {
        for card in ROLE_CARDS {
            let golden = try XCTUnwrap(
                fixture("\(card.toolID)_empty"), "no empty fixture for \(card.toolID)")
            XCTAssertEqual(
                card.toolSpec.prompt(.empty, today: today), golden,
                "\(card.toolID) drifted from the platform on an empty form")
        }
    }

    func testEveryCardMatchesThePlatformOnAFilledForm() throws {
        for card in ROLE_CARDS {
            let tool = card.toolSpec
            let golden = try XCTUnwrap(
                fixture("\(card.toolID)_filled"), "no filled fixture for \(card.toolID)")
            XCTAssertEqual(
                tool.prompt(filled(tool), today: today), golden,
                "\(card.toolID) drifted from the platform on a filled form")
        }
    }

    /// A card cannot be added without a fixture. Without this the two tests above would pass
    /// vacuously for anything new — which is exactly how a hand-written card would slip in.
    func testEveryCardHasBothFixtures() {
        for card in ROLE_CARDS {
            XCTAssertNotNil(fixture("\(card.toolID)_empty"), "\(card.toolID) has no empty fixture")
            XCTAssertNotNil(fixture("\(card.toolID)_filled"), "\(card.toolID) has no filled fixture")
        }
    }

    func testTheDeckIsTheSizeThePlatformShips() {
        XCTAssertEqual(ROLE_CARDS.count, 94)
        let byRole = Dictionary(grouping: ROLE_CARDS, by: \.role).mapValues(\.count)
        XCTAssertEqual(byRole[.seniorCounsel], 9)
        XCTAssertEqual(byRole[.adjudicator], 11)
        XCTAssertEqual(byRole[.corporateCounsel], 46)
        XCTAssertEqual(byRole[.student], 8)
        XCTAssertEqual(byRole[.paralegal], 8)
        XCTAssertEqual(byRole[.legalAid], 12)
    }

    /// Ids are the platform's, and the prefixes are not interchangeable — `getTool` dispatches on
    /// them, and Senior Counsel's is six characters where every other role's is five.
    func testCardIdsCarryTheirRolesPrefix() {
        for card in ROLE_CARDS {
            XCTAssertTrue(
                card.toolID.hasPrefix(RoleCard.prefix(for: card.role)),
                "\(card.toolID) does not carry \(card.role.label)'s prefix")
        }
        XCTAssertEqual(roleCard("adoc-award-drafting")?.title, "Award Drafting")
        XCTAssertNil(roleCard("award-drafting"), "the bare card id is not a tool id")
    }

    // MARK: - The gate

    /// **A compliance boundary, not a preference.** The platform's own comment on
    /// `adjudicatorCards.js` says a Judge is strictly assistive — no drafting of judgments,
    /// orders, findings, sentencing, bail, interim orders or outcome prediction — while an
    /// Arbitrator gets the full assistive drafting set. It cuts both ways, and getting it wrong
    /// in either direction offers somebody work they must not be offered.
    func testTheAdjudicatorGateHoldsInBothDirections() {
        let judge = PractitionerRole.adjudicator.cards(matching: "judge").map(\.id)
        let arbitrator = PractitionerRole.adjudicator.cards(matching: "arbitrator").map(\.id)

        XCTAssertEqual(judge, [
            "case-summary", "submissions-digest", "evidence-analysis", "legal-research",
            "translation", "hearing-mgmt", "precedent-pull", "judgment-formatting",
        ])
        XCTAssertEqual(arbitrator, [
            "case-summary", "submissions-digest", "evidence-analysis", "legal-research",
            "translation", "hearing-mgmt", "award-drafting", "procedural-orders",
            "costs-interest",
        ])

        for drafting in ["award-drafting", "procedural-orders", "costs-interest"] {
            XCTAssertFalse(judge.contains(drafting), "a judge must not be offered \(drafting)")
        }
        for judicial in ["precedent-pull", "judgment-formatting"] {
            XCTAssertFalse(
                arbitrator.contains(judicial), "an arbitrator must not be offered \(judicial)")
        }
    }

    /// Every other grid's filter, pinned against the platform's own selection.
    func testEveryFilteredGridMatchesThePlatform() {
        XCTAssertEqual(PractitionerRole.legalAid.cards(matching: "beneficiary").count, 8)
        XCTAssertEqual(PractitionerRole.legalAid.cards(matching: "advocacy").count, 6)
        XCTAssertEqual(PractitionerRole.student.cards(matching: "law-student").count, 7)
        XCTAssertEqual(PractitionerRole.student.cards(matching: "moot").count, 5)
        XCTAssertEqual(PractitionerRole.student.cards(matching: "research").count, 4)
        XCTAssertEqual(PractitionerRole.paralegal.cards(matching: "general").count, 7)
        XCTAssertEqual(PractitionerRole.paralegal.cards(matching: "litigation").count, 7)
        XCTAssertEqual(PractitionerRole.paralegal.cards(matching: "corporate").count, 4)

        // `GEN` is a real tag covering eighteen of the forty-six, not a synonym for "all".
        XCTAssertEqual(PractitionerRole.corporateCounsel.cards(matching: "GEN").count, 18)
        XCTAssertEqual(PractitionerRole.corporateCounsel.cards(matching: "CORP").count, 21)
        XCTAssertEqual(PractitionerRole.corporateCounsel.cards.count, 46)
    }

    /// Senior Counsel's grid is flat — no filter, every card always shown.
    func testAFlatGridShowsEverything() {
        XCTAssertTrue(PractitionerRole.seniorCounsel.cardFilters.isEmpty)
        XCTAssertEqual(PractitionerRole.seniorCounsel.cards(matching: "anything").count, 9)
    }
}
