import XCTest
@testable import EmperorCore

/// Which heading a matter goes under, and the order the headings run in.
final class CourtTierTests: XCTestCase {

    private func tier(
        type: String? = nil, code: String? = nil, name: String? = nil
    ) -> CourtTier {
        CourtTier.tier(courtType: type, courtCode: code, courtName: name)
    }

    // MARK: - The order

    /// The owner's order of importance, heading by heading.
    func testTheHeadingsRunInOrderOfImportance() {
        XCTAssertEqual(CourtTier.allCases.map(\.title), [
            "Supreme Court", "High Courts", "NCLAT", "NCLT", "Tribunals", "District Courts",
            "Consumer Commissions", "Other courts",
        ])
    }

    /// The one place this departs from the web's `COURT_ORDER`: the appellate tribunal is listed
    /// above the tribunal whose orders it hears.
    func testNCLATComesBeforeNCLT() {
        let order = CourtTier.allCases
        XCTAssertLessThan(order.firstIndex(of: .nclat)!, order.firstIndex(of: .nclt)!)
        XCTAssertLessThan(order.firstIndex(of: .nclt)!, order.firstIndex(of: .tribunal)!)
    }

    // MARK: - The stored type

    /// Every value the web stamps on `court_type`, read as it stands.
    func testEveryStoredCourtTypeIsPlacedAsTheWebStampsIt() {
        let expected: [String: CourtTier] = [
            "sc": .supremeCourt, "hc": .highCourt, "nclt": .nclt, "nclat": .nclat,
            "tribunal": .tribunal, "district": .districtCourt, "forum": .consumerCommission,
        ]
        for (type, want) in expected {
            XCTAssertEqual(tier(type: type), want, type)
            XCTAssertEqual(tier(type: " \(type.uppercased()) "), want, "\(type), shouted")
        }
    }

    /// A specific stored type outranks the name: it is what the court lookup itself recorded.
    func testASpecificStoredTypeIsNotSecondGuessedByTheName() {
        XCTAssertEqual(tier(type: "hc", name: "Supreme Court of India"), .highCourt)
        XCTAssertEqual(tier(type: "sc", name: "District & Sessions Court"), .supremeCourt)
        XCTAssertEqual(tier(type: "forum", name: "NCLT Mumbai Bench"), .consumerCommission)
    }

    /// `district` is the column's default as well as a real value, so a name or code that
    /// positively says otherwise wins — and only then.
    func testAStoredDistrictYieldsOnlyToACourtThatSaysOtherwise() {
        XCTAssertEqual(tier(type: "district", name: "Bombay High Court"), .highCourt)
        XCTAssertEqual(tier(type: "district", code: "trib-nclat"), .nclat)
        XCTAssertEqual(tier(type: "district", name: "Family Court, Bandra"), .districtCourt)
        XCTAssertEqual(tier(type: "district", name: "Court No. 4"), .districtCourt)
        XCTAssertEqual(tier(type: "district"), .districtCourt)
    }

    /// `tribunal` is generic; NCLT and NCLAT have headings of their own.
    func testAGenericTribunalIsRefinedOnlyToNCLTOrNCLAT() {
        XCTAssertEqual(tier(type: "tribunal", code: "trib-nclat"), .nclat)
        XCTAssertEqual(tier(type: "tribunal", name: "NCLT Mumbai Bench"), .nclt)
        XCTAssertEqual(tier(type: "tribunal", name: "Debts Recovery Tribunal"), .tribunal)
        XCTAssertEqual(tier(type: "tribunal", name: "Bombay High Court"), .tribunal,
                       "only the two company-law tribunals refine it")
        XCTAssertEqual(tier(type: "tribunal"), .tribunal)
    }

    /// An unrecognised type is no type: the name decides.
    func testAnUnknownTypeFallsBackToTheName() {
        XCTAssertEqual(tier(type: "highcourt", name: "Bombay High Court"), .highCourt)
        XCTAssertEqual(tier(type: "", name: "Supreme Court of India"), .supremeCourt)
        XCTAssertEqual(tier(type: "other", name: "NCLT Mumbai Bench"), .nclt)
        XCTAssertEqual(tier(type: "mystery"), .other)
    }

    // MARK: - The code

    /// Every court the lookup can save a case under is placed exactly as the lookup files it,
    /// from its code alone.
    func testEveryCatalogueCodeIsPlacedAsTheLookupFilesIt() {
        for court in CourtCatalogue.all {
            XCTAssertEqual(tier(code: court.id), CourtTier(family: court.family), court.id)
        }
        XCTAssertEqual(tier(code: "trib-nclat"), .nclat)
        XCTAssertEqual(tier(code: "trib-nclt"), .nclt)
        XCTAssertEqual(tier(code: "trib-drt"), .tribunal)
        XCTAssertEqual(tier(code: "forum-dcdrc"), .consumerCommission,
                       "a District Commission is not a district court")
        XCTAssertEqual(tier(code: "dist-family"), .districtCourt)
    }

    /// Codes the catalogue does not list: the bare `hc` the High Court routes stamp when no court
    /// id was sent, and a court added to the platform after this build.
    func testCodesOutsideTheCatalogueArePlacedByTheirPrefix() {
        XCTAssertEqual(tier(code: "hc"), .highCourt)
        XCTAssertEqual(tier(code: "hc-ladakh-new"), .highCourt)
        XCTAssertEqual(tier(code: "trib-rera"), .tribunal)
        XCTAssertEqual(tier(code: "forum-new"), .consumerCommission)
        XCTAssertEqual(tier(code: "dist-rent"), .districtCourt)
        XCTAssertEqual(tier(code: "SC"), .supremeCourt)
    }

    /// A district court's eCourts code is a number, which says nothing — the name decides.
    func testACodeThatNamesNoTierDefersToTheName() {
        XCTAssertEqual(tier(code: "1", name: "Family Court, Pune"), .districtCourt)
        XCTAssertEqual(tier(code: "1"), .other)
        XCTAssertEqual(tier(code: "trib-nclat", name: "Debts Recovery Tribunal"), .nclat,
                       "a code the app knows is read before the name")
    }

    // MARK: - The name

    func testCourtNamesArePlacedTheWayAPractitionerReadsThem() {
        let expected: [(String, CourtTier)] = [
            ("Supreme Court of India", .supremeCourt),
            ("High Court of Delhi", .highCourt),
            ("Bombay High Court", .highCourt),
            ("High Court — Madras", .highCourt),
            ("Delhi HC", .highCourt),
            ("National Company Law Appellate Tribunal", .nclat),
            ("NCLAT, Chennai Bench", .nclat),
            ("National Company Law Appellate Tribunal (NCLAT)", .nclat),
            ("NCLT Mumbai Bench", .nclt),
            ("NCLT-Mumbai", .nclt),
            ("National Company Law Tribunal (NCLT)", .nclt),
            ("Debts Recovery Tribunal", .tribunal),
            ("Debts Recovery Appellate Tribunal (DRAT)", .tribunal),
            ("Income Tax Appellate Tribunal (ITAT)", .tribunal),
            ("CAT Principal Bench", .tribunal),
            ("National Green Tribunal", .tribunal),
            ("District & Sessions Court", .districtCourt),
            ("Family Court, Bandra", .districtCourt),
            ("CJM / Metropolitan Magistrate Court", .districtCourt),
            ("Court of Small Causes, Mumbai", .districtCourt),
            ("State Consumer Disputes Redressal Commission", .consumerCommission),
            ("National Consumer Disputes Redressal Commission (NCDRC)", .consumerCommission),
            ("Consumer Forum, Pune", .consumerCommission),
        ]
        for (name, want) in expected {
            XCTAssertEqual(tier(name: name), want, name)
        }
    }

    /// The checks whose order matters, each against the one it must come before.
    func testNamesThatCarryTwoTiersAreReadTheRightWayRound() {
        XCTAssertEqual(tier(name: "District Consumer Disputes Redressal Commission"),
                       .consumerCommission, "consumer before district")
        XCTAssertEqual(tier(name: "Motor Accident Claims Tribunal (MACT)"), .districtCourt,
                       "the platform files MACT with the subordinate courts")
        XCTAssertEqual(tier(name: "Labour Court / Industrial Tribunal"), .districtCourt)
        XCTAssertEqual(tier(name: "High Court of Bombay at Goa, District Bench"), .highCourt,
                       "High Court before district")
    }

    /// Whole words only, and never "SC" for the Supreme Court — the SC/ST Act's special courts
    /// are trial courts.
    func testNamesAreMatchedOnWholeWords() {
        XCTAssertNotEqual(tier(name: "Special Court (SC/ST Act), Pune"), .supremeCourt)
        XCTAssertEqual(tier(name: "Catalyst Arbitration Centre"), .other, "not CAT")
        XCTAssertEqual(tier(name: "Saturn Mediation Cell"), .other, "not SAT")
        XCTAssertEqual(tier(name: "HCL Arbitration Room"), .other, "not HC inside HCL")
    }

    func testNothingToGoOnIsOther() {
        XCTAssertEqual(tier(), .other)
        XCTAssertEqual(tier(type: "  ", code: "", name: "   "), .other)
        XCTAssertEqual(tier(name: "Court No. 4"), .other)
    }

    /// Placing a whole case reads its three fields.
    func testACaseIsPlacedFromItsOwnFields() {
        let legalCase = LegalCase(
            id: "c", teamID: nil, cnr: nil, courtType: nil, courtCode: nil, caseNumber: nil,
            caseYear: nil, title: "Bakshi", parties: nil, status: nil, stage: nil,
            nextHearingDateRaw: nil, filingDateRaw: nil, judge: nil,
            courtName: "Bombay High Court", caseType: nil, diaryNumber: nil, category: nil,
            lastSyncedAtRaw: nil, createdAtRaw: nil, updatedAtRaw: nil, teamName: nil)
        XCTAssertEqual(CourtTier.of(legalCase), .highCourt)
    }

    func testEveryLookupFamilyHasAHeading() {
        let tiers = Set(CourtFamily.allCases.map(CourtTier.init(family:)))
        XCTAssertEqual(tiers.count, CourtFamily.allCases.count, "two families share a heading")
        XCTAssertFalse(tiers.contains(.other))
    }
}
