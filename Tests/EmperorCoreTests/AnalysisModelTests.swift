import XCTest
@testable import EmperorCore

/// Results as the platform's repair step (`lib/analysis/schemas.js`) sends them: every field it
/// always fills is filled, and the optional ones appear in some places and not others.
enum AnalysisFixtures {

    static let docIndex = #"""
    {"label":"Our pleadings bundle","rationale":"A court file, so there is an annexure column.",
     "filterKey":"type","filterLabel":"Type",
     "flag":{"key":"issues","nonEmpty":true,"label":"with an issue to watch"},
     "columns":[
      {"key":"sr","label":"Sr.","type":"number","width":76,"pin":true,"description":"Serial number."},
      {"key":"doc","label":"Document","type":"text","width":252,"pin":true,"strong":true,"description":"Its name."},
      {"key":"type","label":"Type","type":"badge","width":142,"tones":{"Pleading":"accent","Contract":"info"},"description":""},
      {"key":"date","label":"Date","type":"date","width":120,"description":""},
      {"key":"pages","label":"Pages","type":"pages","width":86,"total":true,"description":""},
      {"key":"claim","label":"Amount","type":"amount","width":150,"total":true,"description":""},
      {"key":"terms","label":"Key terms","type":"tags","width":260,"description":""},
      {"key":"relevance","label":"Relevance","type":"badge","width":140,"order":["High","Medium","Low"],"description":""},
      {"key":"issues","label":"Issues to watch","type":"long","width":330,"description":""}
     ],
     "rows":[
      {"id":"r1","sr":1,"doc":"Plaint with verification","type":"Pleading","date":"2025-03-06","pages":54,
       "claim":48200000,"terms":["18% interest","Cl. 22 arbitration"],"relevance":"High",
       "issues":"Para 31 claims 18% interest."},
      {"id":"r2","sr":2,"doc":"Power Purchase Agreement","type":"Contract","date":"Aug 2021","pages":1,
       "claim":null,"terms":null,"relevance":"Medium","issues":null},
      {"id":"r3","sr":3,"doc":"Vakalatnama","type":"Pleading","date":null,"pages":2,
       "claim":1250.5,"terms":["Signed by MD"],"relevance":"Low","issues":null}
     ]}
    """#

    static let listOfDates = #"""
    {"matter":{"title":"Helios v. Northgrid","number":"CS(COMM) 412/2025","forum":"High Court of Delhi"},
     "parties":{"ours":"Helios","other":"Northgrid"},
     "entries":[
      {"id":"e1","day":"1963","cat":"rules","short":"Limitation Act","text":"The **Limitation Act, 1963** gives three years.","label":"1963"},
      {"id":"e2","day":"2021-08-14","cat":"rules","short":"PPA signed","text":"**Cl. 22**: disputes go to arbitration."},
      {"id":"e3","day":"2021-08-14","cat":"ours","short":"Helios signs","text":"Helios signs the **PPA** (**Annexure P-1**)."},
      {"id":"e4","day":"2023-05","cat":"adverse","short":"Northgrid stops paying","text":"Northgrid stops paying."},
      {"id":"e5","day":"2023-07-01","cat":"others","short":"Bank guarantee","text":"The bank refuses to pay."},
      {"id":"e6","day":"2099-01-10","cat":"others","short":"Next hearing","text":"Next hearing.","upcoming":true},
      {"id":"e7","day":"","cat":"adverse","short":"Undated reply","text":"A reply with no date."}
     ],
     "inSum":"Helios **performed**; Northgrid did not pay.",
     "limitation":{"headline":"Last payment 28 Mar 2023 → 3 years end 28 Mar 2026","note":"Section 18 may extend it."}}
    """#

    static let listOfDatesBare = #"""
    {"matter":{"title":"","number":"","forum":""},"parties":{"ours":"","other":""},
     "entries":[{"id":"e1","day":"2024-02-02","cat":"ours","short":"Filed","text":"Filed."}],
     "inSum":"Filed."}
    """#

    static let devilsAdvocate = #"""
    {"matter":{"title":"Helios v. Northgrid","forum":"High Court of Delhi","number":"CS(COMM) 412/2025","client":"Helios"},
     "exposureScore":58,
     "oneMinute":["The arbitration clause is the danger.","The emails need a certificate."],
     "weakSpots":[
      {"id":1,"severity":"serious","category":"contract","likelihood":5,"impact":5,"title":"Arbitration clause",
       "why":"Cl. 22 sends disputes to arbitration.","where":["PPA cl. 22","Plaint para 40"],"say":"This court has no jurisdiction.","fix":"Plead waiver."},
      {"id":2,"severity":"serious","category":"evidence","likelihood":4,"impact":4,"title":"No 65B certificate",
       "why":"Emails without it may be shut out.","where":[],"say":"","fix":"File the certificate."},
      {"id":3,"severity":"moderate","category":"relief","likelihood":3,"impact":3,"title":"Interest at 18%",
       "why":"The PPA allows 12%.","where":["PPA cl. 19.2"],"say":"Inflated.","fix":"Amend to 12%."},
      {"id":4,"severity":"minor","category":"contract","likelihood":2,"impact":2,"title":"Unsigned schedule",
       "why":"Sch. IV is not initialled.","where":["Sch. IV"],"say":"Not proved.","fix":"Get the original."}
     ],
     "questions":[
      {"q":"Why not arbitrate?","why":"Cl. 22.","answer":"Waiver by conduct.","readiness":"work","spot":1},
      {"q":"Where is the certificate?","why":"Section 63.","answer":"Being filed.","readiness":"gap","spot":2},
      {"q":"When was the last payment?","why":"Limitation.","answer":"28 Mar 2023.","readiness":"ready"}
     ],
     "docGaps":[{"doc":"65B certificate","who":"Helios IT","how":"Ask the IT head","when":"Before the next hearing","spot":2}],
     "authorities":[
      {"name":"Vidya Drolia v. Durga Trading","court":"Supreme Court","year":"2020","holds":"Arbitrability.","distinguish":"Waiver.","verify":true,"pinCite":"para 154","against":1},
      {"name":"Limitation Act, 1963, s. 18","court":"","year":"","holds":"Acknowledgment extends time.","distinguish":"","verify":false}
     ],
     "checklist":[{"id":"c1","text":"File the 65B certificate","done":false},{"id":"c2","text":"Amend interest","done":true}]}
    """#

    static func value(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }
}

final class AnalysisModelTests: XCTestCase {

    private func docIndex() throws -> DocIndexResult {
        guard case .docIndex(let r) = try AnalysisResult.decode(AnalysisFixtures.value(AnalysisFixtures.docIndex), tool: .docIndex)
        else { throw XCTSkip("wrong case") }
        return r
    }

    private func listOfDates(_ json: String = AnalysisFixtures.listOfDates) throws -> ListOfDatesResult {
        guard case .listOfDates(let r) = try AnalysisResult.decode(AnalysisFixtures.value(json), tool: .listOfDates)
        else { throw XCTSkip("wrong case") }
        return r
    }

    private func devilsAdvocate() throws -> DevilsAdvocateResult {
        guard case .devilsAdvocate(let r) = try AnalysisResult.decode(AnalysisFixtures.value(AnalysisFixtures.devilsAdvocate), tool: .devilsAdvocate)
        else { throw XCTSkip("wrong case") }
        return r
    }

    // MARK: - Tools

    func testTheToolIdsAreTheWiresAndHighlighterIsNotOffered() {
        XCTAssertEqual(AnalysisJobTool.allCases.map(\.rawValue), ["devils-advocate", "doc-index", "list-of-dates"])
        XCTAssertEqual(AnalysisJobTool.maxFiles, 10)
        XCTAssertEqual(AnalysisJobTool.maxReferenceLength, 2000)
        XCTAssertNil(AnalysisJobTool(rawValue: "highlighter"))
    }

    // MARK: - Doc Index

    func testADocIndexDecodesWithItsDynamicColumns() throws {
        let index = try docIndex()
        XCTAssertEqual(index.label, "Our pleadings bundle")
        XCTAssertEqual(index.columns.count, 9)
        XCTAssertEqual(index.rows.count, 3)
        XCTAssertEqual(index.strongColumn.key, "doc")
        XCTAssertFalse(index.detailColumns.contains { $0.key == "doc" })
        XCTAssertEqual(index.columns[2].tones?["Pleading"], .accent)
        XCTAssertEqual(index.columns[7].order ?? [], ["High", "Medium", "Low"])
        XCTAssertTrue(index.columns[4].total)
        XCTAssertFalse(index.columns[2].total)
        XCTAssertEqual(index.flag?.nonEmpty, true)
        XCTAssertEqual(index.title(of: index.rows[0]), "Plaint with verification")
        XCTAssertEqual(DocIndexResult.id(of: index.rows[1], at: 1), "r2")
    }

    func testEachCellIsDrawnByItsColumnType() throws {
        let index = try docIndex()
        func col(_ key: String) -> DocIndexResult.Column { index.columns.first { $0.key == key }! }
        let plaint = index.rows[0], ppa = index.rows[1], vakalat = index.rows[2]

        XCTAssertEqual(index.cell(plaint, col("sr")), "1")
        XCTAssertEqual(index.cell(plaint, col("claim")), "₹4,82,00,000")
        XCTAssertEqual(index.cell(vakalat, col("claim")), "₹1,250.50")
        XCTAssertEqual(index.cell(plaint, col("pages")), "54 pages")
        XCTAssertEqual(index.cell(ppa, col("pages")), "1 page")
        XCTAssertEqual(index.cell(plaint, col("terms")), "18% interest; Cl. 22 arbitration")
        XCTAssertEqual(index.tags(plaint, col("terms")), ["18% interest", "Cl. 22 arbitration"])
        // A day the server read is written out, as a day in India; anything else as written.
        XCTAssertEqual(index.cell(plaint, col("date")), "Thursday, 6 March 2025")
        XCTAssertEqual(index.cell(ppa, col("date")), "Aug 2021")
        XCTAssertNil(index.cell(vakalat, col("date")))
        XCTAssertNil(index.cell(ppa, col("terms")))
        XCTAssertNil(index.cell(ppa, col("claim")))
    }

    func testBadgeTonesComeFromTheServerElseFromTheWord() throws {
        let index = try docIndex()
        let type = index.columns[2], relevance = index.columns[7]
        XCTAssertEqual(index.tone(for: "Contract", in: type), .info)
        XCTAssertEqual(index.tone(for: "High", in: relevance), .danger)
        XCTAssertEqual(index.tone(for: "Medium", in: relevance), .warn)
        XCTAssertEqual(index.tone(for: "Low", in: relevance), .neutral)
    }

    func testTheSummaryCountsDocumentsPagesAndFlags() throws {
        let index = try docIndex()
        XCTAssertEqual(index.totalPages, 57)
        XCTAssertEqual(index.flaggedCount, 1)
        XCTAssertTrue(index.isFlagged(index.rows[0]))
        XCTAssertFalse(index.isFlagged(index.rows[1]))
        XCTAssertEqual(index.summaryLine, "3 documents · 57 pages in all · 1 with an issue to watch")
    }

    func testAFlagByValueMatchesOnlyThoseValues() {
        let index = DocIndexResult(
            label: "x", flag: .init(key: "risk", values: ["Red"], label: "red"),
            columns: [.init(key: "doc", label: "Doc", type: .text, strong: true), .init(key: "risk", label: "Risk", type: .badge)],
            rows: [["doc": .string("a"), "risk": .string("Red")], ["doc": .string("b"), "risk": .string("Green")]])
        XCTAssertEqual(index.flaggedCount, 1)
    }

    func testTheFilterListsValuesInFirstAppearanceOrderWithCounts() throws {
        let index = try docIndex()
        XCTAssertEqual(index.filterOptions, [.init(value: "Pleading", count: 2), .init(value: "Contract", count: 1)])
        XCTAssertEqual(index.rows(matching: "Pleading").count, 2)
        XCTAssertEqual(index.rows(matching: nil).count, 3)
    }

    func testTheIndexAsTextNamesEachDocumentAndItsFilledColumns() throws {
        let text = try docIndex().plainText
        XCTAssertTrue(text.hasPrefix("DOC INDEX: Our pleadings bundle\n3 documents"))
        XCTAssertTrue(text.contains("1. Plaint with verification\n   Sr.: 1\n   Type: Pleading"))
        XCTAssertTrue(text.contains("   Amount: ₹4,82,00,000"))
        XCTAssertFalse(text.contains("Key terms: \n"))
    }

    func testADocIndexWithoutRowsOrWithAnUnknownTypeIsAContractBreak() {
        let noRows = #"{"label":"x","rationale":"","columns":[{"key":"a","label":"A","type":"text","width":1,"description":""},{"key":"b","label":"B","type":"text","width":1,"description":""}],"rows":[]}"#
        let badType = AnalysisFixtures.docIndex.replacingOccurrences(of: #""type":"long""#, with: #""type":"paragraph""#)
        for json in [noRows, badType] {
            XCTAssertThrowsError(try AnalysisResult.decode(AnalysisFixtures.value(json), tool: .docIndex)) { error in
                guard case .decoding? = error as? APIError else { return XCTFail("expected .decoding, got \(error)") }
            }
        }
    }

    // MARK: - List of Dates

    func testAListOfDatesDecodesWithItsOptionalParts() throws {
        let list = try listOfDates()
        XCTAssertEqual(list.entries.count, 7)
        XCTAssertEqual(list.limitation?.headline, "Last payment 28 Mar 2023 → 3 years end 28 Mar 2026")
        XCTAssertEqual(list.entries[0].label, "1963")
        XCTAssertTrue(list.entries[5].upcoming)
        XCTAssertFalse(list.entries[4].upcoming)

        let bare = try listOfDates(AnalysisFixtures.listOfDatesBare)
        XCTAssertNil(bare.limitation)
        XCTAssertEqual(bare.matterLine, "")
    }

    func testRulesAndEventsAreSeparatedAndEventsGroupedByYearUndatedLast() throws {
        let list = try listOfDates()
        XCTAssertEqual(list.rules.map(\.id), ["e1", "e2"])
        XCTAssertEqual(list.events.map(\.id), ["e3", "e4", "e5", "e6", "e7"])
        XCTAssertEqual(list.eventsByYear.map(\.year), ["2021", "2023", "2099", "Undated"])
        XCTAssertEqual(list.eventsByYear[1].entries.map(\.id), ["e4", "e5"])
        XCTAssertEqual(list.upcoming.map(\.id), ["e6"])
    }

    func testDatesReadTheWayTheWebWritesThem() throws {
        let list = try listOfDates()
        let byID = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.id, $0) })
        XCTAssertEqual(byID["e1"]?.dateLabel, "1963")
        XCTAssertEqual(byID["e3"]?.dateLabel, "14.08.2021")
        XCTAssertEqual(byID["e4"]?.dateLabel, "May 2023")
        XCTAssertEqual(byID["e7"]?.dateLabel, "Undated")
        XCTAssertEqual(byID["e3"]?.fullDate, "14 Aug 2021")
        XCTAssertEqual(byID["e4"]?.fullDate, "May 2023")
        XCTAssertEqual(byID["e7"]?.fullDate, "Undated")
    }

    func testSidesAreNamedForThePartiesWhenTheResultNamesThem() throws {
        let list = try listOfDates()
        XCTAssertEqual(list.sideTag(.ours), "Helios (ours)")
        XCTAssertEqual(list.sideTag(.adverse), "Northgrid (adverse)")
        XCTAssertEqual(list.sideName(.ours), "Helios’s own acts")
        let bare = try listOfDates(AnalysisFixtures.listOfDatesBare)
        XCTAssertEqual(bare.sideTag(.ours), "Our side")
        XCTAssertEqual(bare.sideTag(.adverse), "Other side (adverse)")
    }

    func testTheSummaryCountsEachSideAndTheSpan() throws {
        let s = try listOfDates().summary
        XCTAssertEqual(s.events, 5)
        XCTAssertEqual(s.rules, 2)
        XCTAssertEqual(s.ours, 1)
        XCTAssertEqual(s.others, 2)
        XCTAssertEqual(s.adverse, 2)
        XCTAssertEqual(s.span, "2021 → 2099")
        XCTAssertEqual(try listOfDates().matterLine, "Helios v. Northgrid | CS(COMM) 412/2025, High Court of Delhi")
    }

    func testBoldIsSplitIntoRunsAndStrippedForText() throws {
        XCTAssertEqual(RichRun.runs("Helios signs the **PPA** (**Annexure P-1**)."), [
            .init(text: "Helios signs the ", bold: false), .init(text: "PPA", bold: true),
            .init(text: " (", bold: false), .init(text: "Annexure P-1", bold: true), .init(text: ").", bold: false),
        ])
        // An unmatched marker is dropped, not shown.
        XCTAssertEqual(RichRun.runs("a **b** c ** d"), [
            .init(text: "a ", bold: false), .init(text: "b", bold: true), .init(text: " c  d", bold: false),
        ])
        XCTAssertEqual(RichRun.runs("plain"), [.init(text: "plain", bold: false)])
        XCTAssertEqual(RichRun.runs(""), [])
        XCTAssertEqual(try listOfDates().entries[2].plainText, "Helios signs the PPA (Annexure P-1).")
    }

    func testTheListAsTextHasRulesEventsBySideAndInSum() throws {
        let text = try listOfDates().plainText
        XCTAssertTrue(text.contains("Helios v. Northgrid | CS(COMM) 412/2025, High Court of Delhi"))
        XCTAssertTrue(text.contains("Limitation watch: Last payment"))
        XCTAssertTrue(text.contains("RULES, CONTRACT TERMS & ORDERS (as they came)\n1963: The Limitation Act, 1963 gives three years."))
        XCTAssertTrue(text.contains("2021\n14.08.2021 [Helios (ours)]: Helios signs the PPA (Annexure P-1)."))
        XCTAssertTrue(text.contains("Undated\nUndated [Northgrid (adverse)]: A reply with no date."))
        XCTAssertTrue(text.hasSuffix("In sum: Helios performed; Northgrid did not pay.\n"))
        XCTAssertFalse(text.contains("**"))
    }

    func testAListWithNoDatedEventOrAnUnknownSideIsAContractBreak() {
        let onlyRules = #"{"matter":{"title":"","number":"","forum":""},"parties":{"ours":"","other":""},"entries":[{"id":"e1","day":"2020","cat":"rules","short":"x","text":"x"}],"inSum":"x"}"#
        let badCat = AnalysisFixtures.listOfDatesBare.replacingOccurrences(of: #""cat":"ours""#, with: #""cat":"client""#)
        let noSum = AnalysisFixtures.listOfDatesBare.replacingOccurrences(of: #""inSum":"Filed.""#, with: #""other":1"#)
        XCTAssertNotEqual(noSum, AnalysisFixtures.listOfDatesBare)
        XCTAssertNotEqual(badCat, AnalysisFixtures.listOfDatesBare)
        for json in [onlyRules, badCat, noSum] {
            XCTAssertThrowsError(try AnalysisResult.decode(AnalysisFixtures.value(json), tool: .listOfDates))
        }
    }

    // MARK: - Devil's Advocate

    func testAReportDecodesEverySection() throws {
        let r = try devilsAdvocate()
        XCTAssertEqual(r.exposureScore, 58)
        XCTAssertEqual(r.weakSpots.map(\.id), [1, 2, 3, 4])
        XCTAssertEqual(r.weakSpots[0].where, ["PPA cl. 22", "Plaint para 40"])
        XCTAssertEqual(r.questions[2].spot, nil)
        XCTAssertEqual(r.docGaps[0].spot, 2)
        XCTAssertEqual(r.authorities[0].pinCite, "para 154")
        XCTAssertEqual(r.authorities[0].whereLine, "Supreme Court, 2020 · para 154")
        XCTAssertEqual(r.authorities[1].whereLine, "")
        XCTAssertNil(r.authorities[1].against)
        XCTAssertEqual(r.checklist.map(\.done), [false, true])
        XCTAssertEqual(r.spot(2)?.title, "No 65B certificate")
        XCTAssertNil(r.spot(9))
    }

    /// The web's `exposureBand`: `score < 34 ? 'Low' : score < 67 ? 'Moderate' : 'High'`.
    func testTheExposureBandIsTheWebs() throws {
        var r = try devilsAdvocate()
        for (score, band) in [(0, "Low"), (33, "Low"), (34, "Moderate"), (58, "Moderate"), (66, "Moderate"), (67, "High"), (100, "High")] {
            r.exposureScore = score
            XCTAssertEqual(r.band.rawValue, band, "score \(score)")
        }
    }

    func testCountsAndBarsAreDerivedFromTheSpots() throws {
        let r = try devilsAdvocate()
        XCTAssertEqual(r.severityLine, "2 serious, 1 moderate, 1 minor")
        XCTAssertEqual(r.categoryRows.map(\.category), [.contract, .evidence, .relief])
        XCTAssertEqual(r.categoryRows[0].weight, 4)
        XCTAssertEqual(r.categoryRows[0].count, 2)
        XCTAssertEqual(r.count(.ready), 1)
        XCTAssertEqual(r.count(.work), 1)
        XCTAssertEqual(r.count(.gap), 1)
        XCTAssertEqual(r.questions(.gap).map(\.q), ["Where is the certificate?"])
        XCTAssertEqual(r.questions(nil).count, 3)
        XCTAssertEqual(r.matterFacts.map(\.label), ["Forum", "Matter", "Prepared for"])
    }

    func testTheReportAsTextKeepsTheVerifyWarningAndEverySection() throws {
        let text = try devilsAdvocate().plainText
        XCTAssertTrue(text.contains("Overall exposure: Moderate (58 of 100) — 2 serious, 1 moderate, 1 minor"))
        XCTAssertTrue(text.contains("#1 [Serious · Contract terms] Arbitration clause"))
        XCTAssertTrue(text.contains("What they will say: “This court has no jurisdiction.”"))
        XCTAssertTrue(text.contains("See e.g. Vidya Drolia v. Durga Trading (Supreme Court, 2020 · para 154) [Verify before citing: not found in your papers]"))
        XCTAssertTrue(text.contains("See e.g. Limitation Act, 1963, s. 18\n"))
        XCTAssertTrue(text.contains("[x] Amend interest"))
        XCTAssertTrue(text.contains("A first draft to check, not advice."))
    }

    func testAReportWithoutWeakSpotsOrWithAnUnknownSeverityIsAContractBreak() {
        let base = AnalysisFixtures.devilsAdvocate
        let badSeverity = base.replacingOccurrences(of: #""severity":"minor""#, with: #""severity":"low""#)
        let noGaps = base.replacingOccurrences(of: #""docGaps":[{"doc":"65B certificate","who":"Helios IT","how":"Ask the IT head","when":"Before the next hearing","spot":2}],"#, with: "")
        let outOfRange = base.replacingOccurrences(of: #""exposureScore":58"#, with: #""exposureScore":140"#)
        XCTAssertNotEqual(noGaps, base)
        for json in [badSeverity, noGaps, outOfRange] {
            XCTAssertThrowsError(try AnalysisResult.decode(AnalysisFixtures.value(json), tool: .devilsAdvocate))
        }
    }

    func testAResultOfOneToolDoesNotReadAsAnother() {
        XCTAssertThrowsError(try AnalysisResult.decode(AnalysisFixtures.value(AnalysisFixtures.docIndex), tool: .listOfDates))
    }

    // MARK: - History rows

    func testAHistoryRowIsTitledByItsTitleElseItsFirstFile() throws {
        let json = #"{"id":"anr_1","tool":"doc-index","title":"","createdAt":"2026-10-16T09:30:00.000Z","fileNames":["My_Plaint.pdf","b.pdf","c.pdf","d.pdf"],"reference":"","usage":null}"#
        let row = try JSONDecoder().decode(AnalysisRunSummary.self, from: Data(json.utf8))
        XCTAssertEqual(row.tool, .docIndex)
        XCTAssertEqual(row.displayTitle, "My Plaint.pdf")
        XCTAssertEqual(row.fileLine, "My Plaint.pdf, b.pdf +2")
        XCTAssertNotNil(row.createdDate)
        XCTAssertEqual(AnalysisRunSummary(id: "x", tool: .listOfDates).displayTitle, "Untitled run")
    }

    func testTheProvenanceLineIsTheWebs() {
        let r = AnalysisResult.listOfDates(ListOfDatesResult(entries: [], inSum: ""))
        var outcome = AnalysisOutcome(result: r, fileNames: ["a.pdf", "b.pdf", "c.pdf"], reference: "note")
        XCTAssertEqual(outcome.provenance, "Read 3 documents: a.pdf, b.pdf and 1 more · with your note")
        outcome.fileNames = ["a.pdf"]
        outcome.reference = ""
        XCTAssertEqual(outcome.provenance, "Read 1 document: a.pdf")
    }
}
