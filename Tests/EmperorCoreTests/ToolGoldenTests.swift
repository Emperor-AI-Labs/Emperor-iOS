import XCTest
@testable import EmperorCore

/// Every tool, checked against the platform's own output character for character.
///
/// The fixtures were produced by evaluating the real registry module under Node, and carried
/// over from the Android client unchanged — the same bytes pin both ports. If one fails after a
/// deliberate platform change, **regenerate it from source rather than editing it to match**:
/// the fixture is the contract and the Swift is the copy.
///
/// Data-driven rather than one test per tool. There are twenty-nine of them, most with an
/// empty-form and a filled-form fixture, and a method per case would be sixty near-identical
/// tests nobody would keep in step. The loop also buys the property that matters most — **a tool
/// cannot be added without a fixture**, because `testEveryToolHasAFixture` fails if one is
/// missing.
final class ToolGoldenTests: XCTestCase {

    /// The date the fixtures were generated against. Only Caseflow reads it, but it has to be
    /// fixed or that tool's output changes daily.
    private let today: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
        return calendar.date(from: components)!
    }()

    private func fixture(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "txt", subdirectory: "tools")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The filled case for a tool: every field answered, using its first option where it has
    /// one. Kept in step with the fixtures by construction — the same rule generated both sides.
    private func filled(_ tool: ToolSpec) -> ToolValues {
        var values: [String: String] = [:]
        for field in tool.inputs {
            if field.key == "lang" {
                values[field.key] = "Hindi"          // exercises the non-English branch
            } else if let first = field.options.first {
                values[field.key] = first
            } else {
                values[field.key] = "test \(field.key)"
            }
        }
        return ToolValues(values)
    }

    func testEveryRegistryToolMatchesThePlatformOnAnEmptyForm() throws {
        // The common case: these tools are opened and run against an attached record.
        for tool in REGISTRY_TOOLS {
            let golden = try XCTUnwrap(
                fixture("\(tool.id)_empty"), "no empty fixture for \(tool.id)")
            XCTAssertEqual(tool.prompt(.empty, today: today), golden, tool.id)
        }
    }

    func testEveryRegistryToolMatchesThePlatformWithEveryFieldAnswered() throws {
        for tool in REGISTRY_TOOLS {
            let golden = try XCTUnwrap(
                fixture("\(tool.id)_filled"), "no filled fixture for \(tool.id)")
            XCTAssertEqual(tool.prompt(filled(tool), today: today), golden, tool.id)
        }
    }

    /// The guard that makes the loops above meaningful: a tool added without a fixture would
    /// otherwise be silently untested.
    func testEveryToolHasAFixture() {
        let variants = ["empty", "filled", "litigation", "contract", "scoped", "today", "full"]
        for tool in LEGAL_TOOLS {
            XCTAssertTrue(
                variants.contains { fixture("\(tool.id)_\($0)") != nil },
                "no fixture for \(tool.id)")
        }
    }

    /// Two tools sharing an id would make `legalTool(_:)` return whichever came first, leaving
    /// the other permanently unreachable from its own route.
    func testTheIDsAreUnique() {
        let ids = LEGAL_TOOLS.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testTheCatalogueIsTheSizeThePlatformHas() {
        XCTAssertEqual(ANALYSIS_TOOLS.count, 5)
        XCTAssertEqual(REGISTRY_TOOLS.count, 24)
        XCTAssertEqual(LEGAL_TOOLS.count, 29)
    }

    /// Ids come off a navigation route, so they are not trusted.
    func testAnUnknownIDResolvesToNothing() {
        XCTAssertNil(legalTool("../../etc/passwd"))
        XCTAssertNil(legalTool(nil))
        XCTAssertNotNil(legalTool("blind-spots"))
    }

    /// Every tool has to be openable and runnable — a blank title or an empty form is a row that
    /// leads nowhere.
    func testEveryToolIsPresentable() {
        for tool in LEGAL_TOOLS {
            XCTAssertFalse(tool.title.isEmpty, tool.id)
            XCTAssertFalse(tool.short.isEmpty, tool.id)
            XCTAssertFalse(tool.blurb.isEmpty, tool.id)
            XCTAssertFalse(tool.inputs.isEmpty, "\(tool.id) asks nothing")
            XCTAssertFalse(
                tool.prompt(.empty, today: today).isEmpty,
                "\(tool.id) builds an empty prompt")
        }
    }

    /// A select field with no options is a picker that cannot be used.
    func testEverySelectOffersOptions() {
        for tool in LEGAL_TOOLS {
            for field in tool.inputs where field.type == .select {
                XCTAssertFalse(
                    field.options.isEmpty, "\(tool.id).\(field.key) is a select with no options")
            }
        }
    }
}

// MARK: - The five analysis tools

/// The registry loop above cannot cover these: each takes its own input shape and two of them
/// branch on it, so the fixtures were generated from specific answers rather than a rule. These
/// are the five the web's own sidebar links, which makes them the most-used of the twenty-nine —
/// checking only that a fixture *exists* for them would be the wrong place to save effort.
extension ToolGoldenTests {

    private func values(_ pairs: [String: String]) -> ToolValues { ToolValues(pairs) }

    func testListOfDatesMatchesThePlatform() throws {
        XCTAssertEqual(
            ListOfDatesTool.prompt(values([
                "format": "Limitation Chronology",
                "forum": "NCLT",
                "party": "the Petitioner",
                "focus": "The 2019 invoices only.",
            ]), today: today),
            try XCTUnwrap(fixture("list-of-dates_full")))
        XCTAssertEqual(
            ListOfDatesTool.prompt(.empty, today: today),
            try XCTUnwrap(fixture("list-of-dates_empty")))
    }

    /// `v.forum || 'as the record indicates'` is an instruction, not an error path: several of
    /// these fallbacks tell the model to work the value out of the record itself.
    func testAnUnansweredFieldYieldsThePlatformsFallbackNeverABlank() {
        let prompt = ListOfDatesTool.prompt(.empty, today: today)
        XCTAssertTrue(prompt.contains("Forum: as the record indicates."))
        XCTAssertTrue(prompt.contains("[the filing party, as identified from the record]"))
    }

    func testTheOptionalFocusBlockIsAbsentUntilAnswered() {
        let without = ListOfDatesTool.prompt(.empty, today: today)
        let with = ListOfDatesTool.prompt(values(["focus": "The 2019 invoices only."]), today: today)
        XCTAssertFalse(without.contains("Counsel's instructions / focus:"))
        XCTAssertTrue(with.contains("Counsel's instructions / focus:"))
    }

    func testDevilsAdvocateMatchesThePlatformOnBothBranches() throws {
        XCTAssertEqual(
            BlindSpotsTool.prompt(values([
                "docKind": "Writ Petition",
                "side": "the Petitioner",
                "material": "Para 1. The impugned order.",
                "worry": "Limitation.",
            ]), today: today),
            try XCTUnwrap(fixture("blind-spots_litigation")))
        XCTAssertEqual(
            BlindSpotsTool.prompt(
                values(["docKind": "Contract / Agreement", "side": "the Buyer"]), today: today),
            try XCTUnwrap(fixture("blind-spots_contract")))
        XCTAssertEqual(
            BlindSpotsTool.prompt(.empty, today: today),
            try XCTUnwrap(fixture("blind-spots_empty")))
    }

    /// The platform's own reasoning: "agreement", "tender", "policy" and "licence" are litigation
    /// words at least as often as transactional ones, and routing a tender writ into the clause
    /// sweep costs the advocate limitation, Order VII Rule 11 and verification — which is the
    /// whole reason they opened the tool. A tie or an unknown value must fall to litigation,
    /// where those threshold checks live.
    func testTheTwoBranchesAreGenuinelyDifferentInstructions() {
        let litigation = BlindSpotsTool.prompt(values(["docKind": "Writ Petition"]), today: today)
        let contract = BlindSpotsTool.prompt(
            values(["docKind": "Contract / Agreement"]), today: today)

        XCTAssertTrue(litigation.contains("THRESHOLD SWEEP"))
        XCTAssertTrue(litigation.contains("Order VII Rule 11"))
        XCTAssertFalse(litigation.contains("CLAUSE SWEEP"))

        XCTAssertTrue(contract.contains("CLAUSE SWEEP"))
        XCTAssertFalse(contract.contains("WHAT TO FIX BEFORE FILING"))

        // An unrecognised or empty type must not land in the clause sweep.
        for ambiguous in ["", "Something the dropdown does not offer",
                          "Writ Petition challenging cancellation of tender",
                          "Suit for specific performance of an agreement to sell"] {
            XCTAssertTrue(
                BlindSpotsTool.prompt(values(["docKind": ambiguous]), today: today)
                    .contains("THRESHOLD SWEEP"),
                "\(ambiguous.isEmpty ? "an empty kind" : ambiguous) fell to the clause sweep")
        }
    }

    func testHighlighterMatchesThePlatform() throws {
        XCTAssertEqual(
            HighlighterTool.prompt(.empty, today: today),
            try XCTUnwrap(fixture("highlighter_empty")))
        XCTAssertEqual(
            HighlighterTool.prompt(values([
                "extract": "Caps, Indemnity Limits & Carve-outs",
                "party": "the Buyer",
                "hunt": "the liability cap",
                "source": "Clause 9.2 caps liability at INR 5,00,00,000.",
            ]), today: today),
            try XCTUnwrap(fixture("highlighter_scoped")))

        // "Something else" falls through the category map, and the single table is then headed
        // with the user's own words rather than a mapped heading that would not match what was
        // actually asked for.
        XCTAssertEqual(
            HighlighterTool.prompt(values(["extract": "Something I typed myself"]), today: today),
            try XCTUnwrap(fixture("highlighter_custom")))
    }

    func testDocIndexMatchesThePlatform() throws {
        XCTAssertEqual(
            DocIndexTool.prompt(.empty, today: today),
            try XCTUnwrap(fixture("doc-index_empty")))
        XCTAssertEqual(
            DocIndexTool.prompt(values([
                "deliverable": "Contradictions & discrepancies",
                "recordType": "Title deeds & property chain",
                "matter": "Sterling v NHAI",
                "focus": "The principal amount.",
                "source": "D1 text",
            ]), today: today),
            try XCTUnwrap(fixture("doc-index_full")))
    }

    /// The only tool that reads the clock, which is why `today` is a parameter throughout: a
    /// prompt builder that called `Date()` could not be pinned to a fixture at all.
    func testCaseflowMatchesThePlatformAgainstAFixedToday() throws {
        XCTAssertEqual(
            CaseflowTool.prompt(values([
                "deliverable": "Client Status Note",
                "party": "Appellant",
                "asOn": "08.12.2026",
                "context": "Order sheet attached.",
            ]), today: today),
            try XCTUnwrap(fixture("caseflow_ason")))
        XCTAssertEqual(
            CaseflowTool.prompt(.empty, today: today),
            try XCTUnwrap(fixture("caseflow_today")))
    }
}
