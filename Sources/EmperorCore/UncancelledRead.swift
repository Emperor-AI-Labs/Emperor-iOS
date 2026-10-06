import Foundation

/// Runs a read to its end even when the task that asked for it is cancelled, and hands back its
/// answer — or its own failure, never the caller's cancellation.
///
/// A screen loads in its `.task`, and SwiftUI cancels that task whenever it takes the screen off
/// and puts it back: a tab switched away and back, or — on an iPad — the Cases tab coming to the
/// front at the moment the Calendar's request replaces the case beside the docket. The
/// cancellation reaches the request, `URLSession` abandons it, and the screen is left with
/// "cancelled" for an answer it would have had a moment later. A matter stood on "Could not
/// load", and later on a spinner that never stopped: the screen came back while the cancelled
/// read was still unwinding, saw it as still loading, and was never asked again. A conversation
/// was worse off — its history unread, so its composer stayed shut.
///
/// So the read is not the screen's to cancel. It runs in a task of its own and finishes; the
/// screen that asked, whether it is still waiting or has come back, gets the result. Finishing
/// costs one response nobody may look at, and a matter or a conversation read once is kept for
/// reading offline besides.
///
/// For reads only. A write is ordered with what follows it, and has its own rules about
/// cancellation — see `ChatService.saveWorkLog`.
func uncancelledRead<T: Sendable>(
    _ read: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await Task { try await read() }.value
}
