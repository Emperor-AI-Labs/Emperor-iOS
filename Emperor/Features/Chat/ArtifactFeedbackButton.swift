import SwiftUI

/// "Feedback" on a drafted document or table, for the full-screen viewer's toolbar — the web's
/// green Feedback button in its document header. Kept apart from `ArtifactDetailView` so that
/// screen gains one line.
struct ArtifactFeedbackButton: View {
    let artifact: StreamArtifact
    var chatID: String?

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            Label("Feedback", systemImage: "text.bubble")
        }
        .accessibilityLabel("Feedback on this \(artifact.kind == .table ? "table" : "document")")
        .sheet(isPresented: $isOpen) {
            DraftFeedbackSheet(target: .artifact(artifact, chatID: chatID))
        }
    }
}
