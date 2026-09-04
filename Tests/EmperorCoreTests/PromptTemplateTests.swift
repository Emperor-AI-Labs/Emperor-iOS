import XCTest
@testable import EmperorCore

final class PromptTemplateTests: XCTestCase {

    func testPlainTextHasNoPlaceholders() {
        let template = PromptTemplate.parse("Draft a reply to the notice.")
        XCTAssertFalse(template.hasPlaceholders)
        XCTAssertEqual(template.segments, [.text("Draft a reply to the notice.")])
    }

    func testPlaceholderIsSplitOut() {
        let template = PromptTemplate.parse("File in {{WHICH COURT}} by Friday.")
        XCTAssertEqual(template.segments, [
            .text("File in "),
            .placeholder(label: "WHICH COURT"),
            .text(" by Friday."),
        ])
        XCTAssertEqual(template.labels, ["WHICH COURT"])
    }

    func testLabelIsTrimmed() {
        let template = PromptTemplate.parse("{{  CASE NUMBER  }}")
        XCTAssertEqual(template.labels, ["CASE NUMBER"])
    }

    func testPlaceholderAtEachEnd() {
        let template = PromptTemplate.parse("{{A}} middle {{B}}")
        XCTAssertEqual(template.segments, [
            .placeholder(label: "A"), .text(" middle "), .placeholder(label: "B"),
        ])
    }

    func testAdjacentPlaceholders() {
        let template = PromptTemplate.parse("{{A}}{{B}}")
        XCTAssertEqual(template.labels, ["A", "B"])
    }

    /// A model that needs the same fact twice writes the label twice. Asking twice would be
    /// absurd, so one field drives both.
    func testRepeatedLabelIsOfferedOnce() {
        let template = PromptTemplate.parse("Send {{PARTY}} the notice, then tell {{PARTY}} why.")
        XCTAssertEqual(template.labels, ["PARTY"])
        XCTAssertEqual(
            template.filled(with: ["PARTY": "Mr Bakshi"]),
            "Send Mr Bakshi the notice, then tell Mr Bakshi why.")
    }

    // MARK: - What must NOT be treated as a placeholder

    /// Square brackets were rejected as the syntax precisely because real legal text is full
    /// of them. Braces are rarer, but a prompt about JSON or a template is entirely plausible
    /// from this audience, so the shape has to be matched strictly.
    func testSingleBracesAreProse() {
        let text = "Return {\"status\": \"ok\"} exactly."
        XCTAssertEqual(PromptTemplate.parse(text).segments, [.text(text)])
    }

    func testUnclosedTokenIsProse() {
        let text = "Explain {{ this never closes"
        XCTAssertEqual(PromptTemplate.parse(text).segments, [.text(text)])
    }

    /// The web client's pattern is `[^}]+`, so a stray `}` inside means this is not a token.
    /// The server never parses these tokens at all — it only tells the model to emit them.
    func testTokenContainingABraceIsProse() {
        let text = "Use {{a}b}} here"
        XCTAssertFalse(PromptTemplate.parse(text).hasPlaceholders)
        XCTAssertEqual(PromptTemplate.parse(text).raw, text)
    }

    func testEmptyTokenIsProse() {
        XCTAssertFalse(PromptTemplate.parse("nothing {{}} here").hasPlaceholders)
    }

    /// A blank with no label cannot be filled on a phone — there is nothing to tell the user
    /// what to type — so it stays prose rather than becoming an unlabelled field.
    func testWhitespaceOnlyLabelIsProse() {
        XCTAssertFalse(PromptTemplate.parse("nothing {{   }} here").hasPlaceholders)
    }

    func testStrayBracesInLegalCitationsSurvive() {
        let text = "Cite [Section 138] and exhibit [P-4], not {x}."
        XCTAssertEqual(PromptTemplate.parse(text).raw, text)
    }

    // MARK: - Filling

    /// The point of the placeholder is that the assistant is *told* what is missing. Dropping
    /// an unfilled one leaves a fluent sentence with a hole in it — which is the fabrication
    /// risk the guardrail exists to remove.
    func testUnfilledPlaceholderGoesBackAsItsLabel() {
        let template = PromptTemplate.parse("Draft for {{WHICH MATTER}} before {{DATE}}.")
        XCTAssertEqual(
            template.filled(with: ["DATE": "12 September"]),
            "Draft for {{WHICH MATTER}} before 12 September.")
    }

    func testWhitespaceOnlyAnswerCountsAsUnfilled() {
        let template = PromptTemplate.parse("For {{PARTY}}.")
        XCTAssertEqual(template.filled(with: ["PARTY": "   "]), "For {{PARTY}}.")
    }

    func testAnswersAreTrimmed() {
        let template = PromptTemplate.parse("For {{PARTY}}.")
        XCTAssertEqual(template.filled(with: ["PARTY": "  ABC Ltd \n"]), "For ABC Ltd.")
    }

    /// An unfilled round trip is byte-identical for every input that has no padded label —
    /// see the next test for the one deliberate exception.
    func testParseThenRawIsLossless() {
        for text in [
            "plain",
            "{{A}}",
            "a {{B}} c",
            "{ not a token }",
            "unclosed {{",
            "",
            "देखिए {{कौन सा मामला}} अभी",
        ] {
            XCTAssertEqual(PromptTemplate.parse(text).raw, text, "round trip failed for \(text)")
        }
    }

    /// The one deliberate exception to the round trip. The label is trimmed on the way in and
    /// re-emitted trimmed, matching the web serialiser (`EnhancedPromptFields.jsx:37`) so both
    /// clients hand the assistant the same token for the same blank.
    func testAPaddedLabelLosesItsPaddingOnTheWayBack() {
        XCTAssertEqual(PromptTemplate.parse("{{ CASE NUMBER }}").raw, "{{CASE NUMBER}}")
        XCTAssertEqual(PromptTemplate.parse("a {{\n B \n}} c").raw, "a {{B}} c")
    }

    /// Devanagari labels are entirely realistic — the enhancer is told to preserve the user's
    /// language — and a Character-based scan must not mangle them.
    func testDevanagariLabel() {
        let template = PromptTemplate.parse("मुझे {{कौन सा मामला}} चाहिए")
        XCTAssertEqual(template.labels, ["कौन सा मामला"])
        XCTAssertEqual(
            template.filled(with: ["कौन सा मामला": "पार्टीशन सूट"]),
            "मुझे पार्टीशन सूट चाहिए")
    }

    func testEmojiAroundAPlaceholderSurvives() {
        let template = PromptTemplate.parse("⚖️ file in {{COURT}} ⚖️")
        XCTAssertEqual(template.filled(with: ["COURT": "NCLT"]), "⚖️ file in NCLT ⚖️")
    }

    /// The example the platform's own system prompt ships, end to end.
    func testTheSystemPromptsOwnExample() {
        let output = """
            I need help with a legal matter but haven't specified the details. Please explain \
            {{THE LEGAL TOPIC OR ISSUE}} in the context of {{RELEVANT JURISDICTION}}, and let \
            me know what additional information you need from me to proceed.
            """
        let template = PromptTemplate.parse(output)
        XCTAssertEqual(template.labels, ["THE LEGAL TOPIC OR ISSUE", "RELEVANT JURISDICTION"])
        XCTAssertEqual(
            template.filled(with: [
                "THE LEGAL TOPIC OR ISSUE": "cheque dishonour under s.138",
                "RELEVANT JURISDICTION": "Bombay High Court",
            ]),
            """
            I need help with a legal matter but haven't specified the details. Please explain \
            cheque dishonour under s.138 in the context of Bombay High Court, and let me know \
            what additional information you need from me to proceed.
            """)
    }
}
