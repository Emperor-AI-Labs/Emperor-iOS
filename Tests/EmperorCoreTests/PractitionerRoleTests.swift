import XCTest
@testable import EmperorCore

/// The seven roles the platform offers, and the three identities the model knows.
final class PractitionerRoleTests: XCTestCase {

    /// **The one that would rot silently.** A tool id here is a string, and nothing else checks
    /// it: a typo, or a tool renamed in the registry, would quietly shorten somebody's toolkit
    /// and only be noticed by the person who went looking for the tool that had gone.
    func testEveryRolesToolsExistInTheRegistry() {
        for role in PractitionerRole.allCases {
            let missing = role.toolIDs.filter { id in !LEGAL_TOOLS.contains { $0.id == id } }
            XCTAssertTrue(
                missing.isEmpty,
                "\(role.label) names tools that are not in the registry: \(missing)")
            XCTAssertEqual(
                role.tools.count, role.toolIDs.count,
                "\(role.label) resolved fewer tools than it names")
        }
    }

    /// Seven roles, three wire values. Four of them send `Litigator`, which is the contract and
    /// not an approximation — the system prompt knows three identities, and the other four
    /// differ in what the app offers, not in what the model is told it is.
    func testSevenRolesNarrowToThreeWireValues() {
        XCTAssertEqual(PractitionerRole.allCases.count, 7)

        XCTAssertEqual(PractitionerRole.corporateCounsel.wireRole, .corporateCounsel)
        XCTAssertEqual(PractitionerRole.adjudicator.wireRole, .judicialOfficer)
        for role in [
            PractitionerRole.litigator, .seniorCounsel, .student, .paralegal, .legalAid,
        ] {
            XCTAssertEqual(role.wireRole, .litigator, "\(role.label) is a litigator on the wire")
        }

        XCTAssertEqual(Set(PractitionerRole.allCases.map(\.wireRole)).count, 3)
    }

    /// A blank drafting surface belongs to everybody — `COMMON_TOOLS` on the web.
    func testEveryRoleCanReachTheBlankDocument() {
        for role in PractitionerRole.allCases {
            XCTAssertTrue(
                role.toolIDs.contains("custom-document"),
                "\(role.label) cannot reach a blank document")
        }
    }

    /// Order is the platform's, not alphabetical: the first tool is what the role opens the app
    /// to do, and sorting this list would put `arguments` before `research` for a litigator.
    func testAToolkitOpensWithTheRolesOwnFirstTool() {
        XCTAssertEqual(PractitionerRole.litigator.toolIDs.first, "research")
        XCTAssertEqual(PractitionerRole.corporateCounsel.toolIDs.first, "contract-analysis")
        XCTAssertEqual(PractitionerRole.adjudicator.toolIDs.first, "brief-workup")
        XCTAssertEqual(PractitionerRole.student.toolIDs.first, "law-timeline")
        XCTAssertEqual(PractitionerRole.legalAid.toolIDs.first, "know-your-rights")
    }

    /// A role scopes the toolkit; it does not take tools away. Every role names fewer than the
    /// full registry, and between them they do not cover it — which is why the full list stays
    /// reachable in the UI.
    func testARoleNarrowsTheRegistryRatherThanReplacingIt() {
        for role in PractitionerRole.allCases {
            XCTAssertLessThan(role.toolIDs.count, LEGAL_TOOLS.count)
            XCTAssertFalse(role.toolIDs.isEmpty)
        }

        let reachable = Set(PractitionerRole.allCases.flatMap(\.toolIDs))
        XCTAssertLessThan(
            reachable.count, LEGAL_TOOLS.count,
            "no role names every tool, so the full list has to stay reachable")
    }

    // MARK: - Storage

    func testAChosenRoleIsRemembered() {
        let store = InMemoryPreferenceStore()
        XCTAssertEqual(PractitionerRole.stored(in: store), .litigator, "the default")

        PractitionerRole.paralegal.save(to: store)
        XCTAssertEqual(PractitionerRole.stored(in: store), .paralegal)
    }

    /// A value this build does not recognise falls back rather than failing — what a downgrade,
    /// or a role retired in a later build, leaves behind.
    func testAnUnrecognisedStoredRoleFallsBackToTheDefault() {
        let store = InMemoryPreferenceStore()
        store.setString("barrister-of-the-inner-temple", for: PractitionerRole.storageKey)

        XCTAssertEqual(PractitionerRole.stored(in: store), .default)
    }
}
