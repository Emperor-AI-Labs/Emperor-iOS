import XCTest
@testable import EmperorCore

// MARK: - The export funnel

final class DraftEditScrubTests: XCTestCase {

    func testEditModesOwnAttributesGoFromTheElementsItMarked() {
        let html = #"<div contenteditable="true" data-ex-edit="1" role="textbox" aria-multiline="true" spellcheck="true" class="x"><p>Text</p></div>"#
        XCTAssertEqual(DraftEdit.scrub(html), #"<div class="x"><p>Text</p></div>"#)
    }

    /// The web removes them only where it put them: a `role` the model wrote on a table stays.
    func testAttributesOnUnmarkedElementsStay() {
        let html = #"<table role="presentation"><tr><td>x</td></tr></table>"#
        XCTAssertEqual(DraftEdit.scrub(html), html)
    }

    func testAlignBecomesTextAlign() {
        XCTAssertEqual(DraftEdit.scrub(#"<p align="center">Title</p>"#),
                       #"<p style="text-align: center;">Title</p>"#)
        XCTAssertEqual(DraftEdit.scrub(#"<div align=right style="font-weight: bold">x</div>"#),
                       #"<div style="font-weight: bold; text-align: right;">x</div>"#)
        XCTAssertEqual(DraftEdit.scrub(#"<p style="text-align: left; color: red" align='justify'>x</p>"#),
                       #"<p style="color: red; text-align: justify;">x</p>"#)
    }

    func testFontIsUnwrappedKeepingWhatIsInside() {
        XCTAssertEqual(DraftEdit.scrub(#"<p><font face="Arial"><b>Bold</b> text</font></p>"#),
                       "<p><b>Bold</b> text</p>")
    }

    func testNothingExecutableOrPageLevelSurvives() {
        let html = #"<p>a</p><script>alert(1)</script><style>p{}</style><meta charset="x"><link rel="x"><base href="/"><p>b</p>"#
        XCTAssertEqual(DraftEdit.scrub(html), "<p>a</p><p>b</p>")
    }

    func testThePasteMarkerGoes() {
        XCTAssertEqual(DraftEdit.scrub(#"<p>a<br class="Apple-interchange-newline"></p><p>b<br></p>"#),
                       "<p>a</p><p>b<br></p>")
    }

    func testAnUntouchedDocumentIsUnchanged() {
        let html = #"<h1 style="text-align:center">TITLE</h1><p>Body &amp; more</p><table><tr><td>1</td></tr></table>"#
        XCTAssertEqual(DraftEdit.scrub(html), html)
    }
}

// MARK: - The outline

final class DraftEditOutlineTests: XCTestCase {

    func testHeadingsAndBoldOnlyParagraphsInDocumentOrder() {
        let html = """
            <h1>PLAINT</h1><p>Intro text.</p><p><strong>SYNOPSIS</strong></p>\
            <h2 id="facts">Facts</h2><p>A <b>bold</b> word in a sentence.</p><h3>Cause of action</h3>\
            <h5>Too deep</h5><p><b>PRAYER</b></p>
            """
        let (anchored, outline) = DraftEdit.anchored(html)
        XCTAssertEqual(outline, [
            .init(id: "doc-h-0", text: "PLAINT", level: 1),
            .init(id: "doc-h-1", text: "SYNOPSIS", level: 2),
            .init(id: "facts", text: "Facts", level: 2),
            .init(id: "doc-h-3", text: "Cause of action", level: 3),
            .init(id: "doc-h-4", text: "PRAYER", level: 2),
        ])
        XCTAssertTrue(anchored.contains(#"<h1 id="doc-h-0">PLAINT</h1>"#))
        XCTAssertTrue(anchored.contains(#"<p id="doc-h-1"><strong>SYNOPSIS</strong></p>"#))
        XCTAssertTrue(anchored.contains(#"<h2 id="facts">Facts</h2>"#), "an id of its own is kept")
        XCTAssertTrue(anchored.contains("<h5>Too deep</h5>"))
    }

    /// A fully bolded body paragraph is not a section title.
    func testALongBoldParagraphIsNotAHeading() {
        let long = String(repeating: "word ", count: 30)
        XCTAssertTrue(DraftEdit.outline(of: "<p><strong>\(long)</strong></p>").isEmpty)
    }

    func testTwoBoldRunsAreNotAHeading() {
        XCTAssertTrue(DraftEdit.outline(of: "<p><b>A</b> <b>B</b></p>").isEmpty)
        XCTAssertTrue(DraftEdit.outline(of: "<p><b>A</b> and more</p>").isEmpty)
    }

    func testEmptyHeadingsAreSkippedAndTextIsDecoded() {
        let outline = DraftEdit.outline(of: "<h2> </h2><h2>Rent &amp; <i>arrears</i>&nbsp;due</h2>")
        XCTAssertEqual(outline, [.init(id: "doc-h-0", text: "Rent & arrears due", level: 2)])
    }

    /// Anchoring twice changes nothing the second time: the ids are already there.
    func testAnchoringIsIdempotent() {
        let once = DraftEdit.anchored("<h1>A</h1><h2>B</h2>").html
        XCTAssertEqual(DraftEdit.anchored(once).html, once)
    }
}

// MARK: - What the editor opens over

final class DraftEditBodyTests: XCTestCase {

    func testCitationTokensAndNarrationAreNotShown() {
        let body = "Now I will draft it.\n\n<p>Annexure P-2 <@Ledger.pdf:P-2:4-9>, as filed.</p>"
        XCTAssertEqual(DraftEdit.editableHTML(body: body, format: .html), "<p>Annexure P-2 , as filed.</p>")
    }

    func testAMarkdownTableIsEditedAsAnHTMLTable() {
        let html = DraftEdit.editableHTML(
            body: "| Date | Event |\n| --- | --- |\n| 04.03.2024 | Agreement |", format: .markdown)
        XCTAssertTrue(html.contains("<table"))
        XCTAssertTrue(html.contains("Agreement"))
        XCTAssertFalse(html.contains("| ---"))
    }

    /// The folded body keeps every citation the edited one lost, out of sight.
    func testCitationsTheEditDroppedAreCarried() {
        let raw = "[CANVAS_TRIGGER: P]\n<canvas_content><p>x <@A.pdf:P-1> y <@B.pdf:P-2:3></p></canvas_content>"
        let folded = DraftEdit.replaceCanvasBody(raw, html: "<p>x <@A.pdf:P-1> y, edited</p>")
        XCTAssertEqual(folded, "[CANVAS_TRIGGER: P]\n<canvas_content>\n<p>x <@A.pdf:P-1> y, edited</p>\n<@B.pdf:P-2:3>\n</canvas_content>")
    }

    /// Template characters in the edit are text, not substitutions.
    func testDollarsAndBackslashesSurviveTheFold() {
        let raw = "<canvas_content><p>a</p></canvas_content>"
        XCTAssertEqual(DraftEdit.replaceCanvasBody(raw, html: #"<p>$1 \1 $0</p>"#),
                       "<canvas_content>\n<p>$1 \\1 $0</p>\n</canvas_content>")
    }

    func testTheMatchingFormIgnoresWhitespace() {
        XCTAssertEqual(DraftEdit.normalisedForMatch("  <p>a</p>\n\n <p>b</p> "), "<p>a</p> <p>b</p>")
    }
}

// MARK: - The web view's scripts

final class DraftEditScriptTests: XCTestCase {

    func testEveryCommandRunsItsExecCommandOnTheHost() {
        for command in DraftEditCommand.allCases {
            let script = DraftEditScript.run(command)
            XCTAssertTrue(script.contains("execCommand(\"\(command.execName)\""), command.rawValue)
            XCTAssertTrue(script.contains(DraftEditScript.hostSelector))
        }
    }

    func testTheToolbarOffersTheWebsCoreCommands() {
        XCTAssertEqual(Set(DraftEditCommand.toolbarOrder), Set(DraftEditCommand.allCases))
        XCTAssertEqual(DraftEditCommand.toolbarOrder.first, .undo)
        XCTAssertEqual(DraftEditCommand.alignCentre.label, "Centre")
    }

    func testStateIsReadForTheStatefulCommandsOnly() {
        XCTAssertTrue(DraftEditScript.state.contains(#""bold": q("bold")"#))
        XCTAssertTrue(DraftEditScript.state.contains(#""alignCentre": q("justifyCenter")"#))
        XCTAssertFalse(DraftEditScript.state.contains("\"undo\""))
    }

    func testStateIsParsed() {
        XCTAssertEqual(
            DraftEditScript.activeCommands(from: #"{"bold":true,"italic":false,"alignCentre":true,"nonsense":true}"#),
            [.bold, .alignCentre])
        XCTAssertEqual(DraftEditScript.activeCommands(from: nil), [])
        XCTAssertEqual(DraftEditScript.activeCommands(from: "not json"), [])
    }

    /// The id is a JavaScript string literal, whatever a heading's id holds.
    func testAJumpQuotesItsId() {
        let script = DraftEditScript.jump(to: #"a"b\c</script>"#)
        XCTAssertTrue(script.contains(#"getElementById("a\"b\\c</script>")"#))
        XCTAssertTrue(script.contains("scrollIntoView"))
    }

    func testBeginAndReadRunTheExportFunnel() {
        for script in [DraftEditScript.begin, DraftEditScript.read] {
            XCTAssertTrue(script.contains("querySelectorAll('font')"))
            XCTAssertTrue(script.contains("br.Apple-interchange-newline"))
            XCTAssertTrue(script.contains("script,style,meta,link,base"))
            XCTAssertTrue(script.contains("'contenteditable,spellcheck,data-ex-edit,data-ex-edited,role,aria-multiline,tabindex'"))
        }
        XCTAssertTrue(DraftEditScript.begin.contains("defaultParagraphSeparator"))
        XCTAssertTrue(DraftEditScript.begin.contains("styleWithCSS"))
    }

    /// The host is the element the page wrapper puts the fragment in.
    func testTheHostIsWhereThePageWrapperPutsTheDraft() {
        XCTAssertTrue(ArtifactDocument.html(wrapping: "<p>x</p>")
            .contains(#"<body><div class="scroll"><p>x</p></div></body>"#))
        XCTAssertEqual(DraftEditScript.hostSelector, "body > .scroll")
    }
}

// MARK: - Writing the conversation back

private func message(_ role: MessageRole, _ content: String, typing: Bool? = nil) -> ChatMessage {
    var built = ChatMessage(role: role, content: content)
    built.isTyping = typing
    return built
}

final class DraftEditSyncTests: XCTestCase {

    func testReplacingOneMemberKeepsEveryOtherByte() throws {
        let object = Data(#"{"role":"assistant", "content" : "old \"one\"","usage":{"content":1},"x":[1,2]}"#.utf8)
        let replaced = try XCTUnwrap(RawJSON.replacingMember(
            "content", with: Data(#""new""#.utf8), inObject: object))
        XCTAssertEqual(String(decoding: replaced, as: UTF8.self),
                       #"{"role":"assistant", "content" : "new","usage":{"content":1},"x":[1,2]}"#)
    }

    func testReplacingRefusesWhatItCannotDoExactly() {
        let value = Data(#""v""#.utf8)
        XCTAssertNil(RawJSON.replacingMember("content", with: value, inObject: Data(#"{"role":"user"}"#.utf8)))
        XCTAssertNil(RawJSON.replacingMember("content", with: value, inObject: Data(#"{"content":"a","content":"b"}"#.utf8)))
        XCTAssertNil(RawJSON.replacingMember("content", with: value, inObject: Data("[1]".utf8)))
        XCTAssertNil(RawJSON.replacingMember("content", with: Data("not json".utf8), inObject: Data(#"{"content":"a"}"#.utf8)))
    }

    func testTheStoredConversationMustMatchMessageForMessage() {
        let local = [message(.user, "Q"), message(.assistant, "A")]
        XCTAssertNil(DraftEditSync.mismatch(server: local, local: local))
        XCTAssertEqual(DraftEditSync.mismatch(server: local + [message(.user, "Q2")], local: local), .serverHasMore)
        XCTAssertEqual(DraftEditSync.mismatch(server: [local[0]], local: local), .serverHasFewer)
        XCTAssertEqual(DraftEditSync.mismatch(server: [local[0], message(.assistant, "B")], local: local),
                       .transcriptDiffers(at: 1))
        XCTAssertEqual(DraftEditSync.mismatch(server: [local[0], message(.assistant, "A", typing: true)], local: local),
                       .runStillActive)
    }

    func testTheBodyEchoesTheChatAndReplacesOneContent() throws {
        let chat = ChatSummary(id: "chat-1", title: "Plaint", role: "Litigator", model: "fast", updatedAtRaw: "2026-10-03 06:30:00")
        let stored = [
            Data(#"{"role":"user","content":"Q","attachments":[{"name":"a.pdf"}]}"#.utf8),
            Data(#"{"role":"assistant","content":"old","done":true,"workLog":[]}"#.utf8),
        ]
        let body = try XCTUnwrap(DraftEditSync.body(
            userID: "42", chat: chat, storedMessages: stored, index: 1, content: "new </p> \"q\""))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix(#"{"userId":"42","chats":[{"#), text)
        XCTAssertTrue(text.hasSuffix(#"""
            "messages":[{"role":"user","content":"Q","attachments":[{"name":"a.pdf"}]},{"role":"assistant","content":"new </p> \"q\"","done":true,"workLog":[]}]}]}
            """#), "the stored bytes, the one content replaced")
        let head = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["chats"] as? [[String: Any]])
        XCTAssertEqual(head.first?["id"] as? String, "chat-1")
        XCTAssertEqual(head.first?["title"] as? String, "Plaint")
        XCTAssertEqual(head.first?["role"] as? String, "Litigator")
        XCTAssertEqual(head.first?["model"] as? String, "fast")
        XCTAssertEqual(head.first?["updatedAt"] as? String, "2026-10-03 06:30:00")
        XCTAssertNil(DraftEditSync.body(userID: "42", chat: chat, storedMessages: stored, index: 2, content: "x"))
    }
}
