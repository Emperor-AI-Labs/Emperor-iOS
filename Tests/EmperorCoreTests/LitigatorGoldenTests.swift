import XCTest
@testable import EmperorCore

/// Litigator's drafting taxonomy, held to the platform's own output character for character.
///
/// The fixtures were produced by importing `src/roles/litigatorDrafting.js`,
/// `src/roles/litigatorForms.js` and `src/tools/registry.js` under Node and calling `getTool` for
/// every id the workspace offers (`scripts/generate-litigator-fixtures.mjs`). The same discipline
/// as `ToolGoldenTests` and `RoleCardGoldenTests`, and for the same reason: each of these prompts
/// is what an advocate drafts a filing from. A dropped drafting instruction, a wrong code note
/// ("apply the CPC" on a bail application), or a forum's filing rules gone missing is a document
/// that is quietly wrong in a way nobody downstream would notice.
///
/// If one fails after a deliberate platform change, **regenerate from source rather than editing
/// the fixture to match**: the fixture is the contract and the Swift is the copy.
final class LitigatorGoldenTests: XCTestCase {

    // MARK: - Fixtures

    private struct Input: Decodable, Equatable {
        let key: String
        let label: String
        let type: String
        let required: Bool
        let placeholder: String?
        let options: [String]
        let big: Bool
    }

    private struct Tool: Decodable {
        let id: String
        let title: String
        let short: String
        let blurb: String
        let output: String
        let inputs: [Input]
        let empty: String
        let filled: String
    }

    private struct Tools: Decodable {
        let tools: [Tool]
    }

    private struct Taxonomy: Decodable {
        struct Matter: Decodable {
            let id: String
            let label: String
            let short: String?
        }
        struct Listing: Decodable {
            struct Section: Decodable {
                let key: String
                let items: [String]
            }
            let matter: String
            let proceeding: String?
            let sections: [Section]
        }
        struct Summary: Decodable {
            let id: String
            let summary: String
        }
        let matters: [Matter]
        let toolkit: [String]
        let proceedings: [String: [String]]
        let sectionsFor: [Listing]
        let summaries: [Summary]
    }

    private struct Cases: Decodable {
        struct Case: Decodable {
            let id: String
            let values: [String: String]
            let prompt: String
        }
        struct Lookup: Decodable {
            let id: String
            let resolves: Bool
            let title: String?
            let blurb: String?
        }
        let cases: [Case]
        let lookups: [Lookup]
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "litigator"),
            "missing fixture \(name).json — run scripts/generate-litigator-fixtures.mjs")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    /// Fixed, so nothing here can depend on the day it runs. No litigator prompt reads it.
    private let today: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 3
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata") ?? .gmt
        return calendar.date(from: components)!
    }()

    /// The rule that generated the filled fixtures — `ToolGoldenTests.filled`, unchanged.
    private func filled(_ tool: ToolSpec) -> ToolValues {
        var values: [String: String] = [:]
        for field in tool.inputs {
            if field.key == "lang" {
                values[field.key] = "Hindi"
            } else if let first = field.options.first {
                values[field.key] = first
            } else {
                values[field.key] = "test \(field.key)"
            }
        }
        return ToolValues(values)
    }

    private func describe(_ field: ToolField) -> Input {
        Input(
            key: field.key, label: field.label, type: field.type.rawValue,
            required: field.required, placeholder: field.placeholder, options: field.options,
            big: field.big)
    }

    /// Everything about one tool, against its fixture.
    private func check(_ golden: Tool, file: StaticString = #filePath, line: UInt = #line) {
        guard let tool = LitigatorDrafting.tool(golden.id) else {
            XCTFail("\(golden.id) resolves on the platform and not here", file: file, line: line)
            return
        }
        XCTAssertEqual(tool.id, golden.id, file: file, line: line)
        XCTAssertEqual(tool.title, golden.title, "\(golden.id) title", file: file, line: line)
        XCTAssertEqual(tool.short, golden.short, "\(golden.id) short", file: file, line: line)
        XCTAssertEqual(tool.blurb, golden.blurb, "\(golden.id) blurb", file: file, line: line)
        XCTAssertEqual(tool.output.rawValue, golden.output, "\(golden.id) output", file: file, line: line)
        XCTAssertEqual(tool.inputs.map(describe), golden.inputs, "\(golden.id) inputs", file: file, line: line)
        XCTAssertEqual(
            tool.prompt(.empty, today: today), golden.empty,
            "\(golden.id) drifted from the platform on an empty form", file: file, line: line)
        XCTAssertEqual(
            tool.prompt(filled(tool), today: today), golden.filled,
            "\(golden.id) drifted from the platform on a filled form", file: file, line: line)
    }

    // MARK: - Every id

    /// All 175 documents: title, short, blurb, every field, and the prompt both ways.
    func testEveryDocumentMatchesThePlatform() throws {
        let tools = try fixture("documents", as: Tools.self).tools
        XCTAssertEqual(tools.count, 175)
        for golden in tools { check(golden) }
    }

    /// All 47 heading forms, whose first field chooses the document.
    func testEveryHeadingFormMatchesThePlatform() throws {
        let tools = try fixture("sections", as: Tools.self).tools
        XCTAssertEqual(tools.count, 47)
        for golden in tools { check(golden) }
    }

    /// The other direction. Without this the two tests above would pass vacuously for anything
    /// the Swift taxonomy offered that the platform does not — which is exactly how a hand-added
    /// document would slip in.
    func testTheWorkspaceOffersExactlyTheIdsThePlatformDoes() throws {
        let documents = Set(try fixture("documents", as: Tools.self).tools.map(\.id))
        let sections = Set(try fixture("sections", as: Tools.self).tools.map(\.id))

        var offeredDocuments: Set<String> = []
        var offeredSections: Set<String> = []
        for matter in LITIGATOR_MATTERS {
            for section in LitigatorDrafting.sections(for: matter.id) {
                offeredSections.insert(
                    LitigatorDrafting.sectionID(matter: matter.id, section: section.key))
                for item in section.items {
                    offeredDocuments.insert(
                        LitigatorDrafting.documentID(matter: matter.id, item: item.id))
                }
            }
        }
        XCTAssertEqual(offeredDocuments, documents)
        XCTAssertEqual(offeredSections, sections)
    }

    // MARK: - The taxonomy

    func testTheMattersAreThePlatformsInItsOrder() throws {
        let golden = try fixture("taxonomy", as: Taxonomy.self)
        XCTAssertEqual(LITIGATOR_MATTERS.map(\.id), golden.matters.map(\.id))
        XCTAssertEqual(LITIGATOR_MATTERS.map(\.label), golden.matters.map(\.label))
        XCTAssertEqual(LITIGATOR_MATTERS.map(\.short), golden.matters.map(\.short))
        XCTAssertEqual(LITIGATOR_PROCEEDINGS, golden.proceedings)
    }

    /// The role's toolkit sits beside the workspace — under All tools — and comes from the same
    /// `roleConfig.js` entry. `PractitionerRole.toolIDs` is typed by hand, so it is held here too.
    func testTheToolkitIsThePlatforms() throws {
        let golden = try fixture("taxonomy", as: Taxonomy.self)
        XCTAssertEqual(PractitionerRole.litigator.toolIDs, golden.toolkit)
    }

    /// `sectionsFor` for every matter, and for Civil and Criminal under every proceeding — which
    /// sections show, in what order, holding which documents.
    func testSectionsForMatchesThePlatformForEveryMatterAndProceeding() throws {
        let listings = try fixture("taxonomy", as: Taxonomy.self).sectionsFor
        XCTAssertEqual(listings.count, 12 + 5 + 5)
        for listing in listings {
            let sections = LitigatorDrafting.sections(
                for: listing.matter, proceeding: listing.proceeding)
            let label = "\(listing.matter) / \(listing.proceeding ?? "any stage")"
            XCTAssertEqual(sections.map(\.key), listing.sections.map(\.key), label)
            XCTAssertEqual(
                sections.map { $0.items.map(\.id) }, listing.sections.map(\.items), label)
        }
    }

    /// The line on each heading card, quirks included — see `LitigatorDrafting.summary(of:)`.
    func testHeadingSummariesMatchTheWeb() throws {
        let summaries = try fixture("taxonomy", as: Taxonomy.self).summaries
        XCTAssertEqual(summaries.count, 47)
        for golden in summaries {
            guard let section = LitigatorDrafting.section(golden.id)?.section else {
                XCTFail("\(golden.id) names no section here")
                continue
            }
            XCTAssertEqual(LitigatorDrafting.summary(of: section), golden.summary, golden.id)
        }
    }

    // MARK: - The cases the empty and filled forms do not reach

    /// Every forum on a document and on a heading form, a forum typed in, trimming and the
    /// "(not provided)" fallback, a chosen document type, an empty template, and the code note
    /// for a criminal matter, a civil one and a practice area.
    func testTheEdgeCasesMatchThePlatform() throws {
        let cases = try fixture("cases", as: Cases.self).cases
        XCTAssertGreaterThan(cases.count, 20)
        for golden in cases {
            let tool = try XCTUnwrap(LitigatorDrafting.tool(golden.id), golden.id)
            XCTAssertEqual(
                tool.prompt(ToolValues(golden.values), today: today), golden.prompt,
                "\(golden.id) with \(golden.values)")
        }
    }

    /// Exactly as permissive as `getTool`: ids the workspace never builds still answer where the
    /// platform's would, and nothing answers that the platform's would not.
    func testLookupsAreExactlyAsPermissiveAsThePlatforms() throws {
        let lookups = try fixture("cases", as: Cases.self).lookups
        for golden in lookups {
            let tool = LitigatorDrafting.tool(golden.id)
            XCTAssertEqual(tool != nil, golden.resolves, golden.id)
            XCTAssertEqual(tool?.title, golden.title, golden.id)
            XCTAssertEqual(tool?.blurb, golden.blurb, golden.id)
        }
    }

    /// Every one of the eight forum formats is reached by some case, so a forum whose rules went
    /// missing from `FORUM_FORMATS` cannot pass on the strength of the other seven.
    func testEveryForumFormatIsPinned() throws {
        let cases = try fixture("cases", as: Cases.self).cases
        let forums = Set(cases.compactMap { $0.values["forum"] })
        for forum in FORUMS {
            XCTAssertTrue(forums.contains(forum), "\(forum) has no case")
            XCTAssertNotNil(FORUM_FORMATS[forum], "\(forum) has no formatting rules")
        }
    }
}
