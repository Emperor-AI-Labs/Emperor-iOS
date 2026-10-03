import XCTest
@testable import EmperorCore

/// Icon tiles — their colours and their pictures — held to the platform's own JavaScript.
///
/// `Resources/tool-tiles.json` is produced by running `src/tools/registry.js` and
/// `src/roles/roleConfig.js` under Node (`scripts/generate-tile-fixtures.mjs`). A tool's tile on
/// the phone should be the tile it has on the web: the same colour, which the web picks by
/// hashing the tool's id, and the same picture.
final class TileTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Tool: Decodable {
            let color: String
            let icon: String?
        }
        let palette: [String]
        let tools: [String: Tool]
        let hashes: [String: String]
        let roles: [String: String]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tool-tiles", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return "#" + String(repeating: "0", count: max(0, 6 - digits.count)) + digits
    }

    /// `TOOL_PALETTE`, colour for colour and in order — the order is what the hash indexes.
    func testThePaletteIsTheWebsInItsOrder() throws {
        let web = try fixture().palette
        XCTAssertEqual(TileHue.toolPalette.map { hex($0.webHex) }, web)
    }

    /// Every tool the registry exports wears the colour `toolColor` gives it.
    func testEveryToolWearsTheWebsColour() throws {
        let tools = try fixture().tools
        XCTAssertGreaterThanOrEqual(tools.count, 29)
        for (id, tool) in tools {
            XCTAssertEqual(hex(TileHue.forTool(id).webHex), tool.color, "toolColor('\(id)')")
        }
    }

    /// Ids long enough to wrap the 32-bit hash many times over, and the empty one. Thirty short
    /// tool ids could agree with a hash that overflows differently; these could not.
    func testTheHashWrapsAsJavaScriptsDoes() throws {
        let hashes = try fixture().hashes
        XCTAssertGreaterThan(hashes.count, 5)
        for (id, colour) in hashes {
            XCTAssertEqual(hex(TileHue.forTool(id).webHex), colour, "toolColor('\(id)')")
        }
    }

    /// Each role's colour is `roleConfig.js`'s. Matched by label, which both sides spell alike;
    /// the web's eighth role, Devil's Advocate, is not one this app carries.
    func testEveryRoleWearsTheWebsColour() throws {
        let roles = try fixture().roles
        for role in PractitionerRole.allCases {
            let web = try XCTUnwrap(roles[role.label], "\(role.label) is not a web role")
            XCTAssertEqual(hex(role.tileHue.webHex), web, role.label)
        }
    }

    /// The picture on each tool is the one the web draws, read through `forLucide`.
    func testEveryToolCarriesTheWebsIcon() throws {
        for (id, tool) in try fixture().tools {
            let icon = try XCTUnwrap(tool.icon, "\(id) has no icon on the web")
            let symbol = try XCTUnwrap(
                ToolSymbol.forLucide[icon], "no SF Symbol for the web's \(icon), used by \(id)")
            XCTAssertEqual(ToolSymbol.symbol(for: id), symbol, "\(id) draws \(icon)")
        }
    }

    /// Every tool this app lists is one the fixture covers, so none is drawn from the fallback.
    func testEveryListedToolIsCovered() throws {
        let tools = try fixture().tools
        for tool in LEGAL_TOOLS {
            XCTAssertNotNil(tools[tool.id], "\(tool.id) is not in the platform's registry")
        }
    }

    /// The web's `shade`, including its rounding and its clamp.
    func testShadeMatchesTheWebsArithmetic() {
        // shade('#7c86c9', 0.72) on the web is #596091.
        XCTAssertEqual(TileHue.shade(0x7C86C9, by: 0.72), 0x596091)
        // 1.12 pushes 0xff past a byte, which the web clamps.
        XCTAssertEqual(TileHue.shade(0xFFFFFF, by: 1.12), 0xFFFFFF)
        XCTAssertEqual(TileHue.shade(0x000000, by: 0.5), 0x000000)
    }
}
