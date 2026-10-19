import XCTest
@testable import EmperorCore

/// A tracked case is listed under the name the platform would give the matter made from it, so
/// opening it does not rename the row. Held to `tidyCourtName`'s own answers.
final class CourtNamesTests: XCTestCase {

    private struct GoldenCase: Decodable {
        let raw: String
        let title: Bool
        let expected: String
    }

    func testEveryGoldenCaseMatchesThePlatform() throws {
        let cases = try JSONDecoder().decode([GoldenCase].self, from: Data(CourtNamesGolden.json.utf8))
        XCTAssertFalse(cases.isEmpty)
        for golden in cases {
            XCTAssertEqual(
                CourtNames.tidy(golden.raw, title: golden.title), golden.expected,
                "\(golden.raw.debugDescription) title: \(golden.title)")
        }
    }

    func testNilIsAnEmptyName() {
        XCTAssertEqual(CourtNames.tidy(nil, title: true), "")
    }
}
