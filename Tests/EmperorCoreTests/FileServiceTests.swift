import XCTest
@testable import EmperorCore

final class FileServiceTests: XCTestCase {
    private func tree(_ json: String) throws -> [FileNode] {
        try JSONDecoder().decode(UserFilesResponse.self, from: Data(json.utf8)).folders
    }

    private let sample = """
    {"success":true,"folders":[
      {"name":"Partition_Suit","path":"Partition_Suit","type":"folder","files":[
        {"name":"sale_deed.pdf","path":"Partition_Suit/sale_deed.pdf","type":"file","status":"ready","favorite":false},
        {"name":"Orders","path":"Partition_Suit/Orders","type":"folder","files":[
          {"name":"stay_order.pdf","path":"Partition_Suit/Orders/stay_order.pdf","type":"file","status":"scanned","favorite":false}
        ]}
      ]},
      {"name":"loose.pdf","path":"loose.pdf","type":"file","status":"processing","favorite":true}
    ]}
    """

    /// Folders and files are mixed at every level, including the top.
    func testFlatteningFindsFilesAtEveryDepth() throws {
        let files = FileService.allFiles(in: try tree(sample))
        XCTAssertEqual(
            files.map(\.path).sorted(),
            ["Partition_Suit/Orders/stay_order.pdf", "Partition_Suit/sale_deed.pdf", "loose.pdf"])
    }

    /// The folder portion is what `/chat` and `/upload-status` expect; a root file must give
    /// an empty string, which is the server's own default on the chat path.
    func testFolderPathDerivation() throws {
        let files = FileService.allFiles(in: try tree(sample))
        let nested = try XCTUnwrap(files.first { $0.name == "stay_order.pdf" })
        let root = try XCTUnwrap(files.first { $0.name == "loose.pdf" })

        XCTAssertEqual(nested.folderPath, "Partition_Suit/Orders")
        XCTAssertEqual(root.folderPath, "")
    }

    /// A root-level file must omit `folderName` rather than send an empty one.
    func testAttachmentOmitsEmptyFolder() throws {
        let files = FileService.allFiles(in: try tree(sample))
        let root = try XCTUnwrap(files.first { $0.name == "loose.pdf" })
        XCTAssertNil(root.attachment.folderName)
        XCTAssertEqual(root.attachment.name, "loose.pdf")

        let nested = try XCTUnwrap(files.first { $0.name == "sale_deed.pdf" })
        XCTAssertEqual(nested.attachment.folderName, "Partition_Suit")
    }

    /// A scanned PDF is never OCR'd but is still usable — the model reads it visually — so it
    /// must not be presented as unavailable.
    func testReadabilityIncludesScannedFiles() throws {
        let files = FileService.allFiles(in: try tree(sample))
        XCTAssertTrue(try XCTUnwrap(files.first { $0.name == "sale_deed.pdf" }).isReadable)
        XCTAssertTrue(try XCTUnwrap(files.first { $0.name == "stay_order.pdf" }).isReadable)
        // "processing" is neither terminal nor usable yet.
        XCTAssertFalse(try XCTUnwrap(files.first { $0.name == "loose.pdf" }).isReadable)
    }

    /// Names are underscored on disk, so a user typing spaces should still find them.
    func testSearchIsInsensitiveToCaseAndSeparators() throws {
        let files = FileService.allFiles(in: try tree(sample))
        XCTAssertEqual(FileService.search("partition suit", in: files).count, 2)
        XCTAssertEqual(FileService.search("SALE_DEED", in: files).count, 1)
        // Matching on the folder path finds everything filed under a matter.
        XCTAssertEqual(FileService.search("orders", in: files).map(\.name), ["stay_order.pdf"])
        XCTAssertEqual(FileService.search("", in: files).count, 3)
        XCTAssertTrue(FileService.search("nothing-here", in: files).isEmpty)
    }

    // MARK: - Citation resolution

    /// A citation is by construction a file the model was given, so the turn's attachments
    /// are the most reliable source of its folder.
    func testCitationResolvesAgainstTurnAttachmentsFirst() throws {
        let files = FileService.allFiles(in: try tree(sample))
        let attachments = [ChatAttachment(name: "sale_deed.pdf", folderName: "Live_Matter")]
        let mention = AnnexureMention(
            fileName: "sale_deed.pdf", mark: "P-1", startPage: 3, endPage: nil)

        let resolved = CitationResolver.resolve(mention, attachments: attachments, files: files)
        XCTAssertEqual(resolved?.folderName, "Live_Matter")
    }

    /// Falling back to the library when the file was attached on an earlier turn.
    func testCitationFallsBackToTheLibrary() throws {
        let files = FileService.allFiles(in: try tree(sample))
        let mention = AnnexureMention(
            fileName: "stay_order.pdf", mark: "P-2", startPage: nil, endPage: nil)

        let resolved = CitationResolver.resolve(mention, attachments: [], files: files)
        XCTAssertEqual(resolved?.name, "stay_order.pdf")
        XCTAssertEqual(resolved?.folderName, "Partition_Suit/Orders")
    }

    /// The model is told to cite the EXACT attached name, but names are underscore-sanitised
    /// on disk — so matching has to normalise both sides or a spaced citation resolves to
    /// nothing.
    func testCitationMatchingNormalisesNames() throws {
        let files = FileService.allFiles(in: try tree(sample))
        let mention = AnnexureMention(
            fileName: "sale deed.pdf", mark: "P-1", startPage: nil, endPage: nil)

        XCTAssertEqual(
            CitationResolver.resolve(mention, attachments: [], files: files)?.name,
            "sale_deed.pdf")
    }

    func testUnresolvableCitationReturnsNil() throws {
        let files = FileService.allFiles(in: try tree(sample))
        let mention = AnnexureMention(
            fileName: "never_uploaded.pdf", mark: "P-9", startPage: nil, endPage: nil)
        XCTAssertNil(CitationResolver.resolve(mention, attachments: [], files: files))
    }

    /// Same filename in two matters is two different documents. We cannot tell them apart
    /// from a name alone, so resolution must at least be stable rather than arbitrary.
    func testAmbiguousCitationPicksStablyByPath() throws {
        let ambiguous = try tree("""
        {"folders":[
          {"name":"B_Matter","path":"B_Matter","type":"folder","files":[
            {"name":"order.pdf","path":"B_Matter/order.pdf","type":"file","status":"ready"}]},
          {"name":"A_Matter","path":"A_Matter","type":"folder","files":[
            {"name":"order.pdf","path":"A_Matter/order.pdf","type":"file","status":"ready"}]}
        ]}
        """)
        let files = FileService.allFiles(in: ambiguous)
        let mention = AnnexureMention(
            fileName: "order.pdf", mark: "P-1", startPage: nil, endPage: nil)

        XCTAssertEqual(
            CitationResolver.resolve(mention, attachments: [], files: files)?.folderName,
            "A_Matter")
    }
}
