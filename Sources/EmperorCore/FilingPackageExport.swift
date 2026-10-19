import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Making a filing-ready package from the download menu, and what the screen shows meanwhile.
///
/// The pieces come from `FilingPackage.build`; turning them into a file is the caller's — a PDF
/// needs UIKit and PDFKit, which the core does not have — and is passed in as `render`.
///
/// `@Observable` on Apple platforms only — see `ChatViewModel` for the Linux link failure.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class FilingPackageExport {

    enum Phase: Equatable {
        case idle
        /// Under way; the share done, 0 to 1.
        case building(Double)
        /// Done: the file, ready to hand to the share sheet.
        case ready(Data, FilingPackage.Format)
        case failed(String)
        case refused(Refusal)
    }

    let chatID: String
    private let service: any FilingAnnexureProviding

    private(set) var phase: Phase = .idle

    init(chatID: String, service: any FilingAnnexureProviding) {
        self.chatID = chatID
        self.service = service
    }

    var isBuilding: Bool {
        if case .building = phase { return true }
        return false
    }

    /// The share done while building, for a progress bar.
    var fraction: Double? {
        if case .building(let value) = phase { return value }
        return nil
    }

    /// What the progress line says.
    static func label(for format: FilingPackage.Format) -> String {
        format == .pdf ? "Preparing the PDF filing package…" : "Preparing the Word filing package…"
    }

    /// Builds the package. A second request while one is under way is ignored.
    ///
    /// - Parameter render: lays the pieces out as a file. Throws to report a failure in its
    ///   own words.
    func start(
        _ format: FilingPackage.Format,
        draftHTML: String,
        render: @MainActor ([FilingPackage.Piece]) async throws -> Data
    ) async {
        guard !isBuilding else { return }
        phase = .building(0)
        do {
            let pieces = try await FilingPackage.build(
                format: format, draftHTML: draftHTML, chatID: chatID, service: service,
                progress: { [weak self] value in self?.advance(to: value) })
            let data = try await render(pieces)
            phase = .ready(data, format)
        } catch let failure as FilingPackage.Failure {
            switch failure {
            case .refused(let refusal): phase = .refused(refusal)
            case .stopped(let message): phase = .failed(message)
            }
        } catch {
            phase = .failed("The package could not be laid out. \(error.localizedDescription)")
        }
    }

    /// Progress only moves forward, so a late report cannot pull the bar back.
    private func advance(to value: Double) {
        guard case .building(let current) = phase else { return }
        phase = .building(max(current, min(value, 1)))
    }

    /// The share sheet closed, or the message was read.
    func reset() {
        guard !isBuilding else { return }
        phase = .idle
    }
}
