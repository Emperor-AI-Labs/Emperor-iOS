import Foundation

/// The record of an upload that is still in flight, written to disk so it outlives the process.
///
/// A foreground upload can hold its state in a `Task` because the task and the upload die
/// together. A background upload cannot: iOS may suspend the app, terminate it outright, and
/// then **relaunch it** hours later purely to hand back a finished transfer. Anything held in
/// memory is gone by then, so what a chunk needs in order to be counted — which upload it
/// belongs to, which index it was, how many there are — has to be recoverable from disk.
///
/// ## Why every chunk can be sent at once
///
/// The server writes each chunk at `chunkIndex * chunkSize`, an absolute offset, provided
/// `chunkSize` is sent. Order therefore does not matter, and neither does completing one chunk
/// before starting the next. That is what makes this tractable in the background: rather than a
/// chain where each completion enqueues its successor — which a termination would break in the
/// middle — every chunk is enqueued immediately and the system schedules, retries and reorders
/// them as it likes. This manifest is only the tally of which have landed.
///
/// The one thing that would break it is sending chunks without `chunkSize`, which puts the
/// server into append mode; then order is everything and this design corrupts the file. See
/// `MultipartChunk`, which always sends it.
struct UploadManifest: Codable, Equatable, Sendable, Identifiable {
    /// The server's `uploadId`. Stable across retries so a re-sent chunk overwrites rather
    /// than duplicating.
    let id: String
    let fileName: String
    let folderName: String
    let totalBytes: Int
    let chunkSize: Int
    /// Where the bytes are. A copy the app owns — not the security-scoped original the picker
    /// handed over, which may be revoked before the upload finishes.
    let sourcePath: String
    let createdAt: Date

    /// Indices confirmed accepted. A `Set` because the system may complete them in any order,
    /// and because re-recording one must be harmless — a relaunched app can be told about a
    /// chunk it already knew.
    private(set) var completed: Set<Int>

    init(
        id: String = UUID().uuidString,
        fileName: String,
        folderName: String,
        totalBytes: Int,
        chunkSize: Int,
        sourcePath: String,
        createdAt: Date,
        completed: Set<Int> = []
    ) {
        self.id = id
        self.fileName = fileName
        self.folderName = folderName
        self.totalBytes = max(0, totalBytes)
        // A non-positive chunk size would make `chunkCount` divide by zero and every range
        // empty, so the upload would "succeed" having sent nothing at all.
        self.chunkSize = max(1, chunkSize)
        self.sourcePath = sourcePath
        self.createdAt = createdAt
        self.completed = completed
    }

    // MARK: - Arithmetic

    /// Always at least one, so a zero-byte file is one empty chunk rather than none.
    ///
    /// An upload of no chunks would poll for ingestion of a file the server was never told
    /// about, and wait out the full timeout before reporting something vague.
    var chunkCount: Int {
        max(1, Int((Double(totalBytes) / Double(chunkSize)).rounded(.up)))
    }

    /// The byte range chunk `index` covers, clamped to the file.
    ///
    /// The last chunk is short whenever the size is not an exact multiple, which is almost
    /// always. Computing it as `chunkSize` would read past the end of the file.
    func range(of index: Int) -> Range<Int> {
        guard index >= 0, index < chunkCount else { return 0..<0 }
        let start = index * chunkSize
        let end = min(start + chunkSize, totalBytes)
        return start..<max(start, end)
    }

    var pending: [Int] {
        (0..<chunkCount).filter { !completed.contains($0) }
    }

    var isComplete: Bool {
        completed.isSuperset(of: 0..<chunkCount)
    }

    /// Summed from the actual ranges, not `completed.count * chunkSize`.
    ///
    /// The short last chunk makes those two differ, and the naive form can report more bytes
    /// sent than the file contains — a progress bar that passes 100% and stops.
    var bytesSent: Int {
        completed.reduce(0) { $0 + range(of: $1).count }
    }

    var progress: Double {
        guard totalBytes > 0 else { return isComplete ? 1 : 0 }
        return min(1, Double(bytesSent) / Double(totalBytes))
    }

    // MARK: - Mutation

    /// Idempotent by construction: the system can report the same chunk twice, and a relaunched
    /// app re-reads a manifest that already counted it.
    mutating func markCompleted(_ index: Int) {
        guard index >= 0, index < chunkCount else { return }
        completed.insert(index)
    }

    /// Identifies one chunk of one upload across a process restart.
    ///
    /// A background task survives termination but its Swift context does not, so on relaunch
    /// the only thing left to identify a transfer by is the string in `taskDescription`. It has
    /// to carry both halves: the upload it belongs to and which chunk it was.
    func taskDescription(for index: Int) -> String {
        "\(id)#\(index)"
    }

    static func parseTaskDescription(_ value: String?) -> (id: String, index: Int)? {
        guard let value, let separator = value.lastIndex(of: "#") else { return nil }
        let id = String(value[value.startIndex..<separator])
        guard !id.isEmpty,
              let index = Int(value[value.index(after: separator)...]),
              index >= 0
        else { return nil }
        return (id, index)
    }
}
