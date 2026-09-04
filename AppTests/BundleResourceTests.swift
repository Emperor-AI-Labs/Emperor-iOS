import XCTest
import UIKit
@testable import Emperor

/// Questions only a build that actually ran can answer.
///
/// `swift test` on Linux covers 619 cases and none of them can see any of this: there is no
/// bundle, no UIKit, and `@Observable` is not even applied. Every failure mode checked here is
/// silent — the app renders perfectly and is simply wrong.
final class BundleResourceTests: XCTestCase {

    /// The bundled brand face registered.
    ///
    /// Three separate mistakes end in "the system font, silently": a missing `UIAppFonts` entry,
    /// a resource that never made it into the bundle, or a PostScript name that does not match
    /// the font's `fvar` table. SwiftUI substitutes and renders without complaint, so nothing
    /// downstream of this notices.
    func testFredokaRegistered() {
        XCTAssertTrue(
            BrandFont.isAvailable,
            "Fredoka did not register — check UIAppFonts, the bundled file, and the names below")
    }

    /// Every named instance resolves, not merely the family.
    ///
    /// This font is variable and its *default* instance is Light, so a family-name lookup
    /// "succeeds" while giving the wrong weight everywhere. Each instance is asked for by name.
    func testEveryWeightResolvesToTheRealFace() {
        for name in BrandFont.Name.all {
            let font = UIFont(name: name, size: 17)
            XCTAssertNotNil(font, "\(name) did not resolve")
            XCTAssertEqual(
                font?.fontName, name,
                "\(name) resolved to \(font?.fontName ?? "nil") — a substitution, not the face")
        }
    }

    /// The weights are actually different.
    ///
    /// A variable font whose axis failed to apply returns five identical faces under five names,
    /// which every check above would pass. Widths differ if the weight axis really moved.
    func testTheWeightsDiffer() {
        let text = "Bakshi v. State of Maharashtra" as NSString
        let regular = UIFont(name: BrandFont.Name.regular, size: 17)!
        let bold = UIFont(name: BrandFont.Name.bold, size: 17)!
        let regularWidth = text.size(withAttributes: [.font: regular]).width
        let boldWidth = text.size(withAttributes: [.font: bold]).width
        XCTAssertGreaterThan(
            boldWidth, regularWidth,
            "bold is not wider than regular — the weight axis is not being applied")
    }

    /// The licence ships with the font, which SIL OFL 1.1 requires.
    func testTheFontLicenceShips() {
        XCTAssertNotNil(
            Bundle.main.url(forResource: "OFL", withExtension: "txt"),
            "the OFL licence must ship alongside the font")
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
