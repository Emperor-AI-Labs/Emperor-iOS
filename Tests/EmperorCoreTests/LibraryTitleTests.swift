import XCTest
@testable import EmperorCore

// The Library's pure helpers, each held to the web's reading of the same input
// (coverTheme.js, books/bookFormat.js, acts/actText.js, caselaw/courts.js, readerModel.js).

private func doc(_ id: Int, _ title: String? = nil, category: String = "case-law") -> CatalogueDocument {
    CatalogueDocument(id: id, title: title, category: category)
}

final class LibraryTitleTests: XCTestCase {

    func testTheHashMatchesTheWebsFNV1a() {
        // FNV-1a of "a" (0x61): (0x811c9dc5 ^ 0x61) * 0x01000193 mod 2^32.
        XCTAssertEqual(LibraryTitles.hashOf("a"), 0xE40C292C)
        XCTAssertEqual(LibraryTitles.hashOf(""), 0x811C9DC5)
        XCTAssertEqual(LibraryTitles.hashOf(42), LibraryTitles.hashOf("42"))
    }

    func testJunkTitlesAreNotTitles() {
        for junk in ["View", "PDF (6.19 MB)", "Accessible_(PDF 1.47MB)", "download", "3f2a1b-9c8-77d", "(0.19 MB)", ""] {
            XCTAssertEqual(LibraryTitles.cleanTitle(junk), "", junk)
        }
        XCTAssertEqual(LibraryTitles.cleanTitle("( 4) Do PT, Rules, 1990 (PDF 1.2MB)"), "Do PT, Rules, 1990")
        XCTAssertEqual(LibraryTitles.cleanTitle("'motor vehicles act, 1988"), "Motor vehicles act, 1988")
        XCTAssertEqual(LibraryTitles.cleanTitle("THE CODE OF CRIMINAL PROCEDURE, 1973"), "The Code of Criminal Procedure, 1973")
        XCTAssertEqual(LibraryTitles.cleanTitle("(Unbalanced bracket"), "Unbalanced bracket")
    }

    func testTidyTitlePrefersTheServersThenFallsBack() {
        var d = doc(1, "Accessible_(PDF 0.97MB)", category: "law-commission-reports")
        d.displayTitle = "Law Commission of India — Report No. 277 (2018)"
        XCTAssertEqual(LibraryTitles.tidyTitle(d), "Law Commission of India — Report No. 277 (2018)")
        d.displayTitle = nil
        d.reference = "Report No. 277"
        XCTAssertEqual(LibraryTitles.tidyTitle(d), "Report No. 277")
        d.reference = nil
        d.series = "Calcutta Law Journal"
        d.volume = "12"
        XCTAssertEqual(LibraryTitles.tidyTitle(d), "Calcutta Law Journal, vol. 12")
        d.series = nil
        d.year = 2010
        XCTAssertEqual(LibraryTitles.tidyTitle(d), "Law Commission report, 2010")
        XCTAssertTrue(LibraryTitles.isUntitled(d))
    }

    func testShortDaysAndCounts() {
        XCTAssertEqual(LibraryTitles.shortDay("1979-05-04"), "4 May 1979")
        XCTAssertEqual(LibraryTitles.shortDay("2026-02-20T00:00:00Z"), "20 Feb 2026")
        XCTAssertEqual(LibraryTitles.shortDay("yesterday"), "yesterday")
        XCTAssertEqual(LibraryTitles.shortDay(nil), "")
        XCTAssertEqual(LibraryTitles.count(271_480), "2,71,480")
    }

    func testCoverFieldsPerCollection() {
        var judgment = doc(1, "Seethamma vs State Of Karnataka on 4 May, 1979")
        judgment.courtLabel = "Karnataka High Court"
        judgment.decidedOn = "1979-05-04"
        judgment.neutralCitation = "1979 KHC 12"
        let f = LibraryTitles.coverFields(judgment)
        XCTAssertEqual(f.kicker, "Karnataka High Court")
        XCTAssertNil(f.title)
        XCTAssertEqual(f.parties?.0, "Seethamma")
        XCTAssertEqual(f.parties?.1, "State Of Karnataka on 4 May, 1979")
        XCTAssertEqual(f.foot, ["4 May 1979", "1979 KHC 12"])

        var act = doc(2, "Indian Penal Code, 1860", category: "bare-acts")
        act.year = 1860
        let a = LibraryTitles.coverFields(act)
        XCTAssertEqual(a.kicker, "Central")
        XCTAssertEqual(a.title, "Indian Penal Code, 1860")
        XCTAssertEqual(a.foot, ["1860"])

        var book = doc(3, "Calcutta Law Journal Vol 91", category: "books-and-law-reports")
        book.series = "Calcutta Law Journal"
        book.volume = "91"
        book.year = 1953
        XCTAssertEqual(LibraryTitles.coverFields(book).kicker, "Calcutta Law Journal")
        XCTAssertEqual(LibraryTitles.coverFields(book).foot, ["Vol. 91", "1953"])
    }

    func testMetaLinesPerCollection() {
        var judgment = doc(1, "A vs B")
        judgment.courtLabel = "Delhi High Court"
        judgment.decidedOn = "2024-01-05"
        judgment.caseType = "W.P.(C)"
        judgment.caseNumber = "1234/2024"
        XCTAssertEqual(LibraryTitles.meta(judgment), ["Delhi High Court", "5 Jan 2024", "W.P.(C) 1234/2024"])
        var act = doc(2, "IPC", category: "bare-acts")
        act.hasChildren = 4
        act.year = 1860
        XCTAssertEqual(LibraryTitles.meta(act), ["Central", "1860", "4 related"])
    }

    func testTheClothIsStablePerDocumentAndSharedByASeries() {
        var a = doc(1, "A", category: "books-and-law-reports")
        var b = doc(2, "B", category: "books-and-law-reports")
        a.series = "Calcutta Law Journal"
        b.series = "calcutta law journal"
        XCTAssertEqual(LibraryTitles.cloth(a), LibraryTitles.cloth(b), "volumes of one series are bound alike")
        XCTAssertEqual(LibraryTitles.cloth(doc(7)), LibraryTitles.cloth(doc(7)))
        XCTAssertTrue(LibraryTitles.cloth(doc(7)).hasPrefix("#"))
    }

    func testShelfWorthiness() {
        var d = doc(1, "Life Cycle Fund 2056", category: "books-and-law-reports")
        d.year = 2056
        XCTAssertFalse(LibraryTitles.isShelfWorthy(d, thisYear: 2026))
        d.year = 2020
        XCTAssertTrue(LibraryTitles.isShelfWorthy(d, thisYear: 2026))
        d.anomalies = ["future_year"]
        XCTAssertFalse(LibraryTitles.isShelfWorthy(d, thisYear: 2026))
        XCTAssertFalse(LibraryTitles.isShelfWorthy(doc(2, "'quoted"), thisYear: 2026))
    }
}

final class LibraryBooksFormatTests: XCTestCase {

    func testVolumeLabels() {
        var v = doc(1, "CLJ", category: "books-and-law-reports")
        v.volume = "Vol-02"
        v.year = 1987
        XCTAssertEqual(LibraryBooksFormat.volumeLabel(v)?.top, "Vol. 2")
        XCTAssertEqual(LibraryBooksFormat.volumeLabel(v)?.bottom, "1987")
        v.volume = "xxxiv"
        XCTAssertEqual(LibraryBooksFormat.volumeLabel(v)?.top, "Vol. XXXIV")
        v.volume = "Iiird"
        XCTAssertEqual(LibraryBooksFormat.volumeLabel(v)?.top, "Vol. III")
        v.volume = nil
        v.year = nil
        v.issue = "615"
        XCTAssertEqual(LibraryBooksFormat.volumeLabel(v)?.top, "No. 615")
        var report = doc(2, "LC", category: "law-commission-reports")
        report.reportNo = 277
        report.year = 2018
        XCTAssertEqual(LibraryBooksFormat.volumeLabel(report)?.top, "No. 277")
        XCTAssertNil(LibraryBooksFormat.volumeLabel(doc(3, "x", category: "tribunals")))
    }

    func testSizesSpansAndSeriesNames() {
        XCTAssertEqual(LibraryBooksFormat.size(6_500_000), "6.2 MB")
        XCTAssertEqual(LibraryBooksFormat.size(120 * 1024 * 1024), "120 MB")
        XCTAssertEqual(LibraryBooksFormat.size(900), "1 KB")
        XCTAssertEqual(LibraryBooksFormat.size(nil), "")
        XCTAssertEqual(LibraryBooksFormat.yearSpan(1904, 1952), "1904–1952")
        XCTAssertEqual(LibraryBooksFormat.yearSpan(1904, 1904), "1904")
        XCTAssertEqual(LibraryBooksFormat.yearSpan(nil, nil), "")
        XCTAssertEqual(LibraryBooksFormat.seriesName("THE LAWS OF ENGLAND"), "The Laws of England")
        XCTAssertEqual(LibraryBooksFormat.seriesName("Calcutta Law Journal"), "Calcutta Law Journal")
        XCTAssertEqual(LibraryBooksFormat.seriesName("AIR"), "AIR")
    }

    func testVolumeOrderAndDecades() {
        func vol(_ id: Int, _ volume: String?, year: Int?) -> CatalogueDocument {
            var d = doc(id, "CLJ \(volume ?? "")", category: "books-and-law-reports")
            d.volume = volume
            d.year = year
            return d
        }
        let sorted = [vol(1, "12", year: 1990), vol(2, nil, year: 1950), vol(3, "2", year: 1985), vol(4, nil, year: 1800)].sorted(by: LibraryBooksFormat.volumeOrder)
        XCTAssertEqual(sorted.map(\.id), [3, 1, 4, 2], "numbered volumes first, then undated by year")

        let groups = LibraryBooksFormat.groupByDecade(
            [vol(1, "1", year: 1805), vol(2, "2", year: 1812), vol(3, "3", year: 1950), vol(4, "4", year: 1951), vol(5, "5", year: 1952),
             vol(6, "6", year: 1953), vol(7, "7", year: 1961), vol(8, "8", year: nil)], thisYear: 2026)
        // Thin decades merge with their neighbours until a run is four strong, as the web's do.
        XCTAssertEqual(groups.map(\.label), ["1805–1961", "Undated volumes"])
        XCTAssertEqual(groups[0].items.count, 7)
        XCTAssertEqual(groups[0].items.map(\.id), [1, 2, 3, 4, 5, 6, 7])
        let two = LibraryBooksFormat.groupByDecade([vol(1, "1", year: 1950), vol(2, "2", year: 1951), vol(3, "3", year: 1952), vol(4, "4", year: 1953), vol(5, "5", year: 1961), vol(6, "6", year: 1962)], thisYear: 2026)
        XCTAssertEqual(two.map(\.label), ["1950s", "1960s"])
    }

    func testVolumeTitlesAndReferenceLines() {
        var v = doc(1, "Calcutta Law Journal, Vol-01, Issue no.-615", category: "books-and-law-reports")
        v.series = "Calcutta Law Journal"
        XCTAssertEqual(LibraryBooksFormat.volumeTitle(v), "Vol. 1, Issue 615")
        var order = doc(2, "In the matter of X", category: "regulator-orders")
        order.displayRef = "RBI/DOR/2025-26/232"
        order.decidedOn = "2025-11-28"
        XCTAssertEqual(LibraryBooksFormat.referenceLine(order), "RBI/DOR/2025-26/232 · 28 Nov 2025")
        XCTAssertEqual(LibraryBooksFormat.captionMeta(order, withSize: true), ["28 Nov 2025"])
        XCTAssertEqual(LibraryBooksFormat.kindLabels["adjudication"], "Adjudication order")
    }
}

final class LibraryActTextTests: XCTestCase {

    func testActTitlesAreRepaired() {
        XCTAssertEqual(LibraryActText.actTitle(doc(1, "INDIAN BARE ACTS Indian Evidence Act,1872 (Single Document)", category: "bare-acts")), "Indian Evidence Act, 1872")
        XCTAssertEqual(LibraryActText.actTitle(doc(2, "THE PROHIBITlON OF CHILD MARRIAGE ACT, 2006", category: "bare-acts")), "The Prohibition of Child Marriage Act, 2006")
        XCTAssertEqual(LibraryActText.actTitle(doc(3, "NDIAN PENAL CODE 1860", category: "bare-acts")), "Indian Penal Code, 1860")
        XCTAssertEqual(LibraryActText.actTitle(doc(4, "1THE CONSTITUTION OF INDIA", category: "bare-acts")), "The Constitution of India")
    }

    func testTheYearStandsApartOnACover() {
        let split = LibraryActText.splitTitle(doc(1, "Consumer Protection Act, 1986 No 68 of 1986", category: "bare-acts"))
        XCTAssertEqual(split.name, "Consumer Protection Act")
        XCTAssertEqual(split.year, "1986")
        var constitution = doc(2, "The Constitution of India", category: "bare-acts")
        constitution.year = 1950
        XCTAssertEqual(LibraryActText.splitTitle(constitution).year, "1950")
        XCTAssertEqual(LibraryActText.splitTitle(constitution).name, "The Constitution of India")
    }

    func testJurisdictionClothAndKicker() {
        var central = doc(1, "IPC", category: "bare-acts")
        central.jurisdiction = "Central"
        central.docType = "act"
        XCTAssertTrue(LibraryActText.jurisdiction(of: central).isCentral)
        XCTAssertEqual(LibraryActText.kicker(central), "Bare Act")
        var assam = doc(2, "Assam Act", category: "bare-acts")
        assam.jurisdiction = "Assam"
        XCTAssertEqual(LibraryActText.kicker(assam), "State Act")
        XCTAssertEqual(LibraryActText.cloth(assam), LibraryActText.cloth(assam), "one cloth per State, every time")
        XCTAssertNotEqual(LibraryActText.cloth(central), "#3A3F5C")
        var unknown = doc(3, "Rules", category: "bare-acts")
        unknown.docType = "rules"
        XCTAssertEqual(LibraryActText.jurisdiction(of: unknown).label, "Unspecified")
        XCTAssertEqual(LibraryActText.cloth(unknown), "#3A3F5C")
        XCTAssertEqual(LibraryActText.kicker(unknown), "Rules")
        unknown.aliases = ["PMLA"]
        XCTAssertEqual(LibraryActText.kicker(unknown), "PMLA")
        XCTAssertEqual(LibraryActText.jurisdiction(of: {
            var d = doc(4, "x", category: "bare-acts"); d.jurisdiction = "Jammu and Kashmir"; return d
        }()).short, "Jammu & Kashmir")
    }

    func testCountPartsFollowTheTabOrderAndLeadWithTheFilter() {
        let counts = ["rules": 9, "amendments": 25, "notifications": 1, "editions": 3, "related": 2, "act": 1]
        XCTAssertEqual(LibraryActText.countParts(counts), ["9 rules", "1 notification", "25 amendments"])
        XCTAssertEqual(LibraryActText.countParts(counts, first: "amendments").first, "25 amendments")
        XCTAssertEqual(LibraryActText.countParts(counts, withEditions: true).last, "2 related Acts")
        XCTAssertEqual(LibraryActText.countParts(nil), [])
    }

    func testRepealedTabLabelsAndSizes() {
        XCTAssertTrue(LibraryActText.isRepealed(doc(1, "Forms Rules, 2005 (Rep., Act 1 of 2020)", category: "bare-acts")))
        var flagged = doc(2, "x", category: "bare-acts")
        flagged.repealed = true
        XCTAssertTrue(LibraryActText.isRepealed(flagged))
        XCTAssertEqual(LibraryActText.actTabLabel(doc(3, "The Code of Civil Procedure, 1908", category: "bare-acts"), kind: "act"), "The Code")
        XCTAssertEqual(LibraryActText.actTabLabel(doc(4, "Bharatiya Nyaya Sanhita, 2023", category: "bare-acts"), kind: "act"), "The Sanhita")
        XCTAssertEqual(LibraryActText.actTabLabel(doc(5, "The Constitution of India", category: "bare-acts"), kind: "act"), "The Constitution")
        XCTAssertEqual(LibraryActText.actTabLabel(nil, kind: "amendments"), "Amending Acts")
        XCTAssertEqual(LibraryActText.size(1_400_000), "1.3 MB")
        XCTAssertEqual(LibraryActText.size(40_000), "39 KB")
        XCTAssertEqual(LibraryActText.shortTitle("Assam Amusements and Betting Tax (Amendment) Act, 1940", actName: "Assam Amusements and Betting Tax Act"), "… (Amendment) Act, 1940")
        XCTAssertNil(LibraryActText.shortTitle("Something else", actName: "Assam Amusements and Betting Tax Act"))
    }

    func testTabsForViewReshapeAnAmendmentGroup() {
        func d(_ id: Int, _ year: Int) -> CatalogueDocument { var x = doc(id, "Amending Act \(year)", category: "bare-acts"); x.year = year; return x }
        let bundle = ActBundle(
            act: d(1, 2019), kind: "amendments", groupTitle: "Assam Motor Vehicles Taxation Act",
            tabs: [.init(key: "act", label: "The Act", count: 1, docs: [d(1, 2019)]),
                   .init(key: "amendments", label: "Amendments", count: 2, docs: [d(2, 1990), d(3, 2005)]),
                   .init(key: "rules", label: "Rules", count: 1, docs: [d(4, 1991)])])
        let tabs = LibraryActText.tabsForView(bundle)
        XCTAssertEqual(tabs.map(\.key), ["amendments", "rules"])
        XCTAssertEqual(tabs[0].docs.map(\.id), [2, 3, 1], "a chronology")
        XCTAssertEqual(LibraryActText.latestID(in: tabs[0].docs), 1)
        XCTAssertNil(LibraryActText.latestID(in: [d(5, 2000), d(6, 2000)]), "a shared year names no latest")
    }
}

final class CaseLawVocabularyTests: XCTestCase {

    func testCourtsAreKnownAndUnknownOnesFallBack() {
        XCTAssertEqual(CaseLawVocabulary.court("chennai").short, "Madras HC")
        XCTAssertEqual(CaseLawVocabulary.court("scorders").isOrders, true)
        let unknown = CaseLawVocabulary.court("patna", label: "Patna High Court")
        XCTAssertEqual(unknown.short, "Patna HC")
        XCTAssertEqual(unknown.monogram, "Pat")
        XCTAssertEqual(CaseLawVocabulary.court(nil).monogram, "§")
        let ordered = CaseLawVocabulary.orderCourts([.init(value: "delhi", label: "Delhi High Court", count: 1), .init(value: "patna", label: "Patna", count: 1), .init(value: "supremecourt", label: "SC", count: 1)])
        XCTAssertEqual(ordered.map(\.value), ["supremecourt", "delhi", "patna"])
        XCTAssertEqual(CaseLawVocabulary.railName(.init(value: "scorders", label: "x")), "Daily orders")
        XCTAssertEqual(CaseLawVocabulary.railName(.init(value: "delhi", label: "x")), "Delhi")
    }

    func testPartyNamesReadLikeALawReport() {
        XCTAssertEqual(CaseLawVocabulary.tidyParty("MS Anand Stores"), "M/s Anand Stores")
        XCTAssertEqual(CaseLawVocabulary.tidyParty("MSHindustan Engineering"), "M/s Hindustan Engineering")
        XCTAssertEqual(CaseLawVocabulary.tidyParty("DrPercy Fernandes"), "Dr Percy Fernandes")
        XCTAssertEqual(CaseLawVocabulary.tidyParty("Kamalakar SO Keshav"), "Kamalakar s/o Keshav")
        XCTAssertEqual(CaseLawVocabulary.tidyParty("VKasi"), "V. Kasi")
        XCTAssertEqual(CaseLawVocabulary.tidyParty("STATE OF KARNATAKA"), "State of Karnataka")
        XCTAssertEqual(CaseLawVocabulary.tidyParty("Maharashtra Through The"), "Maharashtra…")
        XCTAssertEqual(CaseLawVocabulary.tidyParty(""), "")
    }

    func testCaseTitlesAndNumbers() {
        var d = doc(1, "Seethamma vs State Of Karnataka on 4 May, 1979")
        XCTAssertEqual(CaseLawVocabulary.parties(of: d)?.0, "Seethamma")
        XCTAssertEqual(CaseLawVocabulary.parties(of: d)?.1, "State of Karnataka")
        XCTAssertEqual(CaseLawVocabulary.caseTitle(d), "Seethamma v. State of Karnataka")
        d.title = "In Re: Contempt"
        XCTAssertEqual(CaseLawVocabulary.caseTitle(d), "In Re: Contempt")
        XCTAssertEqual(CaseLawVocabulary.caseNumberText(caseType: "Civil Appeal", caseNumber: "7710 of 2012"), "Civil Appeal No. 7710 of 2012")
        XCTAssertEqual(CaseLawVocabulary.caseNumberText(caseType: "Arising out of S.L.P. (C)", caseNumber: "4629 of 2008"), "Arising out of S.L.P. (C) No. 4629 of 2008")
        XCTAssertEqual(CaseLawVocabulary.caseNumberText(caseType: nil, caseNumber: "12"), "No. 12")
        XCTAssertEqual(CaseLawVocabulary.caseNumberText(caseType: "Pune Cyber Police Station Pune City with FIR No.", caseNumber: "12"), "No. 12", "a sentence is not a case type")
        XCTAssertEqual(CaseLawVocabulary.caseNumberText(caseType: "W.P.", caseNumber: "No. 5"), "W.P. No. 5")
    }

    func testFutureDatesAndReadingTime() {
        XCTAssertTrue(CaseLawVocabulary.isFutureDate("2026-12-17", today: "2026-10-19"))
        XCTAssertFalse(CaseLawVocabulary.isFutureDate("2026-10-19", today: "2026-10-19"))
        XCTAssertFalse(CaseLawVocabulary.isFutureDate("n/a", today: "2026-10-19"))
        XCTAssertEqual(CaseLawVocabulary.readingMinutes(1204), 5)
        XCTAssertEqual(CaseLawVocabulary.readingMinutes(0), 1)
        var late = doc(1, "Late")
        late.decidedOn = "2026-12-17"
        var ok = doc(2, "Ok")
        ok.decidedOn = "2026-10-01"
        XCTAssertEqual(CaseLawVocabulary.arrange([late, ok], sort: "date_desc", today: "2026-10-19").map(\.id), [2, 1])
        XCTAssertEqual(CaseLawVocabulary.arrange([late, ok], sort: "date_asc", today: "2026-10-19").map(\.id), [1, 2])
    }
}

final class JudgmentReaderModelTests: XCTestCase {

    private func blocks() -> [JudgmentBlock] {
        [
            JudgmentBlock(id: "h-0", type: "heading", text: "JUDGMENT", level: 1),
            JudgmentBlock(id: "para-1", type: "para", text: "Leave granted. The bona fide purchaser prevails.", n: "1"),
            JudgmentBlock(id: "para-2", type: "para", text: "The Bona Fide purchaser again.", n: "2"),
            JudgmentBlock(id: "para-2.1", type: "para", text: "A sub-paragraph.", n: "2.1"),
            JudgmentBlock(id: "b-4", type: "cause", text: "A ..... Appellant\nVersus\nB ..... Respondent", lines: ["A ..... Appellant", "Versus", "B ..... Respondent"]),
            JudgmentBlock(id: "para-5", type: "para", text: "Dismissed.", n: "5"),
        ]
    }

    func testPreferencesRoundTripAndRejectNonsense() {
        var prefs = JudgmentReaderModel.Preferences()
        prefs.size = 4
        prefs.face = .sans
        prefs.paper = .sepia
        let decoded = JudgmentReaderModel.Preferences.decode(prefs.encoded)
        XCTAssertEqual(decoded, prefs)
        XCTAssertEqual(decoded.percent, 117)
        XCTAssertEqual(JudgmentReaderModel.Preferences.decode(#"{"size":99,"face":"comic","width":"wide"}"#), {
            var p = JudgmentReaderModel.Preferences(); p.width = .wide; return p
        }())
        XCTAssertEqual(JudgmentReaderModel.Preferences.decode("not json"), .default)
    }

    func testPlainTextIsSplitIntoParagraphsWithTheHeaderDropped() {
        let raw = "Title: Union Of India vs Sistema on 20 February, 2026\nCourt: supremecourt\nYear: 2026\n======\n[Cites 12 ,\n Cited by 0]\n\n1. Leave\ngranted.\n\nThe appeal\narises.\n\n\n2) Dismissed."
        let parsed = JudgmentReaderModel.paragraphs(fromPlainText: raw)
        XCTAssertEqual(parsed.title, "Union Of India vs Sistema on 20 February, 2026")
        XCTAssertEqual(parsed.paragraphs, ["1. Leave granted.", "The appeal arises.", "2) Dismissed."])
        let blocks = JudgmentReaderModel.blocks(fromParagraphs: parsed.paragraphs)
        XCTAssertEqual(blocks.map(\.id), ["para-1", "b-1", "para-2"])
        XCTAssertEqual(blocks[0].text, "Leave granted.")
        XCTAssertEqual(blocks[0].n, "1")
    }

    func testFindCountsEveryMatchCaseInsensitively() {
        let search = JudgmentReaderModel.search(blocks(), for: "bona fide")
        XCTAssertEqual(search.total, 2)
        XCTAssertEqual(search.hits.map(\.block), [1, 2])
        XCTAssertEqual(search.hits[0].start, 19)
        XCTAssertEqual(search.hits[0].end, 28)
        XCTAssertEqual(search.byBlock[2]?.count, 1)
        XCTAssertEqual(JudgmentReaderModel.search(blocks(), for: "b").total, 0, "one letter is not a search")
        XCTAssertEqual(JudgmentReaderModel.search(blocks(), for: "\"Appellant\"").hits.first?.block, 4, "a cause title's lines are searched")
        XCTAssertEqual(JudgmentReaderModel.step(from: -1, by: 1, in: search), 0)
        XCTAssertEqual(JudgmentReaderModel.step(from: 1, by: 1, in: search), 0, "wraps")
        XCTAssertEqual(JudgmentReaderModel.step(from: 0, by: -1, in: search), 1)
        XCTAssertNil(JudgmentReaderModel.step(from: 0, by: 1, in: .empty))
    }

    func testGoToParagraphIsExactThenNearest() {
        XCTAssertEqual(JudgmentReaderModel.findParagraph(blocks(), numbered: "2"), 2)
        XCTAssertEqual(JudgmentReaderModel.findParagraph(blocks(), numbered: "2.1"), 3)
        XCTAssertEqual(JudgmentReaderModel.findParagraph(blocks(), numbered: "3"), 5, "the first at or past it")
        XCTAssertEqual(JudgmentReaderModel.findParagraph(blocks(), numbered: "9"), -1)
        XCTAssertEqual(JudgmentReaderModel.findParagraph(blocks(), numbered: ""), -1)
        XCTAssertEqual(JudgmentReaderModel.lastParagraphNumber(blocks()), "5")
        XCTAssertEqual(JudgmentReaderModel.index(of: "b-4", in: blocks()), 4)
    }

    func testParagraphMarksSpaceOutALongJudgment() {
        var many: [JudgmentBlock] = []
        for n in 1...120 {
            many.append(JudgmentBlock(id: "para-\(n)", type: "para", text: "x", n: String(n)))
            // A second opinion restarts at 1 part-way through.
            if n == 60 { many.append(JudgmentBlock(id: "para-1b", type: "para", text: "second opinion", n: "1")) }
        }
        let marks = JudgmentReaderModel.paragraphMarks(many)
        XCTAssertEqual(marks.map(\.n), [1, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
        XCTAssertEqual(marks.first?.id, "para-1", "the first paragraph of a number wins")
        XCTAssertEqual(JudgmentReaderModel.paragraphMarks(blocks()).count, 0, "fewer than fifteen paragraphs need no marks")
    }

    func testTheCitationLine() {
        var d = doc(1, "Seethamma vs State Of Karnataka")
        d.court = "karnataka"
        d.decidedOn = "1979-05-04"
        d.neutralCitation = "1979 KHC 12"
        XCTAssertEqual(JudgmentReaderModel.citationLine(d, header: nil), "Seethamma v. State of Karnataka, 1979 KHC 12 (Karnataka HC, 4 May 1979)")
        var header = JudgmentHeader()
        header.citations = ["(2012) 10 SCC 409"]
        header.court = "supremecourt"
        header.year = 2012
        header.title = "A vs B"
        XCTAssertEqual(JudgmentReaderModel.citationLine(nil, header: header), "A v. B, (2012) 10 SCC 409 (Supreme Court, 2012)")
        XCTAssertEqual(JudgmentReaderModel.citations(d, header: header), ["1979 KHC 12", "(2012) 10 SCC 409"])
        header.source = "https://indiankanoon.org/doc/1/"
        XCTAssertNotNil(JudgmentReaderModel.sourceURL(header))
        header.source = "https://example.com/doc/1/"
        XCTAssertNil(JudgmentReaderModel.sourceURL(header), "only the source site is linked")
    }

    func testCauseRowsNamePartiesAndTheirRoles() {
        let lines = ["REPORTABLE", "UNION OF INDIA ..... Appellant", "Versus", "SISTEMA SHYAM", "TELESERVICES LIMITED ..... Respondent",
                     "PRAYER: Petition filed under Section 482", "of the Code", "For Petitioner: Mr. X", "5.C.Jeya ... Petitioners/", "Accused Nos.1 to 5"]
        let rows = JudgmentReaderModel.causeRows(lines)
        XCTAssertEqual(rows[0].kind, .tag)
        XCTAssertEqual(rows[1].kind, .party)
        XCTAssertEqual(rows[1].text, "UNION OF INDIA")
        XCTAssertEqual(rows[1].role, "Appellant")
        XCTAssertEqual(rows[2].kind, .versus)
        XCTAssertEqual(rows[3].text, "SISTEMA SHYAM TELESERVICES LIMITED", "a name wrapped over two lines is one row")
        XCTAssertEqual(rows[3].role, "Respondent")
        XCTAssertEqual(rows[4].kind, .prayer)
        XCTAssertEqual(rows[4].text, "PRAYER: Petition filed under Section 482 of the Code")
        XCTAssertEqual(rows[5].kind, .text)
        XCTAssertEqual(rows[6].role, "Petitioners/ Accused Nos.1 to 5")
        XCTAssertNil(JudgmentReaderModel.causeFold(rows))
        XCTAssertTrue(JudgmentReaderModel.isElision("*   *   *"))
        XCTAssertTrue(JudgmentReaderModel.isCopyLine("Copy to:"))
    }
}

final class LibraryPaletteTests: XCTestCase {

    /// A cover is a physical object: its cloth is the same in both themes, and the cream
    /// lettering must clear 4.5:1 on every cloth — the web's worst is ochre at 4.8:1.
    func testCoverLetteringClearsEveryCloth() throws {
        let ink = try XCTUnwrap(LibraryCollectionTheme.color(LibraryCollectionTheme.coverInk))
        for collection in LibraryCollection.allCases {
            for shade in collection.theme.cloth {
                let cloth = try XCTUnwrap(LibraryCollectionTheme.color(shade), shade)
                XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: cloth), 4.5, "\(collection.rawValue) \(shade)")
            }
        }
        for shade in LibraryActText.stateCloths + ["#3A3F5C"] {
            let cloth = try XCTUnwrap(LibraryCollectionTheme.color(shade))
            XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: cloth), 4.5, shade)
        }
    }

    /// Each collection's and each court's ink is re-cut per theme: 4.5:1 on white and on the
    /// dark surface.
    func testInksClearTheirSurfaces() throws {
        let light = PaletteColor(hex: 0xFFFFFF)
        let dark = PaletteColor(hex: 0x1B1F36)
        for collection in LibraryCollection.allCases {
            XCTAssertGreaterThanOrEqual(collection.theme.ink(dark: false).contrastRatio(against: light), 4.5, collection.rawValue)
            XCTAssertGreaterThanOrEqual(collection.theme.ink(dark: true).contrastRatio(against: dark), 4.5, collection.rawValue)
        }
        for key in CaseLawVocabulary.courtOrder {
            let court = CaseLawVocabulary.court(key)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(LibraryCollectionTheme.color(court.ink)).contrastRatio(against: light), 4.5, key)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(LibraryCollectionTheme.color(court.inkDark)).contrastRatio(against: dark), 4.5, key)
        }
        XCTAssertNil(LibraryCollectionTheme.color("red"))
        XCTAssertNotNil(LibraryCollectionTheme.color("1F2E4D"))
    }
}
