import XCTest
@testable import EmperorCore

/// Numbered citations, checked against the platform's own `citations.js`.
///
/// `Resources/citations.json` was produced by running `formatCitationsInMarkdown` under Node
/// (`scripts/generate-citation-fixtures.mjs`) over every case below. If one fails after a
/// deliberate platform change, **regenerate the fixture from source rather than editing it**: the
/// fixture is the contract and the Swift is the copy.
///
/// What is compared is what a reader sees — which reference boxes are drawn, with what number and
/// text, and which numbers in the body become badges — not the HTML the web wraps them in. The
/// comparison is on every marker the web would badge, listed or not: whether a marker *resolves*
/// is a separate, deliberately stricter rule, tested on its own in `CitationTests`.
final class CitationGoldenTests: XCTestCase {

    struct Fixture: Decodable {
        let name: String
        let input: String
        let deviation: String?
        let web: Web
    }

    struct Web: Decodable {
        let output: String
        let references: [Entry]
        let markers: [Int]
    }

    struct Entry: Decodable, Equatable, CustomStringConvertible {
        let number: Int
        let text: String
        var description: String { "[\(number)] \(text)" }
    }

    static func fixtures() throws -> [Fixture] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "citations", withExtension: "json"),
            "Resources/citations.json is missing — run scripts/generate-citation-fixtures.mjs")
        struct File: Decodable { let cases: [Fixture] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    static func fixture(named name: String) throws -> Fixture {
        try XCTUnwrap(fixtures().first { $0.name == name }, "no fixture named \(name)")
    }

    /// What this app finds in `input`, in the fixture's shape.
    ///
    /// The body is walked block by block, exactly as `MarkdownContentView` draws it — a code
    /// block is drawn verbatim and so never read, a table is read cell by cell — so this is the
    /// renderer's view of the answer and not a second reading of the text.
    static func derived(_ input: String) -> (references: [Entry], markers: [Int]) {
        let cited = CitedMarkdown.parse(input)
        let references = cited.index.references.map {
            Entry(number: $0.number, text: normalised($0.text))
        }
        var markers: [Int] = []
        for block in cited.blocks {
            switch block {
            case .block(let block):
                if case .code = block { continue }
                markers += numbers(in: block.text)
            case .table(let table):
                for cell in table.headers + table.normalisedRows.flatMap({ $0 }) {
                    markers += numbers(in: cell)
                }
            case .references:
                continue
            }
        }
        return (references, markers)
    }

    /// A reference's text with each marker written the way the fixture records a badge.
    static func normalised(_ text: String) -> String {
        CitationMarkup.rewritingMarkers(in: text) { marker in
            marker.numbers.map { "[\($0)]" }.joined(separator: " ")
        }
    }

    private static func numbers(in text: String) -> [Int] {
        CitationMarkers.find(in: text).flatMap(\.numbers)
    }

    // MARK: -

    /// The corpus has to be broad enough to mean something.
    func testTheFixtureCoversTheRules() throws {
        let fixtures = try Self.fixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 60)
        XCTAssertGreaterThanOrEqual(fixtures.filter { $0.deviation == nil }.count, 50)
        XCTAssertEqual(
            Set(fixtures.map(\.name)).count, fixtures.count, "two fixtures share a name")
    }

    /// Everywhere the app means to behave as the web does, it finds the same references with the
    /// same text, and the same markers in the same order.
    func testTheAppFindsWhatTheWebFinds() throws {
        for fixture in try Self.fixtures() where fixture.deviation == nil {
            let app = Self.derived(fixture.input)
            XCTAssertEqual(
                app.references, fixture.web.references, "references: \(fixture.name)")
            XCTAssertEqual(app.markers, fixture.web.markers, "markers: \(fixture.name)")
        }
    }

    /// Every deliberate departure still departs. If one of these starts to pass as agreement,
    /// the web has changed its rule and the departure — and its comment — should be revisited.
    func testEveryDeliberateDepartureFromTheWebStillDeparts() throws {
        let deviations = try Self.fixtures().filter { $0.deviation != nil }
        XCTAssertFalse(deviations.isEmpty)
        for fixture in deviations {
            let app = Self.derived(fixture.input)
            XCTAssertTrue(
                app.references != fixture.web.references || app.markers != fixture.web.markers,
                "\(fixture.name) (\(fixture.deviation ?? "")) now matches the web")
        }
    }
}
