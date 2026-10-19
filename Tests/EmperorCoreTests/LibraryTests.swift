import XCTest
@testable import EmperorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The catalogue-backed Library (docs/library.md): what goes on the wire, and how the wire's
// shapes decode. Every JSON below is the platform's own (lib/library/query.js toItem, act.js,
// judgment.js, routes.js), trimmed.

private let browseJSON = #"""
{"success":true,"items":[
 {"id":257708,"title":"Union Of India vs Sistema Shyam Teleservices Limited on 20 February, 2026","displayTitle":"Union Of India vs Sistema Shyam Teleservices Limited on 20 February, 2026",
  "category":"case-law","court":"supremecourt","courtLabel":"Supreme Court","year":2026,"decidedOn":"2026-02-20","petitioner":"UNION OF INDIA","respondent":"SISTEMA SHYAM TELESERVICES LIMITED",
  "neutralCitation":"2026 INSC 210","caseType":"Civil Appeal","caseNumber":"4629 of 2008","bench":"B.R. Gavai, K. Vinod Chandran","ext":".txt","fileSize":653000,"render":"html"},
 {"id":3461,"title":"BIHAR MOTOR VEHICLES RULES, 1992","displayTitle":"Bihar Motor Vehicles Rules, 1992","category":"bare-acts","docType":"rules","jurisdiction":"Bihar","year":1992,
  "ext":".pdf","fileSize":2300000,"render":"pdf","hasChildren":3,"coverUrl":"/api/library/catalogue/cover?id=3461&w=320","anomalies":["future_year"]},
 {"id":280398,"title":"Calcutta Law Journal, Vol-91","category":"books-and-law-reports","series":"Calcutta Law Journal","volume":"Vol-91","volumeNo":91,"year":1953,"issue":"615","ext":".pdf","fileSize":"8123456","render":"pdf"}
],"total":271480,"page":2,"pageSize":20,"sort":"date_desc"}
"""#

private let searchJSON = #"""
{"success":true,"items":[{"id":1,"title":"A vs B","category":"case-law","court":"delhi","courtLabel":"Delhi High Court","ext":".txt","render":"html",
 "snippet":{"text":"the bona fide purchaser for value without notice","before":true,"after":false,"term":"bona fide purchaser"}}],
 "total":1000,"totalIsCapped":true,"page":1,"pageSize":20,"sort":null,"search":"\"bona fide purchaser\"","mode":"body",
 "index":{"available":true,"ready":true,"complete":false,"indexed":200000,"pending":71480,"noText":0,"total":271480}}
"""#

private let judgmentJSON = #"""
{"success":true,"doc":{"id":257708,"title":"Union Of India vs Sistema","category":"case-law","court":"supremecourt","ext":".txt"},
 "header":{"court":"supremecourt","courtLabel":"Supreme Court","title":"Union Of India vs Sistema Shyam Teleservices Limited on 20 February, 2026",
  "petitioner":"UNION OF INDIA","respondent":"SISTEMA SHYAM TELESERVICES LIMITED","caseNumber":"4629 of 2008","caseType":"Civil Appeal",
  "decidedOn":"2026-02-20","year":2026,"bench":["B.R. Gavai","K. Vinod Chandran"],"author":"B.R. Gavai","citations":["2026 INSC 210","(2026) 3 SCC 1"],
  "neutralCitation":"2026 INSC 210","source":"https://indiankanoon.org/doc/174288830/","citesCount":12,"citedByCount":0},
 "blocks":[
  {"id":"b-0","type":"cause","text":"UNION OF INDIA ..... Appellant\nVersus\nSISTEMA ..... Respondent","lines":["UNION OF INDIA ..... Appellant","Versus","SISTEMA ..... Respondent"]},
  {"id":"h-1","type":"heading","level":1,"text":"JUDGMENT"},
  {"id":"para-1","type":"para","n":"1","text":"Leave granted."},
  {"id":"para-2","type":"para","n":2,"text":"The appeal arises from the order of the High Court."},
  {"id":"b-4","type":"quote","text":"\"No person shall be deprived of his property save by authority of law.\""},
  {"id":"b-5","type":"list","marker":"(a)","text":"the first ground"},
  {"id":"b-6","type":"meta","role":"signature","lines":["..................J.","(B.R. GAVAI)","New Delhi;"],"text":"..................J.\n(B.R. GAVAI)\nNew Delhi;"},
  {"id":"b-7","type":"table","lines":["Sl.  Date      Event","1.   01.01.26  Filed"],"text":"Sl.  Date      Event\n1.   01.01.26  Filed"}
 ],
 "toc":[{"id":"h-1","label":"Judgment","level":1},{"id":"para-2","label":"Para 2","level":3}],
 "stats":{"paragraphs":2,"words":1204,"blocks":8,"layout":"wrapped","debrisLines":3,"formatMs":120},"formatterVersion":7,"cached":false}
"""#

private let actJSON = #"""
{"success":true,"act":{"id":2478,"title":"THE PREVENTION OF MONEY-LAUNDERING ACT, 2002","category":"bare-acts","docType":"act","jurisdiction":"Central","jurisdictionInferred":false,
  "jurisdictionSource":"catalogue","year":2002,"ext":".pdf","fileSize":512000,"render":"pdf","aliases":["PMLA"]},
 "bundleId":2478,"kind":"act","requestedId":5333,"selectedId":5333,"selectedTab":"rules","orphan":false,
 "tabs":[{"key":"act","label":"The Act","count":1,"docs":[{"id":2478,"title":"THE PREVENTION OF MONEY-LAUNDERING ACT, 2002","category":"bare-acts","docType":"act","year":2002,"ext":".pdf"}]},
        {"key":"rules","label":"Rules","count":2,"docs":[{"id":5333,"title":"Prevention of Money-laundering (Appeal) Rules, 2005","category":"bare-acts","docType":"rules","year":2005,"ext":".pdf","copies":[9001]},
                                                       {"id":5334,"title":"Prevention of Money-laundering (Forms) Rules, 2005 (Rep., Act 1 of 2020)","category":"bare-acts","docType":"rules","year":2005,"ext":".pdf","repealed":true}]},
        {"key":"editions","label":"Other editions","count":1,"docs":[{"id":7001,"title":"The Prevention of Money-Laundering Act, 2002","category":"bare-acts","docType":"act","jurisdiction":"Assam","year":2002,"ext":".pdf","fileSize":40000}]}]}
"""#

private let foldersJSON = #"""
{"success":true,"items":[{"id":2478,"title":"THE PREVENTION OF MONEY-LAUNDERING ACT, 2002","category":"bare-acts","docType":"act","jurisdiction":"Central","year":2002,"ext":".pdf",
 "firstLetter":"P","kind":"act","tabCounts":{"rules":9,"notifications":17,"amendments":25,"editions":3},"instruments":28,"hasChildren":28,"aliases":["PMLA"],"jurisdictionInferred":false}],
 "total":1,"page":1,"pageSize":60,
 "letters":[{"letter":"A","count":210},{"letter":"P","count":98},{"letter":"#","count":4}],
 "jurisdictions":[{"value":"Central","label":"Central","count":1206},{"value":"Assam","label":"Assam","count":401},{"value":"none","label":"Unspecified","count":293}]}
"""#

private let facetsJSON = #"""
{"success":true,"facets":{"category":"case-law","label":"Case law",
 "courts":[{"value":"chennai","label":"Madras High Court","count":74760},{"value":"supremecourt","label":"Supreme Court","count":30724}],
 "years":[{"year":2026,"count":12},{"year":2025,"count":9000}],"yearRange":{"min":1950,"max":2027},
 "docTypes":[],"jurisdictions":[],"series":[{"value":"Calcutta Law Journal","count":66,"yearMin":1904,"yearMax":1952}],
 "sorts":[{"value":"date_desc","label":"Newest"},{"value":"date_asc","label":"Oldest"}],
 "publishers":[{"value":"sebi","label":"SEBI","name":"Securities and Exchange Board of India","count":1200}],
 "kinds":[{"value":"adjudication","label":"Adjudication orders","count":300}],
 "letters":[{"letter":"A","count":10},{"letter":"#","count":1}]}}
"""#

final class LibraryWireTests: XCTestCase {

    private static let config = APIConfig(baseURL: URL(string: "https://example.test/api")!)

    override func setUp() { super.setUp(); HTTPStub.reset() }
    override func tearDown() { HTTPStub.reset(); super.tearDown() }

    private func makeService() async -> (LibraryService, APIClient) {
        let client = APIClient(config: Self.config, session: HTTPStub.session())
        await client.setCredentials(Credentials(token: "tok-abc", userID: 42))
        return (LibraryService(client: client), client)
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testEveryRouteIsUnderTheCatalogueAndCarriesTheBearerToken() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"success":true,"categories":[{"key":"case-law","label":"Case law","count":271480}]}"#))
        let categories = try await service.categories()
        XCTAssertEqual(categories.first?.count, 271_480)
        let request = try XCTUnwrap(HTTPStub.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/library/catalogue/categories")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
    }

    /// The filters in force, and only those, reach the query string; the page size is clamped
    /// to what the route accepts.
    func testBrowseSendsOnlyTheFiltersInForce() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(browseJSON))
        var filters = LibraryBrowseFilters(category: "case-law", query: "state", sort: "date_desc", page: 2, pageSize: 500)
        filters.court = "delhi"
        filters.yearFrom = 2015
        filters.series = ""
        let page = try await service.browse(filters)
        let q = query(HTTPStub.lastRequest)
        XCTAssertEqual(q["category"], "case-law")
        XCTAssertEqual(q["court"], "delhi")
        XCTAssertEqual(q["yearFrom"], "2015")
        XCTAssertEqual(q["q"], "state")
        XCTAssertEqual(q["page"], "2")
        XCTAssertEqual(q["pageSize"], "100")
        XCTAssertNil(q["series"])
        XCTAssertNil(q["yearTo"])
        XCTAssertEqual(page.total, 271_480)
        XCTAssertEqual(page.pageCount, 13_574)
        XCTAssertTrue(page.hasMore)
    }

    /// The row's many optional fields, including the ones that arrive in more than one type.
    func testADocumentRowDecodesItsManyShapes() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(browseJSON))
        let items = try await service.browse(LibraryBrowseFilters(category: "case-law")).items
        XCTAssertEqual(items.count, 3)
        let judgment = items[0]
        XCTAssertEqual(judgment.court, "supremecourt")
        XCTAssertTrue(judgment.isTextDocument)
        XCTAssertFalse(judgment.isPDF)
        XCTAssertEqual(judgment.bench, "B.R. Gavai, K. Vinod Chandran")
        let rules = items[1]
        XCTAssertTrue(rules.isPDF)
        XCTAssertEqual(rules.hasChildren, 3)
        XCTAssertEqual(rules.anomalies, ["future_year"])
        XCTAssertTrue(rules.opensAsAct, "an instrument with children is a bundle: it opens the Act page")
        let volume = items[2]
        XCTAssertEqual(volume.fileSize, 8_123_456, "a size sent as a string still reads")
        XCTAssertEqual(volume.volumeNo, 91)
        XCTAssertEqual(volume.issue, "615")
    }

    func testBodySearchReadsPassagesTheCapAndTheIndex() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(searchJSON))
        var filters = LibraryBrowseFilters(category: "case-law", query: "\"bona fide purchaser\"")
        filters.pageSize = 80
        let page = try await service.search(filters)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/library/catalogue/search")
        XCTAssertEqual(query(HTTPStub.lastRequest)["pageSize"], "50", "body search pages are at most 50")
        XCTAssertEqual(page.totalIsCapped, true)
        XCTAssertEqual(page.items.first?.snippet?.text, "the bona fide purchaser for value without notice")
        XCTAssertEqual(page.items.first?.snippet?.before, true)
        XCTAssertEqual(page.items.first?.snippet?.after, false)
        XCTAssertEqual(page.index?.complete, false)
        XCTAssertEqual(page.index?.indexed, 200_000)
    }

    func testFacetsDecodeEveryGroup() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(facetsJSON))
        let facets = try await service.facets(category: "case-law")
        XCTAssertEqual(facets.courts?.count, 2)
        XCTAssertEqual(facets.yearRange?.max, 2027)
        XCTAssertEqual(facets.series?.first?.yearMax, 1952)
        XCTAssertEqual(facets.publishers?.first?.name, "Securities and Exchange Board of India")
        XCTAssertEqual(facets.kinds?.first?.displayLabel, "Adjudication orders")
        XCTAssertEqual(facets.letters?.last?.letter, "#")
        XCTAssertEqual(facets.sorts?.map(\.value), ["date_desc", "date_asc"])
    }

    /// A paragraph number arrives as a string or a number; a block's lines are kept.
    func testAJudgmentDecodesItsBlocks() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(judgmentJSON))
        let judgment = try await service.judgment(id: 257_708)
        XCTAssertEqual(judgment.blocks.count, 8)
        XCTAssertEqual(judgment.blocks[2].n, "1")
        XCTAssertEqual(judgment.blocks[3].n, "2", "a numeric n reads as its string")
        XCTAssertEqual(judgment.blocks[0].lines?.count, 3)
        XCTAssertEqual(judgment.blocks[6].role, "signature")
        XCTAssertEqual(judgment.header?.bench, ["B.R. Gavai", "K. Vinod Chandran"])
        XCTAssertEqual(judgment.header?.citations.count, 2)
        XCTAssertEqual(judgment.toc.count, 2)
        XCTAssertEqual(judgment.stats?.words, 1204)
    }

    func testAnActBundleDecodesWithItsTabsAndCopies() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(actJSON))
        let bundle = try await service.act(id: 5333)
        XCTAssertEqual(query(HTTPStub.lastRequest)["id"], "5333")
        XCTAssertEqual(bundle.selectedTab, "rules")
        XCTAssertEqual(bundle.selectedId, 5333)
        XCTAssertEqual(bundle.tabs.map(\.key), ["act", "rules", "editions"])
        XCTAssertEqual(bundle.tabs[1].docs[0].copies, [9001])
        XCTAssertEqual(bundle.tabs[1].docs[1].repealed, true)
        XCTAssertEqual(bundle.act.aliases, ["PMLA"])
        XCTAssertEqual(bundle.resolvedKind, "act")
    }

    func testTheActIndexCarriesLettersAndJurisdictions() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(foldersJSON))
        var filters = ActIndexFilters()
        filters.letter = "P"
        filters.jurisdiction = "Central"
        filters.has = "rules"
        filters.pageSize = 999
        let page = try await service.actIndex(filters)
        let q = query(HTTPStub.lastRequest)
        XCTAssertEqual(HTTPStub.lastRequest?.url?.path, "/api/library/catalogue/folders")
        XCTAssertEqual(q["letter"], "P")
        XCTAssertEqual(q["jurisdiction"], "Central")
        XCTAssertEqual(q["has"], "rules")
        XCTAssertEqual(q["pageSize"], "200")
        XCTAssertEqual(page.letters.count, 3)
        XCTAssertEqual(page.jurisdictions.last?.label, "Unspecified")
        XCTAssertEqual(page.items.first?.tabCounts?["amendments"], 25)
        XCTAssertEqual(page.items.first?.firstLetter, "P")
    }

    /// `/doc` folds the family into the row itself.
    func testADocumentDetailDecodesItsFamily() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"""
        {"success":true,"doc":{"id":2478,"title":"PMLA","category":"bare-acts","docType":"act","ext":".pdf","hasFile":false,
         "childGroups":[{"key":"rules","label":"Rules","items":[{"id":5333,"title":"Appeal Rules","category":"bare-acts"}]}],"childCount":1,
         "editions":[{"id":7001,"title":"PMLA (Assam)","category":"bare-acts"}],"parent":null}}
        """#))
        let detail = try await service.document(id: 2478)
        XCTAssertEqual(detail.doc.hasFile, false)
        XCTAssertEqual(detail.childGroups.first?.items.first?.id, 5333)
        XCTAssertEqual(detail.editions.count, 1)
        XCTAssertNil(detail.parent)
    }

    func testTheGroupedSearchAndTheShelves() async throws {
        let (service, _) = await makeService()
        HTTPStub.respond { request in
            let q = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            if q.contains(where: { $0.name == "groupBy" }) {
                return .json(#"{"success":true,"groups":[{"category":"bare-acts","label":"Bare acts","total":12,"items":[{"id":1,"title":"PMLA"}]}],"search":"money","pageSize":6}"#)
            }
            if q.contains(where: { $0.name == "by" && $0.value == "series" }) {
                return .json(#"{"success":true,"seriesTotal":200,"shelves":[{"series":"Calcutta Law Journal","count":66,"yearMin":1904,"yearMax":1952,"items":[{"id":3}]}],"standalone":{"count":1000,"items":[{"id":4}]},"day":"2026-10-19"}"#)
            }
            return .json(#"{"success":true,"category":"case-law","label":"Case law","day":"2026-10-19","items":[{"id":2,"title":"A vs B","category":"case-law"}]}"#)
        }
        let grouped = try await service.browseGrouped(query: "money", pageSize: 99)
        XCTAssertEqual(query(HTTPStub.lastRequest)["pageSize"], "20", "grouped pages are at most 20")
        XCTAssertEqual(grouped.groups.first?.total, 12)
        let shelf = try await service.shelf(category: "case-law", limit: 14)
        XCTAssertEqual(shelf.items.first?.id, 2)
        let series = try await service.seriesShelves(limit: 12, per: 14)
        XCTAssertEqual(series.shelves.first?.yearMin, 1904)
        XCTAssertEqual(series.standalone?.count, 1000)
    }

    /// The cover route's three answers: bytes, "not yet", "never".
    func testTheCoverRouteAnswersThreeWays() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(HTTPStub.Reply(status: 200, body: Data([0xFF, 0xD8, 0xFF]), headers: ["Content-Type": "image/jpeg"]))
        if case .image(let data) = try await service.cover(id: 3461, width: 640) {
            XCTAssertEqual(data.count, 3)
        } else { XCTFail("expected an image") }
        XCTAssertEqual(query(HTTPStub.lastRequest)["w"], "640")

        HTTPStub.always(HTTPStub.Reply(status: 404, body: Data(#"{"error":"cover_pending"}"#.utf8),
                                       headers: ["Content-Type": "application/json", "Retry-After": "5"]))
        let pending = try await service.cover(id: 3461, width: 320)
        XCTAssertEqual(pending, .pending(retryAfter: 5))

        HTTPStub.always(.json(#"{"error":"no_cover","reason":"not_pdf"}"#, status: 404))
        let none = try await service.cover(id: 257_708, width: 320)
        XCTAssertEqual(none, .none(reason: "not_pdf"))

        _ = try await service.cover(id: 1, width: 999)
        XCTAssertEqual(query(HTTPStub.lastRequest)["w"], "320", "an unknown width falls back to the default rather than earning a 400")
    }

    func testTheCatalogueErrorsCarryTheirCodes() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(.json(#"{"error":"not_an_act"}"#, status: 404))
        do {
            _ = try await service.act(id: 257_708)
            XCTFail("expected a refusal")
        } catch let error as LibraryCatalogueError {
            XCTAssertEqual(error.code, "not_an_act")
            XCTAssertEqual(error.errorDescription, "This document is not part of the Bare Acts.")
        }
        HTTPStub.always(.json(#"{"error":"file_missing"}"#, status: 404))
        do {
            _ = try await service.judgment(id: 1)
            XCTFail("expected a refusal")
        } catch let error as LibraryCatalogueError {
            XCTAssertTrue(error.isFileMissing)
        }
        HTTPStub.always(.json(#"{"error":"catalogue_unavailable","message":"The library catalogue has not been built on this host."}"#, status: 503))
        do {
            _ = try await service.categories()
            XCTFail("expected a refusal")
        } catch let error as LibraryCatalogueError {
            XCTAssertTrue(error.isUnavailable)
            XCTAssertEqual(error.errorDescription, "The library catalogue has not been built on this host.")
        }
        HTTPStub.always(.json(#"{"error":"unknown_library_route","path":"/library/catalogue/shelf"}"#, status: 404))
        do {
            _ = try await service.shelf(category: "case-law", limit: 14)
            XCTFail("expected a refusal")
        } catch let error as LibraryCatalogueError {
            XCTAssertTrue(error.isMissingRoute)
        }
    }

    /// A 401 is the session ending, and the app is told so it signs out as from any other route.
    func testAnAuthRefusalEndsTheSession() async throws {
        let (service, client) = await makeService()
        final class Flag: @unchecked Sendable { var value = false }
        let lost = Flag()
        await client.setAuthenticationLostHandler { lost.value = true }
        HTTPStub.always(.json(#"{"success":false,"error":"auth_required","message":"Sign in to use the Library."}"#, status: 401))
        do {
            _ = try await service.categories()
            XCTFail("expected 401")
        } catch let error as APIError {
            XCTAssertEqual(error, .invalidCredentials)
        }
        XCTAssertTrue(lost.value)
    }

    /// A HEAD tells a file apart from a catalogue row whose bytes are elsewhere.
    func testFileExistsReadsTheHead() async throws {
        let (service, _) = await makeService()
        HTTPStub.always(HTTPStub.Reply(status: 200, body: Data(), headers: ["Content-Type": "application/pdf"]))
        let present = try await service.fileExists(id: 7)
        XCTAssertTrue(present)
        XCTAssertEqual(HTTPStub.lastRequest?.httpMethod, "HEAD")
        HTTPStub.always(.json(#"{"error":"not_found"}"#, status: 404))
        let absent = try await service.fileExists(id: 7)
        XCTAssertFalse(absent)
        HTTPStub.always(.json(#"{"error":"not_found"}"#, status: 404))
        do {
            _ = try await service.file(id: 7, prefer: .text)
            XCTFail("expected 404")
        } catch let error as LibraryCatalogueError {
            XCTAssertEqual(error.status, 404)
        }
        XCTAssertEqual(query(HTTPStub.lastRequest)["prefer"], "text")
    }
}

final class LibraryModelTests: XCTestCase {

    func testEveryCollectionHasAThemeAndAnUnknownKeyFallsBack() {
        for collection in LibraryCollection.allCases {
            XCTAssertFalse(collection.theme.label.isEmpty, collection.rawValue)
            XCTAssertEqual(collection.theme.cloth.count >= 3, true)
        }
        let unknown = LibraryCollectionTheme.theme(for: "gazettes")
        XCTAssertEqual(unknown.label, "Library")
        XCTAssertEqual(unknown.key, "gazettes")
        XCTAssertEqual(LibraryCategoryCount(key: "gazettes", label: "Gazettes", count: 3).theme.label, "Gazettes",
                       "a new collection shows under the name the server gave it")
    }

    func testAnActOpensItsPageAndEverythingElseTheReadingRoom() {
        var act = CatalogueDocument(id: 1, title: "IPC", category: "bare-acts")
        act.docType = "act"
        XCTAssertTrue(act.opensAsAct)
        var rule = CatalogueDocument(id: 2, title: "Rules", category: "bare-acts")
        rule.docType = "rules"
        XCTAssertFalse(rule.opensAsAct)
        rule.hasChildren = 2
        XCTAssertTrue(rule.opensAsAct, "an instrument with children is a bundle of its own")
        var judgment = CatalogueDocument(id: 3, title: "A v. B", category: "case-law")
        judgment.docType = "act"
        XCTAssertFalse(judgment.opensAsAct)
    }

    func testAPageCountsItsPages() {
        XCTAssertEqual(LibraryPage(items: [], total: 0, page: 1, pageSize: 36).pageCount, 1)
        XCTAssertEqual(LibraryPage(items: [], total: 37, page: 1, pageSize: 36).pageCount, 2)
        XCTAssertFalse(LibraryPage(items: [], total: 36, page: 1, pageSize: 36).hasMore)
        XCTAssertEqual(LibraryPage(items: [], total: 10, page: 1, pageSize: 0).pageCount, 1, "a zero page size does not divide")
    }

    func testTheErrorWordingCoversEveryCode() {
        for code in ["catalogue_unavailable", "auth_required", "not_found", "unknown_category", "unknown_library_route",
                     "not_an_act", "not_a_judgment", "file_missing", "too_large", "search_busy", "bad_id"] {
            XCTAssertFalse(LibraryCatalogueError.wording(for: code, status: 400).contains("("), code)
        }
        XCTAssertEqual(LibraryCatalogueError(status: 500, code: "library_failed").errorDescription, "The library did not answer (500). Try again in a moment.")
        XCTAssertTrue(LibraryCatalogueError(status: 413, code: "too_large").isTooLarge)
        XCTAssertTrue(LibraryCatalogueError(status: 404, code: "no_cover", reason: "file_missing").isFileMissing)
    }
}
