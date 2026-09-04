import XCTest
@testable import EmperorCore

final class APIModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Dates

    /// The same field arrives in two formats depending on which code path wrote it: SQLite's
    /// `CURRENT_TIMESTAMP` for server-side writes, ISO-8601 for anything `POST /sync` stored.
    func testBothTimestampFormatsDecode() {
        XCTAssertNotNil(WireDate.parse("2026-08-25 09:12:44"))
        XCTAssertNotNil(WireDate.parse("2026-08-25T09:12:44.101Z"))
        XCTAssertNotNil(WireDate.parse("2026-08-25T09:12:44Z"))
        XCTAssertNil(WireDate.parse(nil))
        XCTAssertNil(WireDate.parse(""))
    }

    /// SQLite's form carries no zone marker but is always UTC. Reading it as local time would
    /// shift every history entry by the device's offset — 5.5 hours in India.
    func testSQLiteTimestampIsTreatedAsUTC() throws {
        let date = try XCTUnwrap(WireDate.parse("2026-08-25 09:12:44"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(utc.component(.hour, from: date), 9)
    }

    /// The ingest progress object uses epoch milliseconds — a different encoding from every
    /// other date on this API.
    func testEpochMillisDecoding() throws {
        let date = try XCTUnwrap(WireDate.fromEpochMillis(1_756_113_164_221))
        XCTAssertEqual(date.timeIntervalSince1970, 1_756_113_164.221, accuracy: 0.001)
    }

    // MARK: - Auth

    func testLoginResponseDecodes() throws {
        let response = try decode(AuthResponse.self, """
        {"success":true,"user":{"id":7,"email":"a@b.com","name":"Jane","avatar":null,
        "title":null,"organization":null,"preferred_model":"fast","plan":"lite",
        "planLabel":"Lite"},"token":"abc.def"}
        """)
        XCTAssertEqual(response.user.id, 7)
        XCTAssertEqual(response.user.preferredModel, "fast")
        XCTAssertEqual(response.token, "abc.def")
    }

    /// `/register` hand-builds a much smaller user object than `/login` returns, so every
    /// field beyond id/name/email has to be optional or registration fails to decode.
    func testRegisterResponseWithSparseUserDecodes() throws {
        let response = try decode(AuthResponse.self, """
        {"success":true,"user":{"id":1217,"name":"Jane","email":"a@b.com"},"token":"t"}
        """)
        XCTAssertEqual(response.user.id, 1217)
        XCTAssertNil(response.user.plan)
    }

    // MARK: - Messages

    /// Server-authored assistant messages carry no `id` — the row id is generated but never
    /// written into the stored blob.
    func testAssistantMessageWithoutIDDecodes() throws {
        let message = try decode(ChatMessage.self, """
        {"role":"assistant","content":"The suit is barred.","done":true,"isTyping":false,
        "incomplete":false,"timestamp":"2026-08-25T09:14:02.883Z",
        "usage":{"prompt_tokens":312025,"cost":0.0141}}
        """)
        XCTAssertNil(message.id)
        XCTAssertFalse(message.stableID.isEmpty)
        XCTAssertEqual(message.usage?["prompt_tokens"]?.intValue, 312025)
        XCTAssertEqual(message.role, .assistant)
    }

    /// One malformed row must not fail the whole history load.
    func testMessageMissingRoleFallsBackRatherThanThrowing() throws {
        let message = try decode(ChatMessage.self, #"{"content":"orphan row"}"#)
        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.content, "orphan row")
    }

    // MARK: - Files

    /// `/user-files` mixes files and folders at every level, including the top, so the
    /// decoder has to discriminate on `type` rather than assume homogeneity.
    func testMixedFileAndFolderTreeDecodes() throws {
        let response = try decode(UserFilesResponse.self, """
        {"success":true,"folders":[
          {"name":"Partition_Suit","path":"Partition_Suit","type":"folder","created":"2026-08-11T04:22:09.331Z",
           "files":[{"name":"deed.pdf","path":"Partition_Suit/deed.pdf","type":"file","size":4823991,
                     "modified":"2026-08-11T04:22:11.020Z","status":"ready",
                     "progress":{"stage":"done","percent":100,"etaSeconds":null,"message":"Ready"},
                     "favorite":false}]},
          {"name":"loose.pdf","path":"loose.pdf","type":"file","size":10,"status":"processing",
           "progress":null,"favorite":true}
        ]}
        """)

        XCTAssertEqual(response.folders.count, 2)
        guard case .folder(let folder) = response.folders[0] else {
            return XCTFail("Expected a folder node")
        }
        XCTAssertEqual(folder.files?.count, 1)
        guard case .file(let nested) = try XCTUnwrap(folder.files?.first) else {
            return XCTFail("Expected a nested file node")
        }
        XCTAssertEqual(nested.path, "Partition_Suit/deed.pdf")
        XCTAssertEqual(nested.progress?.percent, 100)

        guard case .file(let loose) = response.folders[1] else {
            return XCTFail("Expected a loose file at the top level")
        }
        // `progress` is genuinely null for some states and must not be forced.
        XCTAssertNil(loose.progress)
        XCTAssertEqual(loose.favorite, true)
    }

    // MARK: - Ingest state

    /// Only lowercase "ready" is the terminal signal. Capitalised "Ready" is a transient
    /// render of stage == 'done' and must not be mistaken for it.
    func testIngestStateClassification() {
        XCTAssertEqual(IngestState.classify("ready"), .ready)
        XCTAssertEqual(IngestState.classify("scanned"), .scanned)
        XCTAssertEqual(
            IngestState.classify("ERROR: Upload incomplete — please re-upload this file."),
            .failed("ERROR: Upload incomplete — please re-upload this file."))

        XCTAssertFalse(IngestState.classify("Reading page 47 of 131").isTerminal)
        XCTAssertFalse(IngestState.classify("Ready").isTerminal)
        XCTAssertTrue(IngestState.classify("ready").isUsable)
        // A scanned PDF is never OCR'd but is still usable — the model reads it visually.
        XCTAssertTrue(IngestState.classify("scanned").isUsable)
        XCTAssertFalse(IngestState.classify("ERROR: nope").isUsable)
    }

    // MARK: - Stream status

    /// This route answers 200 for errors too, and omits keys rather than nulling them.
    func testStreamStatusToleratesMissingKeys() throws {
        let error = try decode(StreamStatus.self, #"{"active":false,"error":"Forbidden"}"#)
        XCTAssertFalse(error.active)
        XCTAssertEqual(error.error, "Forbidden")
        XCTAssertNil(error.isTyping)

        let live = try decode(StreamStatus.self, """
        {"active":true,"isTyping":true,"step":"unknown","contentLength":8421,
         "content":"the draft so far","done":false,"incomplete":false,
         "incompleteReason":null,"startedAt":1756113164221,"updatedAt":1756113402883}
        """)
        XCTAssertTrue(live.active)
        XCTAssertNotNil(live.startedDate)
    }

    // MARK: - Upload naming

    /// Status polls must use the server's sanitised name or the path never resolves.
    func testFileNameSanitizationMatchesServer() {
        XCTAssertEqual(
            UploadService.sanitize(fileName: "Sale Deed (2019).pdf"),
            "Sale_Deed__2019_.pdf")
        XCTAssertEqual(UploadService.sanitize(fileName: "देखिए.pdf"), "_____.pdf")
        XCTAssertEqual(UploadService.sanitize(fileName: "already-safe_1.pdf"), "already-safe_1.pdf")
    }
}
