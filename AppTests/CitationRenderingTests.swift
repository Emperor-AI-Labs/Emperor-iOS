import XCTest
import SwiftUI
@testable import Emperor

/// Citation badges, through Apple's own markdown parser.
///
/// The core rewrites `[1]` as `[1](emperor-citation:1#1)` and trusts `AttributedString(markdown:)`
/// to turn that into a link run the renderer can restyle. Linux has no markdown parser, so the
/// core's tests can only check the rewrite; whether the parser really does what the badge relies
/// on — a link per marker, emphasis kept around it, nothing left over as literal syntax — can
/// only be asked here.
final class CitationRenderingTests: XCTestCase {

    private let citations = CitationIndex(references: [
        CitationReference(number: 1, text: "Sexual Harassment of Women at Workplace Act, 2013", ordinal: 0),
        CitationReference(number: 2, text: "*Vishaka* v. State of Rajasthan, (1997) 6 SCC 241", ordinal: 1),
    ])

    private func inline(_ text: String, holding: Bool = false) -> CitedInline {
        CitedInline(
            text, citations: citations, holdingTrailingMarker: holding,
            badgeText: .blue, badgeFill: .gray)
    }

    private func characters(_ inline: CitedInline) -> String {
        String(inline.attributed.characters)
    }

    /// The numbers of the badges drawn, in order.
    private func badges(_ inline: CitedInline) -> [Int] {
        inline.attributed.runs.compactMap { run in run.link.flatMap(CitationLink.number(from:)) }
    }

    func testAMarkerBecomesOneBadgeAndTheSentenceIsIntact() {
        let drawn = inline("Under the Act [1], the employer must act.")
        XCTAssertEqual(badges(drawn), [1])
        XCTAssertEqual(characters(drawn), "Under the Act \u{202F}1\u{202F}, the employer must act.")
        XCTAssertEqual(drawn.references.map(\.number), [1])
        XCTAssertEqual(drawn.spoken, "Under the Act (citation 1), the employer must act.")
    }

    func testEmphasisAroundABadgeIsKept() {
        let drawn = inline("**Under the Act [1], the employer**")
        XCTAssertEqual(badges(drawn), [1])
        let emphasised = drawn.attributed.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertEqual(
            emphasised.map { String(drawn.attributed[$0.range].characters) },
            ["Under the Act ", ", the employer"])
    }

    func testARealLinkStaysTheLinkItWas() {
        let drawn = inline("See [the judgment](https://indiankanoon.org/doc/1) and [2].")
        XCTAssertEqual(badges(drawn), [2])
        XCTAssertTrue(drawn.attributed.runs.contains {
            $0.link == URL(string: "https://indiankanoon.org/doc/1")
        })
        XCTAssertEqual(characters(drawn), "See the judgment and \u{202F}2\u{202F}.")
    }

    func testAListMarkerIsABadgePerNumber() {
        XCTAssertEqual(badges(inline("Held [1, 2].")), [1, 2])
        XCTAssertEqual(badges(inline("Held [1][1].")), [1, 1], "two badges, not one merged run")
    }

    func testAnExclamationMarkStaysOneAndMakesNoImage() {
        let drawn = inline("Wow![1]")
        XCTAssertEqual(characters(drawn), "Wow!\u{202F}1\u{202F}")
        XCTAssertEqual(badges(drawn), [1])
    }

    func testWhatIsNotACitationIsDrawnAsBefore() {
        for text in ["Orphan [7].", "Code `[1]` here.", "Mixed [1, 7].", "Plain prose."] {
            let drawn = inline(text)
            XCTAssertEqual(badges(drawn), [], text)
            XCTAssertTrue(drawn.references.isEmpty, text)
            XCTAssertEqual(
                drawn.attributed, CitedInline.parse(text), "\(text) must render exactly as before")
        }
    }

    func testAStreamingTailWaitsForItsNextCharacter() {
        XCTAssertEqual(badges(inline("Under the Act [1]", holding: true)), [])
        XCTAssertEqual(badges(inline("Under the Act [1].", holding: true)), [1])
    }

    /// A whole answer, every block through the real parser: every marker the core resolved is a
    /// badge on screen, and no citation link syntax is ever left showing as text.
    func testEveryMarkerInARealisticAnswerIsDrawnAsABadge() {
        let answer = """
            Under the POSH Act [1], every employer must constitute a Committee, and **Section 26** \
            [1] attaches a penalty. *Vishaka* [2] came first [1, 2].

            1. Constitute the Committee [1].
            2. Ref. 2 explains why.

            | Step | Authority |
            | --- | --- |
            | Constitution | Section 4 [1] |

            ## References
            [1] Sexual Harassment of Women at Workplace Act, 2013 — Sections 4, 26.
            [2] *Vishaka* v. State of Rajasthan, (1997) 6 SCC 241 — see also [1].
            """
        let cited = CitedMarkdown.parse(answer)
        var drawnBadges: [Int] = []
        for block in cited.blocks {
            let texts: [String]
            switch block {
            case .block(let markdown): texts = [markdown.text]
            case .table(let table): texts = table.headers + table.normalisedRows.flatMap { $0 }
            case .references(let references): texts = references.map(\.text)
            }
            for text in texts {
                let drawn = CitedInline(
                    text, citations: cited.index, holdingTrailingMarker: false,
                    badgeText: .blue, badgeFill: .gray)
                XCTAssertFalse(characters(drawn).contains(CitationLink.scheme), text)
                drawnBadges += badges(drawn)
            }
        }
        XCTAssertEqual(drawnBadges, [1, 1, 2, 1, 2, 1, 2, 1, 1])
    }
}
