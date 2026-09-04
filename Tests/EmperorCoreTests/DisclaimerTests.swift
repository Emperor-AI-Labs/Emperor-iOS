import XCTest
@testable import EmperorCore

final class DisclaimerTests: XCTestCase {

    func testAcknowledgementIsRecordedAndRead() {
        let store = InMemoryPreferenceStore()
        XCTAssertFalse(Disclaimer.hasAcknowledged(store))

        Disclaimer.acknowledge(store)

        XCTAssertTrue(Disclaimer.hasAcknowledged(store))
    }

    /// The key carries a version. If the text is ever materially changed, bumping it re-prompts
    /// rather than silently relying on an acknowledgement of different words.
    func testTheKeyIsVersioned() {
        XCTAssertTrue(Disclaimer.key.hasSuffix(".v1"))
    }

    /// The substance matters more than the presence: a disclaimer that does not say what the
    /// product actually gets wrong protects nobody.
    func testTheTextSaysTheThingsThatMatter() {
        let body = Disclaimer.body.lowercased()
        XCTAssertTrue(body.contains("not legal advice"))
        XCTAssertTrue(body.contains("not a lawyer"))
        XCTAssertTrue(body.contains("open the page"), "citations are the product's core claim")
        XCTAssertTrue(body.contains("responsible"))
        XCTAssertFalse(Disclaimer.title.isEmpty)
        XCTAssertFalse(Disclaimer.acknowledgement.isEmpty)
    }

    func testPreferenceStoreDefaultsToFalseAndRoundTrips() {
        let store = InMemoryPreferenceStore()
        XCTAssertFalse(store.bool(for: "anything"))

        store.setBool(true, for: "anything")
        XCTAssertTrue(store.bool(for: "anything"))

        store.setBool(false, for: "anything")
        XCTAssertFalse(store.bool(for: "anything"))
    }
}
