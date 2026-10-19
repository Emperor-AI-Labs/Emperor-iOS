import XCTest
@testable import EmperorCore

/// A `Practice` on a fresh store, optionally already in a role. A free function: the test class
/// is not `@MainActor` (Linux XCTest cannot invoke one), and `Practice` is.
@MainActor
private func devilPractice(
    _ role: PractitionerRole? = nil, store: InMemoryPreferenceStore = InMemoryPreferenceStore()
) -> Practice {
    role?.save(to: store)
    return Practice(store: store)
}

/// The web's eighth role, Devil's Advocate: its deck, its two sides, and the guardrail every tool
/// prompt carries while it is the role.
///
/// The prompts and the guardrail are pinned to fixtures generated from the platform's own
/// JavaScript (`scripts/generate-role-card-fixtures.mjs`); the card prompts themselves are held by
/// `RoleCardGoldenTests` with every other deck's.
final class DevilsAdvocateRoleTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "cards"),
            "no fixture \(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The role

    func testTheRoleIsTheWebs() {
        let role = PractitionerRole.devilsAdvocate
        XCTAssertEqual(role.webID, "devil")
        XCTAssertEqual(PractitionerRole(webID: "devil"), .devilsAdvocate)
        XCTAssertEqual(role.label, "Devil's Advocate")
        XCTAssertEqual(role.tagline, "Adversarial stress-testing")
        XCTAssertEqual(role.tileHue, .brick)
        XCTAssertEqual(TileHue.brick.webHex, 0xB05A4E)
        // `tools` in roleConfig.js, in its order, then COMMON_TOOLS.
        XCTAssertEqual(role.toolIDs, [
            "brief-workup", "draft-review", "arguments", "blind-spots", "research", "doc-index",
            "custom-document",
        ])
        XCTAssertFalse(role.usesDraftingTaxonomy)
        XCTAssertEqual(AskHome.suggestions(for: role).count, 4)
    }

    /// The role sends its own name, as the web's `aiRole` does — not `Litigator`.
    func testTheRoleSendsItsOwnNameOnTheWire() {
        XCTAssertEqual(PractitionerRole.devilsAdvocate.wireRole.wireValue, "Devil's Advocate")
        XCTAssertEqual(ChatRole(rawValue: "Devil's Advocate"), .devilsAdvocate)
    }

    // MARK: - The deck

    func testTheDeckIsElevenCardsUnderOnePrefix() {
        let cards = PractitionerRole.devilsAdvocate.cards
        XCTAssertEqual(cards.count, 11)
        for card in cards {
            XCTAssertTrue(card.toolID.hasPrefix("dadv-"), card.toolID)
            XCTAssertNotNil(roleTool(card.toolID), card.toolID)
            XCTAssertTrue(
                PractitionerRole.devilsAdvocate.cardSections.contains(card.section ?? ""),
                "\(card.id) is in no section")
        }
        XCTAssertEqual(PractitionerRole.devilsAdvocate.cardSections.count, 11)
    }

    /// `selectDevilCards`: the mode's cards, shared ones in both, in the platform's order.
    func testEachSideShowsItsOwnHalfOfTheDeck() {
        let role = PractitionerRole.devilsAdvocate
        XCTAssertEqual(role.cardFilters.map(\.id), ["opposition", "our-side"])
        XCTAssertEqual(role.cardFilters.map(\.label), ["The Other Side", "Our Own Case"])
        XCTAssertEqual(role.cards(matching: "opposition").map(\.id), [
            "opponents-best-case", "anticipated-attack", "cross-exam", "authority-attack",
            "bench-scrutiny", "evidence-gaps", "limitation-radar", "adversarial-research",
        ])
        XCTAssertEqual(role.cards(matching: "our-side").map(\.id), [
            "authority-attack", "weakness-audit", "red-team-draft", "evidence-gaps",
            "limitation-radar", "exposure-floor", "adversarial-research",
        ])
    }

    /// The Limitation card is a capability on the web, routed to the Limitation Radar's page; it
    /// is the only card here that is not a prompt.
    func testTheLimitationCardOpensTheRadar() {
        let opening = ROLE_CARDS.filter { $0.opensScreen != nil }
        XCTAssertEqual(opening.map(\.toolID), ["dadv-limitation-radar"])
        XCTAssertEqual(opening.first?.opensScreen, .limitationRadar)
    }

    /// The card form names the side under attack, in the platform's words, and the prompt falls
    /// back to the other side when it is left blank.
    func testTheCardFormAsksWhoseCaseIsUnderAttack() throws {
        let tool = try XCTUnwrap(roleTool("dadv-weakness-audit"))
        let position = try XCTUnwrap(tool.inputs.first { $0.key == "position" })
        XCTAssertEqual(position.options, ["The Other Side", "Our Own Case"])
        XCTAssertTrue(tool.prompt(.empty).contains("Attacking: The Other Side."))
        XCTAssertTrue(
            tool.prompt(ToolValues(["position": "Our Own Case"])).contains("Attacking: Our Own Case."))
        XCTAssertTrue(tool.prompt(.empty).contains(DevilsAdvocateMode.adversarialScope))
    }

    // MARK: - The guardrail

    func testTheGuardrailIsThePlatformsForEachSide() throws {
        XCTAssertEqual(DevilsAdvocateMode.opposition.guardrail, try fixture("guardrail_devil_opposition"))
        XCTAssertEqual(DevilsAdvocateMode.ourSide.guardrail, try fixture("guardrail_devil_our-side"))
        // Before a side is ever chosen the web attacks the other side.
        XCTAssertEqual(DevilsAdvocateMode.default.guardrail, try fixture("guardrail_devil_unset"))
    }

    func testEveryToolPromptCarriesTheGuardrailOnlyInThisRole() async throws {
        let expected = try fixture("guardrail_devil_unset")
        await MainActor.run {
            XCTAssertEqual(devilPractice(.devilsAdvocate).toolPromptGuardrail, expected)
            for role in PractitionerRole.allCases where role != .devilsAdvocate {
                XCTAssertEqual(devilPractice(role).toolPromptGuardrail, "", role.label)
            }
        }
    }

    // MARK: - Remembering the side

    func testTheSideChosenOnTheDeckIsRememberedAndNamedInTheGuardrail() async throws {
        let ourSide = try fixture("guardrail_devil_our-side")
        await MainActor.run {
            let store = InMemoryPreferenceStore()
            let practice = devilPractice(.devilsAdvocate, store: store)
            XCTAssertEqual(practice.initialCardFilter, "opposition")

            practice.chooseCardFilter("our-side")
            XCTAssertEqual(practice.devilsAdvocateMode, .ourSide)
            XCTAssertEqual(practice.toolPromptGuardrail, ourSide)

            // A fresh launch reopens on the same side.
            let reopened = Practice(store: store)
            XCTAssertEqual(reopened.devilsAdvocateMode, .ourSide)
            XCTAssertEqual(reopened.initialCardFilter, "our-side")

            // Nonsense is ignored rather than stored.
            practice.chooseCardFilter("both-sides")
            XCTAssertEqual(practice.devilsAdvocateMode, .ourSide)
        }
    }

    /// Every other role's filter only filters its grid: nothing is remembered, and its deck
    /// opens on its first filter as before.
    func testOtherRolesFiltersAreNotRemembered() async {
        await MainActor.run {
            let store = InMemoryPreferenceStore()
            let practice = devilPractice(.legalAid, store: store)
            XCTAssertEqual(practice.initialCardFilter, "beneficiary")
            practice.chooseCardFilter("our-side")
            XCTAssertEqual(practice.devilsAdvocateMode, .opposition)
            XCTAssertNil(store.string(for: DevilsAdvocateMode.storageKey))
            XCTAssertNil(devilPractice(.seniorCounsel).initialCardFilter)
        }
    }

    func testAnUnrecognisedStoredSideFallsBackToTheOtherSide() {
        let store = InMemoryPreferenceStore()
        store.setString("neither", for: DevilsAdvocateMode.storageKey)
        XCTAssertEqual(DevilsAdvocateMode.stored(in: store), .opposition)
    }

    // MARK: - The account

    /// Chosen on the web, the role now arrives here instead of being left alone.
    func testTheAccountsDevilsAdvocateIsAdopted() async {
        await MainActor.run {
            let practice = devilPractice(.paralegal)
            XCTAssertNil(practice.reconcile(withAccountRole: "devil"))
            XCTAssertEqual(practice.role, .devilsAdvocate)
        }
    }
}
