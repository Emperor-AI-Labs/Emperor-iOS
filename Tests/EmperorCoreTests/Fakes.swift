import Foundation
@testable import EmperorCore

// Stand-ins for the three services the screens depend on. Shared across the view-model tests
// so each file states only what it is actually exercising.

final class FakeFiles: FileProviding, @unchecked Sendable {
    var tree: [FileNode] = []
    var treeError: Error?
    var data: [String: Data] = [:]
    var dataError: Error?
    /// How many times the tree was fetched. `tree()` is an expensive server-side walk, so
    /// "was it fetched at all" and "was it fetched twice" are both worth asserting.
    private(set) var treeCallCount = 0
    /// The last name passed to `fileData`, or `nil` if it was never called. Lets a test assert
    /// a document was routed *away* from `/view-file`, which is what the office-preview path
    /// has to do for a `.docx`.
    private(set) var lastRequestedName: String?

    func tree() async throws -> [FileNode] {
        treeCallCount += 1
        if let treeError { throw treeError }
        return tree
    }

    func fileData(name: String, folderName: String?) async throws -> Data {
        lastRequestedName = name
        if let dataError { throw dataError }
        return data[name] ?? Data()
    }
}

final class FakeUploads: UploadProviding, @unchecked Sendable {
    var events: [UploadService.UploadEvent] = []
    var error: Error?
    private(set) var uploadedNames: [String] = []
    private(set) var uploadedFolders: [String] = []

    func upload(
        data: Data, fileName: String, folderName: String, chunkSize: Int
    ) -> AsyncThrowingStream<UploadService.UploadEvent, Error> {
        uploadedNames.append(fileName)
        uploadedFolders.append(folderName)
        let queued = events
        let failure = error
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            for event in queued { continuation.yield(event) }
            continuation.finish()
        }
    }
}

final class FakeChatList: ChatListProviding, @unchecked Sendable {
    var chats: [ChatSummary] = []
    var error: Error?

    func chats() async throws -> [ChatSummary] {
        if let error { throw error }
        return chats
    }
}

/// A `ChatProviding` that does nothing. The citation and scan tests drive `ChatViewModel`
/// without running a turn, so the chat service only has to exist.
final class InertChat: ChatProviding, @unchecked Sendable {
    func messages(chatID: String) async throws -> [ChatMessage] { [] }
    func streamStatus(chatID: String) async throws -> StreamStatus { StreamStatus(active: false) }
    func send(
        history: [ChatMessage], chatID: String, model: ChatModel, role: ChatRole?,
        attachments: [ChatAttachment]?, webSearch: Bool
    ) async throws -> AsyncThrowingStream<ChatTurnEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Builders

/// A file the model can read. `status` matters: a `nil` status classifies as *in progress*,
/// which makes a file unattachable — an easy way to write a test that passes for the wrong
/// reason.
func readyFile(_ path: String, size: Int? = 1024) -> FileNode.StoredFile {
    FileNode.StoredFile(
        name: String(path.split(separator: "/").last ?? ""),
        path: path,
        size: size,
        status: "ready")
}

func folder(_ path: String, _ children: [FileNode]) -> FileNode {
    .folder(FileNode.Folder(
        name: String(path.split(separator: "/").last ?? ""),
        path: path,
        files: children))
}

final class FakeCases: CaseProviding, @unchecked Sendable {
    var cases: [LegalCase] = []
    var detail: CaseDetail?
    var listings: [CauseListing] = []
    var error: Error?
    var orderData = Data("%PDF-1.4 stub".utf8)
    /// `/cause-list` takes no date parameter and returns the entire history, so the client
    /// fetches once and windows locally. Counting proves it does not re-fetch per day.
    private(set) var causeListCallCount = 0
    private(set) var notesAdded: [(caseID: String, body: String)] = []
    private(set) var tasksAdded: [(caseID: String, title: String, dueDate: Date?)] = []

    func cases() async throws -> [LegalCase] {
        if let error { throw error }
        return cases
    }

    func caseDetail(id: String) async throws -> CaseDetail {
        if let error { throw error }
        guard let detail else {
            throw APIError.server(status: 404, message: "That matter could not be found.")
        }
        return detail
    }

    func causeList() async throws -> [CauseListing] {
        causeListCallCount += 1
        if let error { throw error }
        return listings
    }

    func addNote(caseID: String, title: String?, body: String) async throws {
        if let error { throw error }
        notesAdded.append((caseID, body))
    }

    func addTask(caseID: String, title: String, dueDate: Date?) async throws {
        if let error { throw error }
        tasksAdded.append((caseID, title, dueDate))
    }

    func orderDocument(for item: CaseItem, in legalCase: LegalCase) async throws -> Data {
        if let error { throw error }
        return orderData
    }
}

final class FakeNotifications: NotificationProviding, @unchecked Sendable {
    var notifications: [AppNotification] = []
    var unreadCount = 0
    var error: Error?
    private(set) var markedRead: [String] = []
    private(set) var markedAllRead = false

    func notifications(limit: Int) async throws -> [AppNotification] {
        if let error { throw error }
        return notifications
    }

    func unreadCount() async throws -> Int {
        if let error { throw error }
        return unreadCount
    }

    func markRead(id: String) async throws {
        if let error { throw error }
        markedRead.append(id)
    }

    func markAllRead() async throws {
        if let error { throw error }
        markedAllRead = true
    }
}

final class FakeOCR: OCRProviding, @unchecked Sendable {
    var job: OCRJob?
    var submitError: Error?
    var statusError: Error?
    var downloadData = Data("PK\u{03}\u{04} docx".utf8)
    private(set) var submitted: [(fileName: String, language: OCRLanguage)] = []

    func submit(data: Data, fileName: String, language: OCRLanguage) async throws -> String {
        if let submitError { throw submitError }
        submitted.append((fileName, language))
        return job?.id ?? "job_1"
    }

    func status(jobID: String) async throws -> OCRJob {
        if let statusError { throw statusError }
        guard let job else {
            throw APIError.server(status: 404, message: "That job could not be found.")
        }
        return job
    }

    func download(outputFile: String) async throws -> Data {
        downloadData
    }
}

final class FakeCalendar: CalendarProviding, @unchecked Sendable {
    var events: [ComplianceEvent] = []
    var error: Error?
    private(set) var saved: [ComplianceDraft] = []
    private(set) var deleted: [String] = []

    func events() async throws -> [ComplianceEvent] {
        if let error { throw error }
        return events
    }

    func save(_ draft: ComplianceDraft) async throws {
        if let error { throw error }
        saved.append(draft)
    }

    func delete(id: String) async throws {
        if let error { throw error }
        deleted.append(id)
    }
}

final class FakeLibrary: LibraryProviding, @unchecked Sendable {
    var categories: [LibraryCategory] = []
    var subFilters: [String] = []
    var pages: [[LibraryDocument]] = []
    var total = 0
    var error: Error?
    var documentData = Data("%PDF-1.4".utf8)
    private(set) var browseCalls: [(category: String, page: Int, search: String?, sort: LibrarySort)] = []

    func categories() async throws -> [LibraryCategory] {
        if let error { throw error }
        return categories
    }

    func subFilters(category: String) async throws -> [String] {
        if let error { throw error }
        return subFilters
    }

    func browse(
        category: String, subFilter: String?, search: String?,
        sort: LibrarySort, page: Int, pageSize: Int
    ) async throws -> (items: [LibraryDocument], total: Int) {
        browseCalls.append((category, page, search, sort))
        if let error { throw error }
        let index = page - 1
        return (index < pages.count ? pages[index] : [], total)
    }

    func document(id: Int) async throws -> Data {
        if let error { throw error }
        return documentData
    }
}
