import XCTest
import UIKit
@testable import Emperor

/// Questions only a build that actually ran can answer.
///
/// `swift test` on Linux covers well over a thousand cases and none of them can see any of this: there is no
/// bundle, no UIKit, and `@Observable` is not even applied. Every failure mode checked here is
/// silent — the app renders perfectly and is simply wrong.
final class BundleResourceTests: XCTestCase {

    /// The bundled Record faces registered.
    ///
    /// Three separate mistakes end in "the system font, silently": a missing `UIAppFonts` entry,
    /// a resource that never made it into the bundle, or a PostScript name that does not match
    /// the file's `name` table. SwiftUI substitutes and renders without complaint, so nothing
    /// downstream of this notices.
    func testTheRecordFacesRegistered() {
        XCTAssertTrue(
            BrandFont.isAvailable,
            "Plus Jakarta Sans did not register — check UIAppFonts, the bundled files, and the names")
        XCTAssertTrue(
            BrandFont.isDisplayAvailable,
            "Instrument Serif did not register — check UIAppFonts, the bundled files, and the names")
    }

    /// Every weight and the serif's italic resolve by name, not merely the family.
    func testEveryFaceResolvesToTheRealFile() {
        for name in BrandFont.Name.all + BrandFont.Name.displayAll {
            let font = UIFont(name: name, size: 17)
            XCTAssertNotNil(font, "\(name) did not resolve")
            XCTAssertEqual(
                font?.fontName, name,
                "\(name) resolved to \(font?.fontName ?? "nil") — a substitution, not the face")
        }
    }

    /// The weights are actually different files.
    func testTheWeightsDiffer() {
        let text = "Bakshi v. State of Maharashtra" as NSString
        let regular = UIFont(name: BrandFont.Name.regular, size: 17)!
        let bold = UIFont(name: BrandFont.Name.bold, size: 17)!
        let regularWidth = text.size(withAttributes: [.font: regular]).width
        let boldWidth = text.size(withAttributes: [.font: bold]).width
        XCTAssertGreaterThan(boldWidth, regularWidth, "bold is not wider than regular")
    }

    /// The licences ship with the fonts, which SIL OFL 1.1 requires.
    func testTheFontLicencesShip() {
        for licence in ["PlusJakartaSans-OFL", "InstrumentSerif-OFL"] {
            XCTAssertNotNil(
                Bundle.main.url(forResource: licence, withExtension: "txt"),
                "\(licence).txt must ship alongside its font")
        }
    }

    /// Apple asks for both at submission and rejects for either.
    func testTheSubmissionRequirementsShip() {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "the privacy manifest is missing")
        XCTAssertNotNil(
            Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription"),
            "without a camera purpose string iOS terminates the app when the scanner opens")
    }

    /// The brand mark the sign-in screen draws. A missing asset renders as nothing at all — an
    /// empty space where the logo should be — with no error anywhere.
    func testTheBrandMarkShips() {
        let mark = UIImage(named: "EmperorMark")
        XCTAssertNotNil(mark, "EmperorMark is missing from the asset catalogue")
        // The artwork is wider than tall (the platform's EmperorLogoFinal2, cropped to its
        // bounds). A square here would mean the uncropped 500×500 canvas, padding and all.
        if let size = mark?.size {
            XCTAssertGreaterThan(size.width, size.height)
        }
    }

    /// The version in Settings has to be the version that was built, or a bug report names the
    /// wrong build. The first `.ipa` shipped as 1.0 (1) while the spec said 0.1.0.
    func testTheVersionIsTheOneTheSpecDeclares() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "0.1.0")
    }

    /// A debug build must reach the development host, which is the only one stood up today.
    /// The opposite direction — a release build reaching development — is pinned in the core by
    /// `APIEnvironmentTests` and is the one that matters for safety.
    func testADebugBuildTalksToDevelopment() {
        XCTAssertEqual(APIConfig.resolvedEnvironment, .development)
    }
}
