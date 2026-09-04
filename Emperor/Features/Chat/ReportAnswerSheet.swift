import SwiftUI

/// Reports a generated answer.
///
/// Both stores expect a product that publishes AI-generated content to give the reader a way to
/// flag it, and this app had none. It matters beyond the requirement: the model can cite a page
/// that does not say what it claims, and a practitioner who spots that has, until now, had
/// nowhere to put it.
///
/// The answer's own text is **not** attached — only the conversation id. The reported answer is
/// already stored server-side, and copying privileged client material into a second table buys
/// a reviewer nothing they cannot already reach.
struct ReportAnswerSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(Session.self) private var session

    let chatID: String?

    @State private var reason: ReportReason = .wrongLaw
    @State private var comment = ""
    @State private var isSending = false
    @State private var failure: String?
    @State private var didSend = false

    private var remaining: Int { FeedbackService.commentLimit - comment.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Reason", selection: $reason) {
                        ForEach(ReportReason.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    SectionHeader(title: "What is wrong with it")
                }

                Section {
                    TextField("Anything that would help (optional)", text: $comment, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    // Said before the tap. The server truncates a long comment rather than
                    // rejecting it, so someone typing past the limit would otherwise lose the
                    // end of their explanation and never be told.
                    if remaining < 500 {
                        Text("\(max(remaining, 0)) characters left.")
                            .foregroundStyle(remaining < 0 ? theme.danger : theme.textTertiary)
                    } else {
                        Text("The answer itself is not sent — only this conversation's id, so a reviewer can find it.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Report this answer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Send", action: send)
                    }
                }
            }
            .alert("Could not send that", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .alert("Thank you", isPresented: $didSend) {
                Button("Done") { dismiss() }
            } message: {
                Text("Someone will look at this answer.")
            }
        }
    }

    private func send() {
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await session.feedback.reportAnswer(
                    chatID: chatID, reason: reason, comment: comment)
                didSend = true
            } catch {
                // The route answers 200 with `ok: false` when it refuses, so "sent" is never
                // assumed from a status code — the service throws and it is said out loud.
                failure = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
