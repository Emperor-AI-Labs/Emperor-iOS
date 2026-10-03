import XCTest
@testable import EmperorCore

/// A free function rather than a method: an `XCTestCase` is not `Sendable`, so calling an instance
/// helper from a `@MainActor` closure makes Swift 6 reject the capture of `self`.
@MainActor
private func withWorkspace(
    _ store: InMemoryPreferenceStore, _ body: @MainActor (LitigatorWorkspaceModel) -> Void
) {
    body(LitigatorWorkspaceModel(store: store))
}

private func matter(_ id: String) -> LitigatorMatter {
    LITIGATOR_MATTERS.first { $0.id == id }!
}

/// The Litigator workspace: the taxonomy's rules, its ids, the remembered matter, and what the
/// screen is given to lay out.
///
/// The class is deliberately **not** `@MainActor`: Linux XCTest cannot cast a `@MainActor` test
/// method and aborts the entire run. The view model is reached through `withWorkspace`.
final class LitigatorWorkspaceTests: XCTestCase {

    // MARK: - sectionsFor

    /// A writ and a civil appeal never go to trial, and only a suit frames issues.
    func testACivilProceedingHidesTheStagesItNeverReaches() {
        let all = LitigatorDrafting.sections(for: "civil").map(\.key)
        XCTAssertEqual(all, [
            "initiating", "reply", "issues", "evidence", "cross", "arguments", "applications",
            "civil-appeals", "common",
        ])

        XCTAssertEqual(LitigatorDrafting.sections(for: "civil", proceeding: "Suit").map(\.key), all)
        for proceeding in ["Writ petition", "Appeal"] {
            let keys = LitigatorDrafting.sections(for: "civil", proceeding: proceeding).map(\.key)
            XCTAssertFalse(keys.contains("issues"), proceeding)
            XCTAssertFalse(keys.contains("evidence"), proceeding)
            XCTAssertFalse(keys.contains("cross"), proceeding)
            XCTAssertTrue(keys.contains("arguments"), proceeding)
        }
        for proceeding in ["Execution", "Tribunal / special forum"] {
            let keys = LitigatorDrafting.sections(for: "civil", proceeding: proceeding).map(\.key)
            XCTAssertFalse(keys.contains("issues"), "issues are a suit's alone")
            XCTAssertTrue(keys.contains("evidence"), proceeding)
        }
    }

    /// Criminal never lists Issues — none of its documents is a civil one — and an appeal or a
    /// bail matter has no trial in it.
    func testACriminalProceedingHidesTheTrial() {
        let all = LitigatorDrafting.sections(for: "criminal").map(\.key)
        XCTAssertEqual(all, [
            "complaints", "bail", "evidence", "cross", "arguments", "applications", "post-trial",
            "common",
        ])
        for proceeding in ["Appeal / revision", "Bail matter"] {
            let keys = LitigatorDrafting.sections(for: "criminal", proceeding: proceeding).map(\.key)
            XCTAssertFalse(keys.contains("evidence"), proceeding)
            XCTAssertFalse(keys.contains("cross"), proceeding)
        }
        XCTAssertEqual(
            LitigatorDrafting.sections(for: "criminal", proceeding: "Private complaint").map(\.key),
            all)
    }

    /// A shared section keeps only the matter's own documents: Civil's cross-examination has the
    /// re-examination notes and not the accused's statement, and Criminal's the other way round.
    func testASharedSectionKeepsOnlyTheMattersOwnDocuments() {
        let civil = LitigatorDrafting.sections(for: "civil").first { $0.key == "cross" }
        let criminal = LitigatorDrafting.sections(for: "criminal").first { $0.key == "cross" }
        XCTAssertEqual(civil?.items.map(\.id), ["cross-pw", "cross-dw", "re-exam-notes"])
        XCTAssertEqual(criminal?.items.map(\.id), ["cross-pw", "cross-dw", "accused-statement"])
    }

    /// A practice area has its own sections and no proceedings; a proceeding passed anyway is
    /// ignored rather than emptying the list.
    func testAPracticeAreaIgnoresAProceeding() {
        let sections = LitigatorDrafting.sections(for: "arbitration").map(\.key)
        XCTAssertEqual(sections, ["invocation", "interim", "pleadings", "challenge"])
        XCTAssertEqual(
            LitigatorDrafting.sections(for: "arbitration", proceeding: "Appeal").map(\.key),
            sections)
        XCTAssertTrue(LitigatorDrafting.sections(for: "nothing").isEmpty)
    }

    /// An empty proceeding is no proceeding — JavaScript's `!proceeding`.
    func testAnEmptyProceedingIsAnyStage() {
        XCTAssertEqual(
            LitigatorDrafting.sections(for: "civil", proceeding: "").map(\.key),
            LitigatorDrafting.sections(for: "civil").map(\.key))
    }

    // MARK: - Ids

    /// Every id the workspace builds comes back to the document and section it was built from.
    func testEveryIdRoundTrips() {
        var documents = 0
        for matter in LITIGATOR_MATTERS {
            for section in LitigatorDrafting.sections(for: matter.id) {
                let sectionID = LitigatorDrafting.sectionID(matter: matter.id, section: section.key)
                let foundSection = LitigatorDrafting.section(sectionID)
                XCTAssertEqual(foundSection?.matter, matter.id, sectionID)
                XCTAssertEqual(foundSection?.section.key, section.key, sectionID)
                XCTAssertEqual(foundSection?.section.items, section.items, sectionID)

                for item in section.items {
                    let id = LitigatorDrafting.documentID(matter: matter.id, item: item.id)
                    let found = LitigatorDrafting.document(id)
                    XCTAssertEqual(found?.matter, matter.id, id)
                    XCTAssertEqual(found?.item, item, id)
                    XCTAssertEqual(found?.section.key, section.key, id)
                    XCTAssertEqual(LitigatorDrafting.tool(id)?.id, id)
                    documents += 1
                }
            }
        }
        XCTAssertEqual(documents, 175)
    }

    /// The split is at the first dash after the prefix: matter ids never hold one, item ids often
    /// do, and `tax-scn-reply` lives in the `tax` matter as `tax-tax-scn-reply`.
    func testAnItemIdWithDashesSplitsAtTheMatter() {
        XCTAssertEqual(
            LitigatorDrafting.documentID(matter: "tax", item: "tax-scn-reply"),
            "ldoc-tax-tax-scn-reply")
        let found = LitigatorDrafting.document("ldoc-tax-tax-scn-reply")
        XCTAssertEqual(found?.matter, "tax")
        XCTAssertEqual(found?.item.id, "tax-scn-reply")
        XCTAssertEqual(found?.area?.label, "Tax")
        XCTAssertEqual(
            LitigatorDrafting.section("lsec-civil-civil-appeals")?.section.title,
            "Appeals, Revision & Review")
    }

    func testMalformedIdsNameNothing() {
        for id in ["", "ldoc", "ldoc-", "ldoc-civil", "lsec-civil", "plaint", "ldoc-civil-",
                   "LDOC-civil-plaint", "lsec-tax-initiating", "lsec-criminal-issues"] {
            XCTAssertNil(LitigatorDrafting.tool(id), id)
        }
    }

    // MARK: - The title rule

    /// A closing parenthetical comes off the form's title; anything else stays.
    func testTheTitleLosesOnlyAClosingParenthetical() {
        let cases: [(String, String)] = [
            ("Plaint (suit, Order 7)", "Plaint"),
            ("Writ petition (Art. 226/227)", "Writ petition"),
            ("Cross questions — plaintiff / prosecution witnesses (PW1, PW2 …)",
             "Cross questions — plaintiff / prosecution witnesses"),
            // A nested closing bracket cannot match, so the label stays whole — as on the web.
            ("Application u/s 175(3) BNSS to direct FIR / investigation (old 156(3))",
             "Application u/s 175(3) BNSS to direct FIR / investigation (old 156(3))"),
            ("Recovery of dues (s.33C(2))", "Recovery of dues (s.33C(2))"),
            ("Reply to notice (s.142(1)/143(2)/148)", "Reply to notice (s.142(1)/143(2)/148)"),
            // Not at the end.
            ("Anticipatory bail (BNSS 482, old 438) — Sessions / HC",
             "Anticipatory bail (BNSS 482, old 438) — Sessions / HC"),
            ("SARFAESI s.13(4) measure", "SARFAESI s.13(4) measure"),
            // Trailing space after the bracket is part of the match, and the rest is trimmed.
            ("  Plaint (suit)   ", "Plaint"),
            ("Plaint(suit)", "Plaint"),
            // Only the last parenthetical goes.
            ("Bail (BNSS 480) (old 437)", "Bail (BNSS 480)"),
            // A label that is nothing else keeps itself.
            ("(suit)", "(suit)"),
            ("Protest petition", "Protest petition"),
        ]
        for (label, title) in cases {
            XCTAssertEqual(LitigatorDrafting.title(for: label), title, label)
        }
    }

    // MARK: - Framing

    /// A Litigator document is framed as a Litigator document — never in Senior Counsel's voice,
    /// which is where an earlier build sent this role.
    func testALitigatorCardIsFramedAsTheWebFramesAnLdocId() throws {
        let card = RoleCard(
            id: "civil-plaint", role: .litigator, title: "Plaint", subtitle: nil, section: nil,
            output: .document, isSafetyFirst: false, filters: [], dropdown: [], note: "")
        XCTAssertEqual(card.toolID, "ldoc-civil-plaint")
        let viaCard = card.toolSpec.prompt(.empty)
        let viaTaxonomy = try XCTUnwrap(LitigatorDrafting.tool("ldoc-civil-plaint")).prompt(.empty)
        XCTAssertEqual(viaCard, viaTaxonomy)

        let stray = RoleCard(
            id: "nothing-here", role: .litigator, title: "Caveat petition", subtitle: "urgent",
            section: "Common documents", output: .document, isSafetyFirst: false, filters: [],
            dropdown: [], note: "")
        let tool = stray.toolSpec
        let prompt = tool.prompt(.empty)
        XCTAssertTrue(prompt.hasPrefix(
            "The user has asked for: \"Caveat petition\" — a civil matter, common documents stage"))
        XCTAssertTrue(prompt.contains(LitigatorDrafting.codeNote(for: "civil")))
        XCTAssertFalse(prompt.lowercased().contains("senior counsel"))
        XCTAssertEqual(tool.blurb, "Civil · Common documents — urgent")
        XCTAssertEqual(tool.inputs.map(\.key), ["forum", "parties", "facts", "relief"])
    }

    /// One lookup for every workspace: the taxonomy's two prefixes, and the cards.
    func testOneLookupServesEveryWorkspace() {
        XCTAssertEqual(roleTool("ldoc-civil-plaint")?.title, "Plaint")
        XCTAssertEqual(roleTool("lsec-criminal-bail")?.title, "Bail")
        XCTAssertEqual(roleTool("adoc-award-drafting")?.title, "Award Drafting")
        XCTAssertNil(roleTool("ldoc-civil-nothing"))
        XCTAssertNil(roleTool("research"), "a registry tool is not a workspace route")
    }

    /// Litigator's workspace is the taxonomy, every other role's is a deck — so no role opens
    /// onto nothing. Litigator's was empty until this.
    func testNoRolesWorkspaceIsEmpty() {
        for role in PractitionerRole.allCases {
            if role.usesDraftingTaxonomy {
                XCTAssertEqual(role, .litigator)
                XCTAssertTrue(role.cards.isEmpty)
            } else {
                XCTAssertFalse(role.cards.isEmpty, "\(role.label) has no deck")
            }
        }
    }

    // MARK: - The remembered matter

    func testAFreshInstallOpensOnCivil() async {
        let store = InMemoryPreferenceStore()
        XCTAssertEqual(LitigatorMatter.stored(in: store).id, "civil")
        await withWorkspace(store) { model in
            XCTAssertEqual(model.matter.id, "civil")
            XCTAssertNil(model.proceeding)
        }
    }

    func testTheChosenMatterIsRememberedAcrossOpens() async {
        let store = InMemoryPreferenceStore()
        await withWorkspace(store) { model in
            model.select(matter("tax"))
            XCTAssertEqual(model.matter.id, "tax")
        }
        XCTAssertEqual(store.string(for: LitigatorMatter.storageKey), "tax")
        // A second model over the same store is the next time the workspace opens.
        await withWorkspace(store) { model in
            XCTAssertEqual(model.matter.id, "tax")
        }
    }

    /// What a matter retired in a later build, or a downgrade, leaves behind.
    func testAnUnrecognisedStoredMatterFallsBackToTheFirst() async {
        let store = InMemoryPreferenceStore()
        store.setString("maritime", for: LitigatorMatter.storageKey)
        XCTAssertEqual(LitigatorMatter.stored(in: store).id, "civil")
        await withWorkspace(store) { model in
            XCTAssertEqual(model.matter.id, "civil")
            XCTAssertFalse(model.groups.isEmpty)
        }
    }

    // MARK: - The proceeding

    func testChoosingAMatterClearsTheProceeding() async {
        await withWorkspace(InMemoryPreferenceStore()) { model in
            model.select(proceeding: "Writ petition")
            XCTAssertEqual(model.proceeding, "Writ petition")
            model.select(matter("criminal"))
            XCTAssertNil(model.proceeding, "a civil proceeding means nothing to a criminal matter")
            XCTAssertEqual(model.proceedings.first, "State (police/FIR) case")
        }
    }

    /// Only a proceeding this matter offers narrows it.
    func testAProceedingFromElsewhereIsAnyStage() async {
        await withWorkspace(InMemoryPreferenceStore()) { model in
            model.select(proceeding: "Bail matter")
            XCTAssertNil(model.proceeding)
            model.select(matter("ipr"))
            XCTAssertTrue(model.proceedings.isEmpty)
            model.select(proceeding: "Suit")
            XCTAssertNil(model.proceeding)
        }
    }

    /// A section a proceeding hides is named, not just missing.
    func testHiddenSectionsAreNamed() async {
        await withWorkspace(InMemoryPreferenceStore()) { model in
            XCTAssertNil(model.stageNote)
            model.select(proceeding: "Writ petition")
            XCTAssertEqual(model.hiddenSections, ["Issues", "Evidence", "Cross-examination"])
            XCTAssertEqual(
                model.stageNote,
                "Not part of this proceeding: Issues, Evidence and Cross-examination.")
            model.select(proceeding: "Execution")
            XCTAssertEqual(model.stageNote, "Not part of this proceeding: Issues.")
            model.select(proceeding: "Suit")
            XCTAssertNil(model.stageNote, "a suit reaches every stage")
            model.select(proceeding: nil)
            XCTAssertTrue(model.hiddenSections.isEmpty)
        }
    }

    // MARK: - What the screen is given

    /// Never an empty screen: every matter, under every proceeding it offers, has documents.
    func testEveryMatterAndProceedingHasSomethingToShow() async {
        await withWorkspace(InMemoryPreferenceStore()) { model in
            for matter in model.matters {
                model.select(matter)
                for proceeding in [nil] + model.proceedings.map(Optional.some) {
                    model.select(proceeding: proceeding)
                    XCTAssertFalse(model.groups.isEmpty, "\(matter.id) / \(proceeding ?? "any")")
                    XCTAssertGreaterThan(model.documentCount, 0)
                    XCTAssertFalse(model.summary.isEmpty)
                }
            }
        }
    }

    /// Civil, as the screen draws it: its own description, the documents under each heading with
    /// the full label, a note where the platform has one, and the heading form's id.
    func testCivilIsLaidOutAsTheWebLaysItOut() async {
        await withWorkspace(InMemoryPreferenceStore()) { model in
            XCTAssertEqual(model.summary, "Suits, writs, appeals, execution and tribunal matters.")
            XCTAssertEqual(model.documentCount, 42)
            let first = model.groups[0]
            XCTAssertEqual(first.id, "lsec-civil-initiating")
            XCTAssertEqual(first.title, "Pleadings & Petitions")
            XCTAssertEqual(first.summary, "Plaint, Writ petition, Memorandum of appeal & more")
            XCTAssertEqual(first.anyDocumentLabel, "Any document in Pleadings & Petitions…")
            XCTAssertEqual(first.documents.first?.id, "ldoc-civil-plaint")
            XCTAssertEqual(first.documents.first?.label, "Plaint (suit, Order 7)")
            XCTAssertNil(first.documents.first?.note)
            XCTAssertEqual(first.documents[1].note, "with synopsis + list of dates")
        }
    }

    /// A practice area has no description on the web, so the line names its sections.
    func testAPracticeAreaIsSummarisedByItsSections() async {
        await withWorkspace(InMemoryPreferenceStore()) { model in
            model.select(matter("arbitration"))
            XCTAssertEqual(
                model.summary,
                "Invocation & Reference · Interim Measures · Pleadings · Challenge & Enforcement")
            XCTAssertEqual(model.documentCount, 16)
            XCTAssertEqual(model.groups.first?.documents.first?.id, "ldoc-arbitration-arb-s21-notice")
        }
    }

    /// The chips use the compact names where the platform has them.
    func testChipsUseTheCompactNames() {
        XCTAssertEqual(LITIGATOR_MATTERS.map(\.chipLabel), [
            "Civil", "Criminal", "IPR", "Tax", "Banking", "Arbitration", "Cyber", "Labour",
            "Property", "Corporate", "Constitutional", "International",
        ])
        XCTAssertFalse(matter("civil").isPracticeArea)
        XCTAssertTrue(matter("company").isPracticeArea)
    }

    /// Every matter has a symbol of its own — a new one from the platform would otherwise draw
    /// the generic document, and two that shared one could not be told apart at a glance.
    func testEveryMatterHasItsOwnSymbol() {
        let symbols = LITIGATOR_MATTERS.map(\.systemImage)
        XCTAssertFalse(symbols.contains("doc.text"), "a matter has no symbol of its own")
        XCTAssertEqual(Set(symbols).count, symbols.count, "two matters share a symbol")
    }
}
