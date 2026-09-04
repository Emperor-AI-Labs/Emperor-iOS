import XCTest

@testable import EmperorCore

/// Fixed so the plausible-year ceiling does not drift with the wall clock.
///
/// A global rather than a stored property: `Cin.parse` takes a `@Sendable` closure, and an
/// `XCTestCase` is not `Sendable`, so capturing `self` in one is rejected under Swift 6.
private let fixedClock = iso8601("2026-09-02T00:00:00Z")

private func iso8601(_ value: String) -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else {
        preconditionFailure("bad fixture instant \(value)")
    }
    return date
}

private func parse(_ raw: String?) -> CinResult {
    Cin.parse(raw, now: { fixedClock })
}

/// The decoder is pure, so these are all straight input/output.
///
/// The CINs used are real ones named in the platform's own source notes (IVRCL, Lanco, Jet
/// Airways) or built segment-by-segment to exercise one branch at a time.
final class CinTests: XCTestCase {

    // MARK: - Normalisation

    func testNormaliseUppercasesAndStripsWhitespaceAndFullStops() {
        XCTAssertEqual(Cin.normalise("  u16001ap2005plc048552 "), "U16001AP2005PLC048552")
        XCTAssertEqual(Cin.normalise("U 16001 AP 2005 PLC 048552"), "U16001AP2005PLC048552")
        XCTAssertEqual(Cin.normalise("U.16001.AP.2005.PLC.048552"), "U16001AP2005PLC048552")
        XCTAssertEqual(Cin.normalise("U16001AP2005PLC048552\n"), "U16001AP2005PLC048552")
    }

    func testNormaliseKeepsHyphensBecauseAnLLPINIsWrittenWithOne() {
        XCTAssertEqual(Cin.normalise("aaa-1234"), "AAA-1234")
    }

    func testNormaliseToleratesNil() {
        XCTAssertEqual(Cin.normalise(nil), "")
    }

    // MARK: - The happy path

    func testDecodesEverySegmentOfAWellFormedCIN() throws {
        let r = parse("U16001AP2005PLC048552")

        XCTAssertEqual(r.kind, .cin)
        XCTAssertTrue(r.shapeValid)
        XCTAssertTrue(r.confident)
        XCTAssertNil(r.reason)
        XCTAssertTrue(r.anomalies.isEmpty)

        let f = try XCTUnwrap(r.fields)
        XCTAssertEqual(f.listing.label, "Unlisted")
        XCTAssertEqual(f.industryDivision, "16")
        XCTAssertEqual(f.industry.label, "Manufacture of tobacco products")
        XCTAssertEqual(f.roc.label, "ROC Vijayawada, Andhra Pradesh")
        XCTAssertEqual(f.yearValue, 2005)
        XCTAssertEqual(f.companyClass.label, "Public Limited Company")
        XCTAssertEqual(f.registration.code, "048552")
    }

    func testSegmentsAreReportedInTheOrderTheCharactersAppear() throws {
        let f = try XCTUnwrap(parse("U16001AP2005PLC048552").fields)
        XCTAssertEqual(f.ordered.map(\.code), ["U", "16001", "AP", "2005", "PLC", "048552"])
        XCTAssertEqual(
            f.ordered.map(\.key),
            ["listing", "industry", "roc", "year", "class", "registration"])
    }

    func testALowercaseSpacedPasteDecodesIdenticallyToTheCanonicalForm() {
        XCTAssertEqual(
            parse("u 16001 ap 2005 plc 048552").summary,
            parse("U16001AP2005PLC048552").summary)
    }

    // MARK: - The NIC edition, which is the whole point of the industry table

    func testIndustryIsReadAsNIC1987_2004NotNIC2008() {
        // Division 45 is construction here. NIC-2008 assigns 45 to motor-vehicle trade, and the
        // platform's source names IVRCL and Pratibha Industries as the companies that would have
        // been mislabelled. This test is what stops a future "update to NIC-2008" from landing.
        XCTAssertEqual(parse("L45201AP1987PLC007959").fields?.industry.label, "Construction")
        XCTAssertEqual(
            parse("L45201AP1987PLC007959").fields?.industryScheme, Cin.nicSchemeLabel)
    }

    func testDivision40IsPowerADivisionNIC2008DoesNotUseAtAll() {
        XCTAssertEqual(
            parse("U40108TG2009PLC063463").fields?.industry.label,
            "Electricity, gas, steam and hot water supply")
    }

    func testDivision72IsComputingWhichNIC2008AssignsToRAndD() {
        XCTAssertEqual(
            parse("U72200DL1999PLC102841").fields?.industry.label,
            "Computer and related activities")
    }

    func testDivision92IsMediaWhichNIC2008AssignsToGambling() {
        XCTAssertEqual(
            parse("U92100MH2007PTC176372").fields?.industry.label,
            "Recreational, cultural and sporting activities")
    }

    func testOnlyTheTwoDigitDivisionIsDecodedNeverTheSubClass() throws {
        // 16001 and 16009 are different sub-classes of the same division and must read the same.
        let a = try XCTUnwrap(parse("U16001AP2005PLC048552").fields)
        let b = try XCTUnwrap(parse("U16009AP2005PLC048552").fields)
        XCTAssertEqual(a.industry.label, b.industry.label)
        // The full code is still carried raw, so the caller can show it.
        XCTAssertEqual(a.industry.code, "16001")
        XCTAssertEqual(b.industry.code, "16009")
    }

    // MARK: - MCA's catch-alls, which are not NIC divisions

    func test99999IsMCAsNotElsewhereClassifiedBucketNotNICDivision99() throws {
        // Jet Airways (India) Limited.
        let f = try XCTUnwrap(parse("L99999MH1992PLC066936").fields)
        XCTAssertEqual(f.industry.label, "Not elsewhere classified (MCA general code)")
        XCTAssertTrue(f.industryIsSentinel)
        XCTAssertTrue(f.industry.known)
    }

    func test00000MeansNoIndustryCodeWasRecorded() throws {
        let f = try XCTUnwrap(parse("U00000MH2005PTC048552").fields)
        XCTAssertEqual(f.industry.label, "No industry code recorded against this company")
        XCTAssertTrue(f.industryIsSentinel)
    }

    func testASentinelOutranksTheDivisionReadingAndIsKeptOutOfTheSummary() {
        // Division 99 has no NIC entry, so without the sentinel this would be an anomaly.
        let r = parse("L99999MH1992PLC066936")
        XCTAssertTrue(r.confident)
        XCTAssertTrue(r.anomalies.isEmpty)
        // A sentinel says nothing about the industry, so the sentence must not claim a division.
        XCTAssertFalse(r.summary.contains("Industry division"))
    }

    // MARK: - Registrar, including the city registrars

    func testPNIsROCPuneInsideMaharashtraNotAStateOfItsOwn() throws {
        let f = try XCTUnwrap(parse("U72200PN2009PTC134567").fields)
        XCTAssertEqual(f.roc.label, "ROC Pune, Maharashtra")
        XCTAssertEqual(f.rocState, "Maharashtra")
        XCTAssertTrue(f.rocIsCityRegistrar)
    }

    func testTZIsROCCoimbatoreInsideTamilNadu() throws {
        let f = try XCTUnwrap(parse("U17111TZ1994PLC005678").fields)
        XCTAssertEqual(f.roc.label, "ROC Coimbatore, Tamil Nadu")
        XCTAssertEqual(f.rocState, "Tamil Nadu")
        XCTAssertTrue(f.rocIsCityRegistrar)
    }

    func testAStateWhoseRegistrarSeatIsUncertainNamesTheStateAndStops() throws {
        // CT has office = nil deliberately. Inventing "ROC Raipur" would be the exact failure
        // this table's nil is there to prevent.
        let f = try XCTUnwrap(parse("U45201CT2011PTC022345").fields)
        XCTAssertEqual(f.roc.label, "Registrar in Chhattisgarh")
        XCTAssertNil(f.rocOffice)
        XCTAssertTrue(f.roc.known)
        XCTAssertFalse(f.rocIsCityRegistrar)
    }

    func testTheUncertainSeatSummaryReadsAsTheRegistrarInThatState() {
        XCTAssertTrue(
            parse("U45201CT2011PTC022345").summary
                .contains("registered with the registrar in Chhattisgarh"))
    }

    func testBothUttarakhandCodesResolve() {
        XCTAssertEqual(parse("U45201UT2011PTC022345").fields?.rocState, "Uttarakhand")
        XCTAssertEqual(parse("U45201UK2011PTC022345").fields?.rocState, "Uttarakhand")
    }

    // MARK: - The neighbouring registers

    func testAHyphenatedLLPINIsNamedRatherThanRejected() throws {
        let r = parse("AAA-1234")
        XCTAssertEqual(r.kind, .llpin)
        XCTAssertFalse(r.shapeValid)
        XCTAssertFalse(r.confident)
        XCTAssertNil(r.fields)
        XCTAssertEqual(r.summary, "LLPIN AAA-1234 — a Limited Liability Partnership.")
        XCTAssertTrue(try XCTUnwrap(r.reason).contains("LLP Act 2008"))
    }

    func testABareLLPINFromAPDFIsRecognisedAndRenderedHyphenated() {
        let r = parse("AAB5824")
        XCTAssertEqual(r.kind, .llpin)
        XCTAssertEqual(r.summary, "LLPIN AAB-5824 — a Limited Liability Partnership.")
    }

    func testAnFCRNIsNamedRatherThanRejected() throws {
        let r = parse("F-01234")
        XCTAssertEqual(r.kind, .fcrn)
        XCTAssertFalse(r.shapeValid)
        XCTAssertEqual(r.summary, "FCRN F01234 — a foreign company registered in India.")
        XCTAssertTrue(try XCTUnwrap(r.reason).contains("Chapter XXII"))
    }

    func testAnUnhyphenatedFCRNIsRecognised() {
        XCTAssertEqual(parse("F01234").kind, .fcrn)
    }

    func testTheRegisterCheckRunsBeforeTheLengthCheck() {
        // Both are far from 21 characters. Reporting "a CIN is 21 characters" would be true and
        // useless; naming the register the number actually belongs to is the point.
        XCTAssertEqual(parse("AAA-1234").kind, .llpin)
        XCTAssertEqual(parse("F-01234").kind, .fcrn)
    }

    // MARK: - Rejection

    func testEmptyInputAsksForACINRatherThanReportingAnError() {
        let r = parse("")
        XCTAssertEqual(r.kind, .unknown)
        XCTAssertEqual(r.reason, "Enter a CIN to decode it.")
        XCTAssertEqual(r.summary, "")
    }

    func testNilInputIsTreatedAsEmpty() {
        XCTAssertEqual(parse(nil).reason, "Enter a CIN to decode it.")
    }

    func testWhitespaceOnlyInputIsTreatedAsEmpty() {
        XCTAssertEqual(parse("   ").reason, "Enter a CIN to decode it.")
    }

    func testTheWrongLengthIsReportedWithTheLengthThatWasGiven() {
        let r = parse("U16001AP2005PLC04855")
        XCTAssertEqual(r.kind, .unknown)
        XCTAssertEqual(r.reason, "A CIN is exactly 21 characters; this is 20.")
    }

    func test21CharactersInTheWrongArrangementIsAShapeErrorNotALengthError() throws {
        let r = parse("UU6001AP2005PLC048552")
        XCTAssertEqual(r.kind, .unknown)
        XCTAssertFalse(r.shapeValid)
        XCTAssertTrue(try XCTUnwrap(r.reason).contains("Wrong shape for a CIN"))
    }

    func testNoRejectionPathEverReturnsFields() {
        let bad = [
            "", "   ", "AAA-1234", "F-01234", "U16001AP2005PLC0485", "UU6001AP2005PLC048552",
        ]
        for input in bad {
            let r = parse(input)
            XCTAssertNil(r.fields, "fields should be nil for '\(input)'")
            XCTAssertFalse(r.shapeValid, "shapeValid should be false for '\(input)'")
            XCTAssertFalse(r.confident, "confident should be false for '\(input)'")
        }
    }

    // MARK: - shapeValid without confident: parse noise from upstream PDFs

    func testAnUnknownListingFlagIsShapeValidButNotConfident() throws {
        let r = parse("A16001AP2005PLC048552")
        XCTAssertTrue(r.shapeValid)
        XCTAssertFalse(r.confident)
        XCTAssertEqual(r.kind, .cin)
        XCTAssertEqual(r.fields?.listing.label, "Listing code: A (unrecognised)")
        XCTAssertEqual(r.anomalies.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(r.anomalies.first)
                .contains("only L (listed) and U (unlisted) are valid"))
    }

    func testAnUnknownCompanyClassIsShapeValidButNotConfident() throws {
        let r = parse("U16001AP2005SKM048552")
        XCTAssertTrue(r.shapeValid)
        XCTAssertFalse(r.confident)
        XCTAssertEqual(r.fields?.companyClass.label, "Class code: SKM (unrecognised)")
        XCTAssertEqual(r.anomalies.count, 1)
        XCTAssertTrue(try XCTUnwrap(r.anomalies.first).contains("\"SKM\" is not a code MCA uses"))
    }

    func testAnUnknownNICDivisionIsLeftUndecodedRatherThanGuessed() throws {
        let r = parse("U03001AP2005PLC048552")
        XCTAssertFalse(r.confident)
        XCTAssertEqual(
            r.fields?.industry.label, "NIC code: 03001 (division 03 unrecognised)")
        XCTAssertFalse(try XCTUnwrap(r.fields).industry.known)
        XCTAssertEqual(r.anomalies.count, 1)
        XCTAssertTrue(try XCTUnwrap(r.anomalies.first).contains("left undecoded"))
    }

    func testAnUnknownRegistrarCodeIsShownRawRatherThanGuessedAt() throws {
        let r = parse("U16001ZZ2005PLC048552")
        XCTAssertFalse(r.confident)
        XCTAssertEqual(r.fields?.roc.label, "Registrar code: ZZ (unrecognised)")
        XCTAssertNil(r.fields?.rocState)
        XCTAssertEqual(r.anomalies.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(r.anomalies.first).contains("shown raw rather than guessed at"))
    }

    func testEveryUnrecognisedSegmentContributesItsOwnAnomaly() {
        let r = parse("A03001ZZ2005SKM048552")
        XCTAssertTrue(r.shapeValid)
        XCTAssertFalse(r.confident)
        XCTAssertEqual(r.anomalies.count, 4)
    }

    func testAnUnrecognisedCodeNeverAppearsAsALabelFromAnotherSegment() throws {
        // The failure this guards against is a lookup miss silently borrowing a neighbour's label.
        let f = try XCTUnwrap(parse("A03001ZZ2005SKM048552").fields)
        for field in f.ordered where field.key != "registration" {
            if !field.known { XCTAssertTrue(field.label.contains(field.code)) }
        }
    }

    // MARK: - Year plausibility

    func testAYearBeforeIndianCompanyRegistrationIsImplausible() throws {
        let r = parse("U16001AP1849PLC048552")
        XCTAssertFalse(r.confident)
        XCTAssertEqual(r.fields?.year.label, "Year: 1849 (implausible)")
        XCTAssertNil(r.fields?.yearValue)
        XCTAssertEqual(r.anomalies.count, 1)
        XCTAssertTrue(try XCTUnwrap(r.anomalies.first).contains("outside a plausible range"))
    }

    func test1850IsTheFirstPlausibleYear() {
        let r = parse("U16001AP1850PLC048552")
        XCTAssertTrue(r.confident)
        XCTAssertEqual(r.fields?.yearValue, 1850)
    }

    func testNextYearIsPlausibleButTheYearAfterIsNot() {
        // Allowing one year ahead covers a CIN allotted just before a year boundary.
        XCTAssertTrue(parse("U16001AP2027PLC048552").confident)
        XCTAssertFalse(parse("U16001AP2028PLC048552").confident)
    }

    func testThePlausibleCeilingFollowsTheClockRatherThanAHardcodedYear() {
        let later = iso8601("2031-01-01T00:00:00Z")
        XCTAssertFalse(Cin.parse("U16001AP2028PLC048552", now: { fixedClock }).confident)
        XCTAssertTrue(Cin.parse("U16001AP2028PLC048552", now: { later }).confident)
    }

    // MARK: - The summary sentence

    func testTheSummaryReadsAsOneSentenceWithTheIndustryAppended() {
        XCTAssertEqual(
            parse("U16001AP2005PLC048552").summary,
            "An unlisted public limited company registered with ROC Vijayawada in 2005. "
                + "Industry division: Manufacture of tobacco products.")
    }

    func testAListedCompanyTakesTheArticleA() {
        XCTAssertTrue(
            parse("L45201AP1987PLC007959").summary
                .hasPrefix("A listed public limited company"))
    }

    func testAnUnlistedCompanyTakesTheArticleAn() {
        XCTAssertTrue(parse("U16001AP2005PLC048552").summary.hasPrefix("An unlisted"))
    }

    func testTheYearClauseReadsIncorporatedInWhenThereIsNoRegistrarToHangOff() {
        let r = parse("U16001ZZ2005PLC048552")
        XCTAssertTrue(r.summary.contains("incorporated in 2005"))
        XCTAssertFalse(r.summary.contains("registered with"))
    }

    func testAnUnknownClassStillYieldsAReadableSentence() {
        XCTAssertTrue(
            parse("U16001AP2005SKM048552").summary
                .hasPrefix("An unlisted company registered with"))
    }

    func testAnUnknownListingStillYieldsAReadableSentence() {
        XCTAssertTrue(
            parse("A16001AP2005PLC048552").summary
                .hasPrefix("A public limited company registered with"))
    }

    func testASentenceWithNothingDecodableStillParsesAsACompany() {
        XCTAssertEqual(parse("A03001ZZ1700SKM048552").summary, "A company.")
    }

    func testTheSummaryNeverContainsTheWordUnrecognised() {
        // Unrecognised segments drop out of the sentence; they are reported through anomalies.
        let bad = [
            "A16001AP2005PLC048552", "U16001ZZ2005PLC048552", "U03001AP2005PLC048552",
            "U16001AP2005SKM048552",
        ]
        for input in bad {
            XCTAssertFalse(parse(input).summary.contains("unrecognised"), input)
            XCTAssertFalse(parse(input).summary.contains("implausible"), input)
        }
    }

    // MARK: - Formatting and the cheap predicate

    func testFormatSpacesACINIntoItsSegments() {
        XCTAssertEqual(Cin.format("u16001ap2005plc048552"), "U 16001 AP 2005 PLC 048552")
    }

    func testFormatFallsBackToTheNormalisedInputWhenItIsNotACIN() {
        XCTAssertEqual(Cin.format(" aaa-1234 "), "AAA-1234")
        XCTAssertEqual(Cin.format("notacin"), "NOTACIN")
    }

    func testFormatToleratesEmptyAndNil() {
        XCTAssertEqual(Cin.format(""), "")
        XCTAssertEqual(Cin.format(nil), "")
    }

    func testTheWellFormedPredicateAgreesWithTheParserOnShape() {
        for s in ["U16001AP2005PLC048552", "A03001ZZ1700SKM048552", "u16001ap2005plc048552"] {
            XCTAssertTrue(Cin.isWellFormed(s), s)
            XCTAssertTrue(parse(s).shapeValid, s)
        }
        for s in ["", "AAA-1234", "F-01234", "U16001AP2005PLC04855", "UU6001AP2005PLC048552"] {
            XCTAssertFalse(Cin.isWellFormed(s), s)
            XCTAssertFalse(parse(s).shapeValid, s)
        }
    }

    // MARK: - The honesty guarantees

    func testEveryResultCarriesTheVerificationNote() {
        for s in ["U16001AP2005PLC048552", "AAA-1234", "", "UU6001AP2005PLC048552"] {
            XCTAssertEqual(parse(s).verificationNote, Cin.verificationNote)
        }
    }

    func testTheVerificationNoteRefusesTheWordVerified() {
        // The note exists so a caller cannot present a decode as authentication.
        XCTAssertTrue(Cin.verificationNote.contains("no check digit"))
        XCTAssertTrue(Cin.verificationNote.contains("not proof that the company exists"))
    }

    func testTheInputIsEchoedBackUnmodifiedAlongsideTheNormalisedForm() {
        let r = parse("  u16001ap2005plc048552  ")
        XCTAssertEqual(r.input, "  u16001ap2005plc048552  ")
        XCTAssertEqual(r.normalised, "U16001AP2005PLC048552")
    }

    func testConfidentImpliesShapeValidAndNoAnomalies() {
        let inputs = [
            "U16001AP2005PLC048552", "L99999MH1992PLC066936", "A16001AP2005PLC048552",
            "AAA-1234", "",
        ]
        for s in inputs {
            let r = parse(s)
            if r.confident {
                XCTAssertTrue(r.shapeValid, s)
                XCTAssertTrue(r.anomalies.isEmpty, s)
            }
        }
    }

    // MARK: - Typing, which is how a CIN arrives on a phone

    func testAHalfTypedCINIsIncompleteRatherThanInvalid() {
        // Every prefix of a real CIN, one keystroke at a time. All twenty must read as unfinished;
        // the twenty-first is the first point at which "not a CIN" is an answer rather than noise.
        let full = "U16001AP2005PLC048552"
        for n in 1..<full.count {
            let r = parse(String(full.prefix(n)))
            XCTAssertTrue(r.isIncomplete, "length \(n)")
            XCTAssertEqual(r.charactersRemaining, full.count - n, "length \(n)")
        }
        XCTAssertFalse(parse(full).isIncomplete)
        XCTAssertEqual(parse(full).charactersRemaining, 0)
    }

    func testAnEmptyFieldIsNotIncompleteItIsUntouched() {
        // Nothing has been typed, so there is nothing to keep going with.
        XCTAssertFalse(parse("").isIncomplete)
        XCTAssertFalse(parse("   ").isIncomplete)
        XCTAssertEqual(parse("").charactersRemaining, 0)
    }

    func testAFullLengthWrongShapeIsADecidedAnswerNotAnUnfinishedOne() throws {
        let r = parse("UU6001AP2005PLC048552")
        XCTAssertFalse(r.isIncomplete)
        XCTAssertEqual(r.charactersRemaining, 0)
        XCTAssertTrue(try XCTUnwrap(r.reason).contains("Wrong shape"))
    }

    func testAnOverLengthInputIsNotIncomplete() {
        XCTAssertFalse(parse("U16001AP2005PLC048552X").isIncomplete)
    }

    func testARecognisedNeighbouringRegisterIsDecidedNeverIncomplete() {
        // Both are short, but they are answers. Telling someone to keep typing an LLPIN would be
        // telling them to turn it into something it cannot become.
        XCTAssertFalse(parse("AAA-1234").isIncomplete)
        XCTAssertFalse(parse("F-01234").isIncomplete)
    }

    func testIncompletenessNeverHidesTheReason() {
        // The flag is about how a caller presents the result, not about withholding it.
        let r = parse("U16001AP20")
        XCTAssertTrue(r.isIncomplete)
        XCTAssertEqual(r.reason, "A CIN is exactly 21 characters; this is 10.")
    }

    func testTheMasterDataGapsNameWhatIsAbsentRatherThanFillingIt() {
        XCTAssertEqual(Cin.masterDataGaps.count, 5)
        XCTAssertTrue(
            Cin.masterDataGaps.allSatisfy { !$0.field.isEmpty && !$0.why.isEmpty })
        XCTAssertTrue(Cin.masterDataGaps.map(\.field).contains("Registered office address"))
        XCTAssertTrue(Cin.masterDataGapReason.contains("captcha-gated"))
    }
}
