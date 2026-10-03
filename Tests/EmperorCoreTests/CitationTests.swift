import XCTest
@testable import EmperorCore

/// Numbered citations: the rules `CitationGoldenTests` cannot pin against the web, because they
/// are where this app is deliberately stricter — and the ones that decide what the screen does.
final class CitationTests: XCTestCase {

    private func references(_ markdown: String) -> [String] {
        CitedMarkdown.parse(markdown).index.references.map { "[\($0.number)] \($0.text)" }
    }

    private func markers(_ text: String) -> [[Int]] {
        CitationMarkers.find(in: text).map(\.numbers)
    }

    private func index(_ numbers: Int...) -> CitationIndex {
        CitationIndex(references: numbers.enumerated().map {
            CitationReference(number: $1, text: "Reference \($1)", ordinal: $0)
        })
    }

    private func link(_ number: Int, _ occurrence: Int) -> String {
        "[\(number)](emperor-citation:\(number)#\(occurrence))"
    }

    private func realisticAnswer() throws -> String {
        try CitationGoldenTests.fixture(named: "a realistic answer").input
    }

    // MARK: - The References section

    /// The system prompt's own example, end to end: three entries with their whole text, lifted
    /// out of the prose into one list at the end, after the heading that introduced them.
    func testARealisticAnswerListsItsReferencesAtTheEnd() throws {
        let cited = CitedMarkdown.parse(try realisticAnswer())

        XCTAssertEqual(cited.index.references.map(\.number), [1, 2, 3])
        XCTAssertEqual(
            cited.index.reference(for: 2)?.text,
            "Santosh Kumar vs. Secretary, Ministry of Defence, (2018) WP(C) 6919/2017 — Scope of statutory remedy.")
        guard case .references(let listed)? = cited.blocks.last else {
            return XCTFail("the References should close the answer, got \(String(describing: cited.blocks.last))")
        }
        XCTAssertEqual(listed.map(\.number), [1, 2, 3])
        XCTAssertEqual(
            cited.blocks.dropLast().last, .block(.heading(level: 2, text: "References")),
            "the heading stays where it was written, above its list")
        // The numbered steps in the body sit above the heading, so they stay a numbered list.
        XCTAssertTrue(cited.blocks.contains(
            .block(.numbered(depth: 0, number: 1, text: "Constitute the Committee under Section 4 [1]."))))
    }

    /// An entry is lifted out where it stands, and the prose either side of it keeps its place.
    func testAnEntryIsLiftedOutOfTheProseInPlace() {
        let cited = CitedMarkdown.parse("Intro.\n[1] Listed\nAfterword.")
        XCTAssertEqual(cited.blocks, [
            .block(.paragraph("Intro.")),
            .references([CitationReference(number: 1, text: "Listed", ordinal: 0)]),
            .block(.paragraph("Afterword.")),
        ])
    }

    /// Models leave a blank line between entries as often as not. That is spacing within one
    /// list, not two lists.
    func testBlankLinesBetweenEntriesKeepOneList() {
        let cited = CitedMarkdown.parse("Body.\n\n[1] First\n\n\n[2] Second\n\nClosing note.")
        XCTAssertEqual(cited.blocks.count, 3)
        guard case .references(let listed) = cited.blocks[1] else {
            return XCTFail("expected one list, got \(cited.blocks)")
        }
        XCTAssertEqual(listed.map(\.text), ["First", "Second"])
        XCTAssertEqual(cited.blocks[2], .block(.paragraph("Closing note.")))
    }

    /// The regression guard for every answer without references, which is most of them: the
    /// blocks are exactly the ones the renderer drew before citations existed.
    func testAnAnswerWithoutReferencesIsLaidOutExactlyAsBefore() {
        let markdown = """
            # Grounds

            The order is **without jurisdiction** [1] and *perverse*.

            1. First ground
            2. Second ground
               - a sub-point

            | Date | Event |
            | --- | --- |
            | 14.07.2026 | Notice issued |

            > Held, the appeal fails.

            ```
            [1] code, not a reference
            ```
            """
        let before: [CitedBlock] = MarkdownTable.segments(in: markdown).flatMap { segment -> [CitedBlock] in
            switch segment {
            case .prose(let prose): return MarkdownBlocks.parse(prose).map(CitedBlock.block)
            case .table(let table): return [.table(table)]
            }
        }
        let cited = CitedMarkdown.parse(markdown)
        XCTAssertEqual(cited.blocks, before)
        XCTAssertTrue(cited.index.isEmpty)
    }

    /// A numbered list is references only under a References heading. Anywhere else it is the
    /// answer's own steps, and turning those into citation targets would be absurd.
    func testANumberedListIsReferencesOnlyUnderTheHeading() {
        XCTAssertEqual(references("Steps:\n1. File the reply\n2. Serve it"), [])
        XCTAssertEqual(
            references("Steps:\n1. File the reply\n\n## Sources\n1. Indian Kanoon"),
            ["[1] Indian Kanoon"])
        // The heading must stand alone on its line; a sentence starting with the word is prose.
        XCTAssertEqual(references("References are below.\n1. Not one"), [])
        XCTAssertEqual(references("**References**\n1. Not one"), [])
    }

    /// A heading still arriving — no line break after it yet — is not a heading. One more
    /// character makes it one; nothing that was a reference ever stops being one.
    func testAHeadingStillStreamingIsNotAHeadingYet() {
        XCTAssertEqual(references("Per [1].\n\nSources"), [])
        XCTAssertEqual(references("Per [1].\n\nSources\n"), [])
        XCTAssertEqual(references("Per [1].\n\nSources\n1. Indian Kanoon"), ["[1] Indian Kanoon"])
    }

    /// A number listed twice is drawn twice, but a marker leads to the first — the web's lookup
    /// returns the first element with that id in document order.
    func testTheFirstListingOfARepeatedNumberIsTheOneCited() {
        let index = CitedMarkdown.parse("Per [1].\n\n[1] First\n[1] Second").index
        XCTAssertEqual(index.references.map(\.text), ["First", "Second"])
        XCTAssertEqual(index.reference(for: 1)?.text, "First")
        XCTAssertEqual(Set(index.references.map(\.id)).count, 2, "two rows, two identities")
    }

    /// Code is shown as written. The web reads `[1] …` inside a fence as an entry and rewrites
    /// the snippet; here a fence is never references, never a heading, never a marker.
    func testAFencedBlockIsNeverReferences() {
        let cited = CitedMarkdown.parse("```\nReferences\n[1] in code\n1. in code\n```\nCite [1].\n\n[1] Listed")
        XCTAssertEqual(cited.index.references.map(\.text), ["Listed"])
        XCTAssertEqual(cited.blocks.first, .block(.code("References\n[1] in code\n1. in code")))
    }

    /// `[3]: https://…` is how a reference-style link is defined. When the answer uses `[3]` as
    /// a link label, the line is the definition and is left for the link; without such a use it
    /// is an entry whose text is a URL, as on the web.
    func testALinkDefinitionIsAnEntryOnlyWhenNoLinkUsesIt() {
        XCTAssertEqual(references("Read [the Act][3].\n\n[3]: https://indiankanoon.org/doc/1"), [])
        XCTAssertEqual(
            references("Per [3].\n\n[3]: https://indiankanoon.org/doc/1"),
            ["[3] https://indiankanoon.org/doc/1"])
        // A colon entry is not a definition just because the label is used: it has no URL.
        XCTAssertEqual(
            references("Read [the Act][3].\n\n[3]: POSH Act, 2013"), ["[3] POSH Act, 2013"])
    }

    /// An entry is one line. The web's pattern can take the next line as the text of a bare
    /// `[1]`, which would make an entry's extent depend on what streams in after it.
    func testAnEntryIsOneLine() {
        XCTAssertEqual(references("Cited [1].\n\n[1]\nPOSH Act, 2013"), [])
        XCTAssertEqual(
            references("Cited [1].\n\n[1] POSH Act, 2013 —\nSections 4, 9."),
            ["[1] POSH Act, 2013 —"])
    }

    /// The web cuts a numbered entry at its first `<`; here the whole line is the entry, so a
    /// comparison in a reference is not lost.
    func testANumberedEntryKeepsItsWholeLine() {
        XCTAssertEqual(
            references("References\n1. Damages < 50,000 under Section 73"),
            ["[1] Damages < 50,000 under Section 73"])
    }

    /// The number on an entry is ASCII digits, as JavaScript's `\d` is. A Devanagari numeral is
    /// text, so `[१]` neither lists nor cites anything.
    func testDevanagariDigitsAreText() {
        XCTAssertEqual(references("[१] Not an entry\n[1] An entry"), ["[1] An entry"])
        XCTAssertEqual(markers("धारा [१] और [1]"), [[1]])
        // `\d+` stops at the ASCII digit, and to JavaScript's ASCII `\b` a Devanagari numeral is
        // not a word character — so the web badges the 1 here, and so does this.
        XCTAssertEqual(markers("Ref 1१"), [[1]])
    }

    // MARK: - Markers in the body

    func testTheThreeMarkerFormsAndWhereTheySit() {
        let found = CitationMarkers.find(in: "A [1, 3] B 【2】 C Ref. 4.")
        XCTAssertEqual(found.map(\.numbers), [[1, 3], [2], [4]])
        XCTAssertEqual(found.map(\.form), [.bracketed, .fullWidth, .spoken])
        XCTAssertEqual(found.map(\.range), [2..<8, 11..<14, 17..<23])
    }

    /// The things that look like a bracketed number and are not one.
    func testFootnotesCheckboxesRangesAndTagsAreNeverMarkers() {
        for text in [
            "See note[^1].", "- [ ] open", "- [x] done", "[2–4]", "[1-3]", "[ 1 ]", "[1a]",
            "[Settled]", "[CANVAS_TRIGGER: Petition]", "[bracketed note]", "[1](https://x.in)",
        ] {
            XCTAssertEqual(markers(text), [], text)
        }
    }

    /// Inline code is shown verbatim, so nothing in it is a citation — however many backticks
    /// open it. A lone backtick opens nothing, and the prose after it is still read.
    func testCodeSpansAreNeverRead() {
        XCTAssertEqual(markers("Write `arr[1]` here, cite [2]."), [[2]])
        XCTAssertEqual(markers("Write ``a ` [1]`` here."), [])
        XCTAssertEqual(markers("A stray ` then [3]."), [[3]])
    }

    /// A link is a link: its text and its destination are left alone, so `[see [1]](url)` still
    /// opens the page and does not turn into a badge inside broken brackets.
    func testLinksKeepTheirTextAndDestination() {
        XCTAssertEqual(markers("[see [1] here](https://x.in/[2]) and [3]"), [[3]])
        XCTAssertEqual(markers("![seal [1]](seal.png) and [3]"), [[3]])
        XCTAssertEqual(markers("Read [the judgment][2], cite [1]."), [[1]])
        XCTAssertEqual(markers("See <https://x.in/a[1]> and [2]."), [[2]])
        // Two bracketed numbers side by side are two citations, not a reference-style link.
        XCTAssertEqual(markers("Held [1][2]."), [[1], [2]])
        // Brackets that are only brackets are read inside.
        XCTAssertEqual(markers("Held [[1]] and [see [2]]."), [[1], [2]])
    }

    func testAnEscapedBracketIsTheAuthorAskingForOne() {
        XCTAssertEqual(markers(#"The form \[1] is literal; cite [2]."#), [[2]])
        // An escaped backslash does not escape the bracket after it.
        XCTAssertEqual(markers(#"A path C:\\[1]"#), [[1]])
    }

    /// The spoken form follows JavaScript's `\b`: the digits may not run on into a letter.
    func testTheSpokenFormNeedsAWordBoundaryAfterTheNumber() {
        XCTAssertEqual(markers("Ref 12a"), [])
        XCTAssertEqual(markers("Ref 12, "), [[12]])
        XCTAssertEqual(markers("citation 3_x"), [])
        XCTAssertEqual(markers("Cross-ref 2"), [[2]])
        XCTAssertEqual(markers("Refs 2 and Reference 3"), [])
    }

    // MARK: - Resolving and linking

    /// Only a marker every number of which is listed becomes a badge. An orphan stays the text
    /// the model wrote: the web badges it, but the badge leads nowhere, and on a phone that is a
    /// control that does nothing.
    func testOnlyAMarkerWhoseEveryNumberIsListedBecomesALink() {
        let linked = CitationMarkup.linked(
            "Held [1], [7] and [1, 7], per [1, 2].", citations: index(1, 2))
        XCTAssertEqual(
            linked.markdown,
            "Held \(link(1, 1)), [7] and [1, 7], per \(link(1, 2)) \(link(2, 3)).")
        XCTAssertEqual(linked.references.map(\.number), [1, 2])
    }

    func testEachFormBecomesOneLinkPerNumber() {
        let linked = CitationMarkup.linked("A 【2】 B Ref. 1 C [2,1].", citations: index(1, 2))
        XCTAssertEqual(
            linked.markdown,
            "A \(link(2, 1)) B \(link(1, 2)) C \(link(2, 3)) \(link(1, 4)).")
        XCTAssertEqual(linked.references.map(\.number), [2, 1], "first cited first, each once")
    }

    /// An answer without references — or a block without markers — comes back untouched, so
    /// the renderer takes exactly the path it took before citations existed.
    func testTextWithNothingToLinkIsReturnedUntouched() {
        let text = "Under **the Act** [1], see [docs](https://x.in)."
        XCTAssertEqual(CitationMarkup.linked(text, citations: .empty).markdown, text)
        XCTAssertEqual(CitationMarkup.linked(text, citations: index(2)).markdown, text)
        XCTAssertEqual(CitationMarkup.linked(text, citations: index(2)).references, [])
    }

    /// Emphasis around a marker survives, because the marker is rewritten in place inside the
    /// markdown rather than cut out of it.
    func testEmphasisAroundAMarkerIsKept() {
        XCTAssertEqual(
            CitationMarkup.linked("**Under the POSH Act [1], the employer**", citations: index(1))
                .markdown,
            "**Under the POSH Act \(link(1, 1)), the employer**")
    }

    /// `![1](…)` is image syntax. A `!` before a marker is escaped so it stays an exclamation
    /// mark — unless the model already escaped it.
    func testAnExclamationMarkBeforeAMarkerDoesNotMakeAnImage() {
        XCTAssertEqual(
            CitationMarkup.linked("Wow![1]", citations: index(1)).markdown,
            #"Wow\!"# + link(1, 1))
        XCTAssertEqual(
            CitationMarkup.linked(#"Wow\![1]"#, citations: index(1)).markdown,
            #"Wow\!"# + link(1, 1))
    }

    /// Two badges for the same number side by side must stay two links: `AttributedString`
    /// merges neighbouring runs whose attributes are equal, and would draw one badge.
    func testRepeatedMarkersCarryDistinctLinks() {
        let linked = CitationMarkup.linked("[1][1]", citations: index(1))
        XCTAssertEqual(linked.markdown, link(1, 1) + link(1, 2))
        XCTAssertEqual(CitationLink.number(from: try XCTUnwrap(URL(string: "emperor-citation:1#2"))), 1)
    }

    /// The end of a block that is still streaming may be the middle of a marker: `Ref 1` may be
    /// `Ref 12` a moment later, and `[1]` may be the start of `[1](https://…)`. It is held as
    /// text until the next character settles it.
    func testAMarkerAtTheEndOfAStreamingBlockWaitsForTheNextCharacter() {
        let citations = index(1, 12)
        XCTAssertEqual(
            CitationMarkup.linked("See Ref 1", citations: citations, holdingTrailingMarker: true)
                .markdown,
            "See Ref 1")
        XCTAssertEqual(
            CitationMarkup.linked("See Ref 12.", citations: citations, holdingTrailingMarker: true)
                .markdown,
            "See \(link(12, 1)).")
        XCTAssertEqual(
            CitationMarkup.linked("Held [1] and [1]", citations: citations,
                                  holdingTrailingMarker: true).markdown,
            "Held \(link(1, 1)) and [1]",
            "only the last marker waits")
        XCTAssertEqual(
            CitationMarkup.linked("See Ref 1", citations: citations).markdown,
            "See \(link(1, 1))",
            "a finished answer's last marker is a citation like any other")
    }

    // MARK: - Streaming

    /// A realistic answer as the stream delivers it.
    ///
    /// It arrives in uneven chunks, as provider chunks do — and one character at a time across
    /// the opening of every reference entry, which is where each badge in the answer comes into
    /// being.
    ///
    /// What must hold: a reference, once listed, stays listed with the same number and a text
    /// that only grows; a badge, once drawn, is never taken back; and nothing a block hands the
    /// renderer is ever half a citation link.
    func testAStreamingAnswerOnlyEverGainsCitations() throws {
        let answer = Array(try realisticAnswer().unicodeScalars)
        let chunks = [1, 3, 2, 7, 4, 11, 5, 17]
        var lengths: Set<Int> = [answer.count]
        var length = 0
        var chunk = 0
        while length < answer.count {
            length += chunks[chunk % chunks.count]
            chunk += 1
            lengths.insert(min(length, answer.count))
        }
        for (position, scalar) in answer.enumerated()
        where scalar == "[" && position > 0 && answer[position - 1] == "\n" {
            lengths.formUnion(position...min(position + 12, answer.count))
        }

        var previous: [CitationReference] = []
        var previousBadges = 0
        let badge = try NSRegularExpression(
            pattern: #"\[(\d+)\]\(emperor-citation:(\d+)#\d+\)"#)

        for length in lengths.sorted() {
            let prefix = CitedMarkdown.string(answer[0..<length])
            let cited = CitedMarkdown.parse(prefix)

            let references = cited.index.references
            XCTAssertGreaterThanOrEqual(references.count, previous.count, "at \(length)")
            for (old, new) in zip(previous, references) {
                XCTAssertEqual(old.number, new.number, "at \(length)")
                XCTAssertTrue(new.text.hasPrefix(old.text), "entry \(old.number) shrank at \(length)")
            }
            previous = references

            var badges = 0
            for (position, block) in cited.blocks.enumerated() {
                // As `MarkdownContentView` has it: only a prose block can be the streaming tail.
                var isTail = false
                if case .block = block { isTail = position == cited.blocks.count - 1 }
                for text in Self.inlineTexts(block) {
                    let linked = CitationMarkup.linked(
                        text, citations: cited.index, holdingTrailingMarker: isTail)
                    let ns = linked.markdown as NSString
                    let whole = badge.numberOfMatches(
                        in: linked.markdown, range: NSRange(location: 0, length: ns.length))
                    XCTAssertEqual(
                        whole, linked.markdown.components(separatedBy: "emperor-citation:").count - 1,
                        "a malformed citation link at \(length): \(linked.markdown)")
                    badges += whole
                }
            }
            XCTAssertGreaterThanOrEqual(
                badges, previousBadges, "a badge went back to text at \(length): \(prefix.suffix(40))")
            previousBadges = badges
        }

        XCTAssertEqual(previous.map(\.number), [1, 2, 3])
        XCTAssertEqual(previousBadges, 12, "every marker in the finished answer is a badge")
    }

    /// Before the References arrive there is nothing to cite, so the body reads exactly as the
    /// model wrote it — `[1]`, not a badge to nowhere and not a broken one.
    func testBeforeItsReferencesArriveAnAnswerIsPlainText() throws {
        let answer = try realisticAnswer()
        let body = String(answer[..<answer.range(of: "## References")!.lowerBound])
        let cited = CitedMarkdown.parse(body)
        XCTAssertTrue(cited.index.isEmpty)
        for block in cited.blocks {
            for text in Self.inlineTexts(block) {
                XCTAssertEqual(CitationMarkup.linked(text, citations: cited.index).markdown, text)
            }
        }
    }

    static func inlineTexts(_ block: CitedBlock) -> [String] {
        switch block {
        case .block(let block):
            if case .code = block { return [] }
            return [block.text]
        case .table(let table):
            return table.headers + table.normalisedRows.flatMap { $0 }
        case .references(let references):
            return references.map(\.text)
        }
    }

    // MARK: - Annexure citations are a different thing, and stay one

    /// `<@file.pdf:MARK:7>` tokens and numbered citations in one answer. The tokens are lifted
    /// by `StreamContent` exactly as before; the numbers are found in what is left; and the
    /// stored copy that goes back to the server still carries every token and every number.
    func testAnnexureMentionsAndNumberedCitationsDoNotInterfere() {
        let raw = """
            The non-compete in clause 4.2 [1] <@Employment_Agreement.pdf:P-1:4-9> is void under \
            Section 27 [2]. The covering letter <@Annexure [1].pdf:P-2> says the same.

            ## References
            [1] Clause 4.2 of the Employment Agreement — Non-compete covenants <@Employment_Agreement.pdf:P-1:4>
            [2] Indian Contract Act, 1872 — Section 27.
            """
        let content = StreamContent.parse(raw)

        XCTAssertEqual(content.mentions, [
            AnnexureMention(fileName: "Employment_Agreement.pdf", mark: "P-1", startPage: 4, endPage: 9),
            AnnexureMention(fileName: "Annexure [1].pdf", mark: "P-2", startPage: nil, endPage: nil),
            AnnexureMention(fileName: "Employment_Agreement.pdf", mark: "P-1", startPage: 4, endPage: nil),
        ])
        XCTAssertFalse(content.prose.contains("<@"))
        XCTAssertEqual(content.persistableContent, raw, "the stored copy is untouched")

        let cited = CitedMarkdown.parse(content.prose)
        XCTAssertEqual(
            cited.index.references.map(\.text),
            ["Clause 4.2 of the Employment Agreement — Non-compete covenants",
             "Indian Contract Act, 1872 — Section 27."])
        guard case .block(let body)? = cited.blocks.first else { return XCTFail() }
        // `[1]` inside the annexure's file name went with the token, so it is not a citation.
        XCTAssertEqual(markers(body.text), [[1], [2]])
    }

    /// While a token is still streaming in, `StreamContent` cannot strip it yet and it sits in
    /// the prose. Nothing inside it is read as a citation, so a bracket in a file name cannot
    /// flash up as a badge before the token completes and vanishes.
    func testAnAnnexureTokenStillArrivingIsNeverRead() {
        XCTAssertEqual(markers("See [1] <@Annexure [2].pdf:P-"), [[1]])
        XCTAssertEqual(markers("See <@Annexure [2].pdf:P-3> then [1]"), [[1]])
        XCTAssertEqual(markers("Line <@Annexure [2].pdf\nnext [3]"), [[3]])
        // A comparison is not a token.
        XCTAssertEqual(markers("damages < 50,000 [1]"), [[1]])
    }

    // MARK: - The private link

    func testACitationLinkRoundTripsAndNothingElseIsOne() throws {
        let url = try XCTUnwrap(CitationLink.url(for: 12, occurrence: 3))
        XCTAssertEqual(url.absoluteString, "emperor-citation:12#3")
        XCTAssertEqual(CitationLink.number(from: url), 12)
        XCTAssertEqual(CitationLink.number(from: try XCTUnwrap(URL(string: "EMPEROR-CITATION://7"))), 7)

        for other in ["https://indiankanoon.org/doc/12", "mailto:clerk@example.com", "tel:12",
                      "emperor-citation:", "emperor-citation:x"] {
            XCTAssertNil(CitationLink.number(from: try XCTUnwrap(URL(string: other))), other)
        }
    }

    // MARK: - Export

    /// A filed document carries citations the way paper does: `[1]` in the text and a
    /// References list with one entry per line. Nothing in it points into the app.
    func testAnExportedAnswerKeepsPlainMarkersAndAReferencesList() {
        let answer = """
            Under the **POSH Act** [1], the Committee must be constituted [1, 2].

            ## References
            [1] POSH Act, 2013 — Section 4.
            [2] Vishaka v. State of Rajasthan, (1997) 6 SCC 241.
            """
        XCTAssertEqual(
            MarkdownHTML.answerFragment(answer),
            "<p>Under the <b>POSH Act</b> [1], the Committee must be constituted [1, 2].</p>"
                + "<h2>References</h2>"
                + "<p>[1] POSH Act, 2013 — Section 4.<br>"
                + "[2] Vishaka v. State of Rajasthan, (1997) 6 SCC 241.</p>")
    }

    /// The References heading used to swallow the list written under it — the whole block
    /// became one `<h2>`. A heading is its own line, and only a line the screen would call one.
    func testAnExportedHeadingIsOneLine() {
        XCTAssertEqual(
            MarkdownHTML.html(from: "## References\n[1] A\n[2] B"),
            "<h2>References</h2><p>[1] A<br>[2] B</p>")
        XCTAssertEqual(MarkdownHTML.html(from: "#### Deep\n\nText"), "<h3>Deep</h3><p>Text</p>")
        XCTAssertEqual(MarkdownHTML.html(from: "## Alone"), "<h2>Alone</h2>")
        XCTAssertEqual(
            MarkdownHTML.html(from: "Closing paragraph.\n## References\n[1] A"),
            "<p>Closing paragraph.</p><h2>References</h2><p>[1] A</p>",
            "a heading written straight under a paragraph is still a heading")
        XCTAssertEqual(
            MarkdownHTML.html(from: "#1 of 2026 was listed today."),
            "<p>#1 of 2026 was listed today.</p>")
    }

    /// The realistic answer, whole: every marker survives as written, and no private link, web
    /// anchor or markdown link syntax leaks into a document someone will file.
    func testAnExportedRealisticAnswerHasNoAppLinks() throws {
        let html = MarkdownHTML.answerFragment(try realisticAnswer())
        for leak in ["emperor-citation", "#cite-", "](", "<a "] {
            XCTAssertFalse(html.contains(leak), leak)
        }
        XCTAssertTrue(html.contains("(the <b>POSH Act</b>) [1]"))
        XCTAssertTrue(html.contains("legislated [1, 3]."))
        XCTAssertTrue(html.contains("<br>[3] Vishaka vs. State of Rajasthan"))
    }

    /// An answer is markdown and is bridged as markdown — handed to the exporter raw, its line
    /// breaks collapse and the References run together. The rare answer written as block HTML
    /// goes through as it is.
    func testAnAnswerIsBridgedAsMarkdownUnlessItIsHTML() {
        XCTAssertEqual(
            MarkdownHTML.answerFragment("Line one\n[1] Entry"), "<p>Line one<br>[1] Entry</p>")
        let html = "<p>Already <b>HTML</b> [1].</p>"
        XCTAssertEqual(MarkdownHTML.answerFragment(html), html)
    }

    // MARK: - Colour

    /// The number is caption-sized, so it is held to 4.5:1 — in `accentText` on the citation
    /// wash, over the canvas an answer sits on and the card a reference row sits on.
    func testACitationNumberClearsAAWhereItIsDrawn() {
        for (name, palette) in [("dark", Palette.dark), ("light", Palette.light)] {
            for (surfaceName, surface) in [
                ("canvas", palette.canvas), ("surface", palette.surface),
            ] {
                let fill = palette.citationFill.composited(over: surface)
                let ratio = palette.accentText.composited(over: fill).contrastRatio(against: fill)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(name)/\(surfaceName): citation number is \(String(format: "%.2f", ratio)):1")
            }
        }
    }
}
