import XCTest
@testable import EmperorCore

/// `DraftEdit` held to the platform's own JavaScript, run under Node by
/// `scripts/generate-draft-edit-fixtures.mjs`. When one of these fails after a platform change,
/// regenerate the fixture; never edit it to match.
private struct GoldenFixture: Decodable {
    struct Stored: Decodable, Equatable {
        let title: String
        let declaredType: String
        let resolvedType: String
        let content: String
    }
    struct Fold: Decodable {
        let name: String
        let html: String
        let ownerIndex: Int
        let roles: [String]
        let contents: [String]
        let lastAssistantIndex: Int
        let after: [String]?
        let storedBefore: [Stored?]
        let storedAfter: [Stored?]?
    }
    struct Strip: Decodable {
        let input: String
        let stripMeta: String
        let stripLeadingNarration: String
        let isBlockHtml: Bool
    }
    struct Shape: Decodable {
        let input: String
        let shape: String
        let asTable: String
    }
    struct StoredCase: Decodable {
        let content: String
        let stored: Stored?
    }
    let folds: [Fold]
    let strips: [Strip]
    let shapes: [Shape]
    let stored: [StoredCase]

    static let shared: GoldenFixture = try! JSONDecoder().decode(
        GoldenFixture.self, from: Data(DraftEditGolden.json.utf8))
}

private func mine(_ draft: DraftEdit.StoredDraft?) -> GoldenFixture.Stored? {
    draft.map {
        GoldenFixture.Stored(
            title: $0.title, declaredType: $0.declaredType, resolvedType: $0.resolvedType,
            content: $0.content)
    }
}

final class DraftEditGoldenTests: XCTestCase {

    func testTheFixtureCoversEveryShapeOfMessage() {
        XCTAssertGreaterThanOrEqual(GoldenFixture.shared.folds.count, 12)
        XCTAssertTrue(GoldenFixture.shared.folds.contains { $0.after == nil })
        XCTAssertTrue(GoldenFixture.shared.folds.contains { $0.after != nil })
    }

    /// `withEditedDraft` over `replaceCanvasBody`: the edit lands exactly where the web's would,
    /// and where the web leaves a conversation untouched, so does this.
    func testTheFoldMatchesTheWeb() {
        for fold in GoldenFixture.shared.folds {
            let conversation = zip(fold.roles, fold.contents).map { role, content in
                ChatMessage(role: MessageRole(rawValue: role) ?? .user, content: content)
            }
            XCTAssertEqual(
                DraftEdit.lastAssistantIndex(conversation) ?? -1, fold.lastAssistantIndex, fold.name)
            let folded = DraftEdit.withEditedDraft(
                conversation, html: fold.html, ownerIndex: fold.ownerIndex)
            XCTAssertEqual(folded?.map(\.content), fold.after, fold.name)
            if let folded {
                XCTAssertEqual(folded.map(\.role), conversation.map(\.role), fold.name)
            }
        }
    }

    /// What the server files for every message, before and after the fold — so the body the app
    /// saves over the original row is the one the server will recognise as that row.
    func testTheStoredDraftMatchesTheServer() {
        for fold in GoldenFixture.shared.folds {
            for (index, content) in fold.contents.enumerated() where fold.roles[index] == "assistant" {
                XCTAssertEqual(
                    mine(DraftEdit.storedDraft(fromMessage: content)), fold.storedBefore[index],
                    "\(fold.name) before, message \(index)")
            }
            guard let after = fold.after, let storedAfter = fold.storedAfter else { continue }
            for (index, content) in after.enumerated() where fold.roles[index] == "assistant" {
                XCTAssertEqual(
                    mine(DraftEdit.storedDraft(fromMessage: content)), storedAfter[index],
                    "\(fold.name) after, message \(index)")
            }
        }
        for item in GoldenFixture.shared.stored {
            XCTAssertEqual(mine(DraftEdit.storedDraft(fromMessage: item.content)), item.stored, item.content)
        }
    }

    func testStrippingMatchesTheWeb() {
        for strip in GoldenFixture.shared.strips {
            XCTAssertEqual(DraftEdit.stripMeta(strip.input), strip.stripMeta, strip.input)
            XCTAssertEqual(
                DraftEdit.stripLeadingNarration(strip.input), strip.stripLeadingNarration, strip.input)
            XCTAssertEqual(DraftEdit.isBlockHTML(strip.input), strip.isBlockHtml, strip.input)
        }
    }

    func testTheShapeOfADraftMatchesTheWeb() {
        for shape in GoldenFixture.shared.shapes {
            XCTAssertEqual(DraftShape.of(shape.input).rawValue, shape.shape, shape.input)
            XCTAssertEqual(
                DraftShape.resolvedType(declared: "table", content: shape.input), shape.asTable,
                shape.input)
        }
    }
}
