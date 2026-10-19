import XCTest
@testable import EmperorCore

/// The matter's record — the merge, the List of Dates & Events and the Overview timeline —
/// against the web's own `projectRecord.js` and `OverviewSection.jsx`, run under Node (regenerate
/// with `node scripts/generate-matter-record-fixtures.mjs <platform>`).
final class MatterRecordGoldenTests: XCTestCase {

    static func root() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "record", withExtension: "json", subdirectory: "matter-record"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: Any?, id: String = "x") throws -> T {
        var dict = (object as? [String: Any]) ?? [:]
        if dict["id"] == nil { dict["id"] = id }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    static func record() throws -> (updates: [ProjectUpdate], court: [CaseItem], root: [String: Any]) {
        let root = try root()
        let updates = try XCTUnwrap(root["updates"] as? [[String: Any]]).map { try decode(ProjectUpdate.self, $0) }
        let court = try XCTUnwrap(root["courtHistory"] as? [[String: Any]]).map { try decode(CaseItem.self, $0) }
        return (updates, court, root)
    }

    static func entries() throws -> [MatterRecordEntry] {
        let r = try record()
        return MatterRecord.entries(updates: r.updates, courtHistory: r.court)
    }

    func testTheMergeIsTheWebs() throws {
        let r = try Self.record()
        let ours = MatterRecord.entries(updates: r.updates, courtHistory: r.court)
        let web = try XCTUnwrap(r.root["entries"] as? [[String: Any]])
        XCTAssertEqual(ours.map(\.key), web.map { $0["key"] as? String ?? "" })
        for (entry, w) in zip(ours, web) {
            XCTAssertEqual(entry.source.rawValue, w["src"] as? String, entry.key)
            XCTAssertEqual(entry.isOwn, w["own"] as? Bool, entry.key)
            XCTAssertEqual(entry.kind, w["kind"] as? String, entry.key)
            XCTAssertEqual(entry.day, w["day"] as? String, entry.key)
            XCTAssertEqual(entry.title, w["title"] as? String, entry.key)
            XCTAssertEqual(entry.body, w["body"] as? String, entry.key)
            XCTAssertEqual(entry.sourceRef, w["sourceRef"] as? String, entry.key)
            XCTAssertEqual(MatterRecord.eventText(entry), w["eventText"] as? String, entry.key)
        }
    }

    func testTheOrderIsTheWebs() throws {
        let r = try Self.record()
        let entries = MatterRecord.entries(updates: r.updates, courtHistory: r.court)
        XCTAssertEqual(MatterRecord.sorted(entries).map(\.key), r.root["oldestFirst"] as? [String])
        XCTAssertEqual(MatterRecord.sorted(entries, newestFirst: true).map(\.key), r.root["newestFirst"] as? [String])
    }

    func testEveryListOfDatesIsTheWebsDocument() throws {
        let r = try Self.record()
        let entries = MatterRecord.entries(updates: r.updates, courtHistory: r.court)
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
        let exports = try XCTUnwrap(r.root["exports"] as? [[String: Any]])
        XCTAssertEqual(exports.count, 5)
        for item in exports {
            let name = item["name"] as? String ?? "?"
            let project = try Self.decode(Project.self, item["project"])
            let linked: LinkedCaseSummary? = item["linkedCase"] is NSNull ? nil
                : try Self.decode(LinkedCaseSummary.self, item["linkedCase"])
            let picked = try XCTUnwrap(item["keys"] as? [String]).compactMap { byKey[$0] }
            XCTAssertEqual(ChronologyExport.html(project: project, linkedCase: linked, entries: picked),
                           item["html"] as? String, name)
        }
    }

    /// The form's default groups give the web's default selection.
    func testTheDefaultGroupsAreTheWebsDefaultSelection() throws {
        let r = try Self.record()
        let entries = MatterRecord.entries(updates: r.updates, courtHistory: r.court)
        let exports = try XCTUnwrap(r.root["exports"] as? [[String: Any]])
        let web = try XCTUnwrap(exports.first { $0["name"] as? String == "default-selection" }?["keys"] as? [String])
        let ours = ChronologyExport.picked(entries, groups: ChronologyExport.defaultGroups)
        XCTAssertEqual(Set(ours.map(\.key)), Set(web))
        XCTAssertEqual(ChronologyExport.summary(ours), "10 entries on 10 dates, oldest first")
        XCTAssertEqual(ChronologyExport.summary([]), "Nothing selected")
        let grouped = ChronologyExport.grouped(entries)
        XCTAssertEqual(grouped[.notes]?.map(\.key), ["u:u4", "u:u5"])
        XCTAssertEqual(grouped[.ai]?.map(\.key), ["u:u2"])
        XCTAssertEqual(Set(grouped[.hearings]?.map(\.key) ?? []), ["u:u6", "c:c2", "c:c5", "c:c9"],
                       "a court listing copied into the chronology is still a listing")
    }

    func testNextHearings() throws {
        let r = try Self.record()
        let today = try XCTUnwrap(r.root["today"] as? String)
        for item in try XCTUnwrap(r.root["nextHearings"] as? [[String: Any]]) {
            let projectDate = (item["project"] as? [String: Any])?["next_hearing_date"] as? String
            let courtDate = (item["linkedCase"] as? [String: Any])?["next_hearing_date"] as? String
            let ours = MatterRecord.nextHearing(projectDate: projectDate, courtDate: courtDate, today: today)
            if let web = item["next"] as? [String: Any] {
                XCTAssertEqual(ours?.day, web["day"] as? String)
                XCTAssertEqual(ours?.from, web["from"] as? String)
                XCTAssertEqual(ours?.days, web["days"] as? Int)
            } else {
                XCTAssertNil(ours)
            }
        }
    }

    func testTheTimelineIsTheWebs() throws {
        let r = try Self.record()
        let entries = MatterRecord.entries(updates: r.updates, courtHistory: r.court)
        for item in try XCTUnwrap(r.root["timeline"] as? [[String: Any]]) {
            let name = item["name"] as? String ?? "?"
            let day = try XCTUnwrap(item["day"] as? String)
            let projectDate = (item["project"] as? [String: Any])?["next_hearing_date"] as? String
            let courtDate = (item["linkedCase"] as? [String: Any])?["next_hearing_date"] as? String
            let next = MatterRecord.nextHearing(projectDate: projectDate, courtDate: courtDate, today: day)
            let ours = OverviewTimeline.rows(entries: entries, next: next, today: day)
            let web = try XCTUnwrap(item["rows"] as? [[String: Any]])
            XCTAssertEqual(ours.count, web.count, name)
            for (row, w) in zip(ours, web) {
                if let year = w["year"] as? String {
                    XCTAssertEqual(row.kind, .year(year), name)
                    continue
                }
                if w["next"] as? Bool == true {
                    XCTAssertEqual(row.kind, .next, name)
                } else {
                    XCTAssertEqual(row.id, w["key"] as? String, name)
                    XCTAssertEqual(row.kind, .entry(kind: w["kind"] as? String ?? "",
                                                    origin: OverviewTimeline.Origin(rawValue: w["src"] as? String ?? "")!), name)
                }
                XCTAssertEqual(row.index, w["i"] as? Int, "\(name) \(row.id)")
                XCTAssertEqual(row.date, w["date"] as? String, "\(name) \(row.id)")
                XCTAssertEqual(row.title, w["title"] as? String, "\(name) \(row.id)")
                XCTAssertEqual(row.subtitle, w["sub"] as? String, "\(name) \(row.id)")
            }
        }
    }

    func testTheTextHelpers() throws {
        let r = try Self.root()
        for item in try XCTUnwrap(r["plainCourtText"] as? [[String: String]]) {
            XCTAssertEqual(MatterRecord.plainCourtText(item["in"]), item["out"])
        }
        for item in try XCTUnwrap(r["orderTitle"] as? [[String: String]]) {
            XCTAssertEqual(MatterRecord.orderTitle(item["in"]), item["out"])
        }
        for item in try XCTUnwrap(r["fmtDots"] as? [[String: String]]) {
            XCTAssertEqual(MatterRecord.dots(item["in"]), item["out"], item["in"] ?? "")
        }
    }

    // MARK: - This client's own

    func testTheFileNameIsTheWebs() {
        XCTAssertEqual(ChronologyExport.baseName(matterName: "Acme v. Beta (Delhi)"), "List_of_Dates_Acme_v_Beta_Delhi")
        XCTAssertEqual(ChronologyExport.baseName(matterName: "  "), "List_of_Dates_matter")
        XCTAssertEqual(ChronologyExport.baseName(matterName: nil), "List_of_Dates_matter")
        let long = String(repeating: "Word ", count: 20)
        let base = ChronologyExport.baseName(matterName: long)
        XCTAssertTrue(base.hasSuffix("_Word"), "cut at a word: \(base)")
        XCTAssertLessThanOrEqual(base.count - "List_of_Dates_".count, 60)
    }

    func testRowsAlternateAndSayWhoseTheyAre() throws {
        let rows = OverviewTimeline.rows(
            entries: try Self.entries(), next: MatterRecord.NextHearing(day: "2026-10-25", from: "project", days: 6),
            today: "2026-10-19")
        XCTAssertEqual(rows.first?.kind, .next)
        XCTAssertFalse(rows[0].isFlipped)
        let court = try XCTUnwrap(rows.first { $0.id == "c:c4" })
        XCTAssertTrue(court.isOrder)
        XCTAssertEqual(court.accessibilityText, "12 Aug: Order dated 12.08.2026, Order (From the court)")
        XCTAssertTrue(rows.allSatisfy { row in
            if case .entry(let kind, _) = row.kind { return kind != "task" }
            return true
        })
    }
}
