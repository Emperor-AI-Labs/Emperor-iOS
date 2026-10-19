import SwiftUI

/// Feedback on a draft, a table or an answer — the web's `DraftFeedbackButton` modal: Good or
/// Needs work, any of six categories, and what to fix. A rating or a comment is enough.
///
/// Both stores expect a product that publishes AI-generated content to give the reader a way to
/// flag it, and this is that way: the model can cite a page that does not say what it claims, and
/// a practitioner who spots it needs somewhere to put it.
///
/// When the feedback is about a draft, the draft's text goes with it, as on the web — a rating
/// with no document to look at tells a reviewer nothing. The footer says so before the tap; an
/// answer with no draft sends only its conversation's id.
struct DraftFeedbackSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(Session.self) private var session

    let target: DraftFeedbackTarget
    /// The rating the sheet opens on — a thumb tapped under an answer.
    var initialRating: DraftFeedbackRating?

    @State private var model: DraftFeedbackViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    DraftFeedbackForm(model: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(model?.title ?? "Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model?.isSending ?? false)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model?.isSending ?? false {
                        ProgressView()
                    } else {
                        Button("Submit") { submit() }
                            .disabled(!(model?.canSend ?? false))
                    }
                }
            }
        }
        .task {
            guard model == nil else { return }
            model = DraftFeedbackViewModel(
                target: target, rating: initialRating, service: session.feedback)
        }
    }

    private func submit() {
        guard let model else { return }
        Task {
            if await model.send() {
                Haptics.answerComplete()
                VoiceOver.announce(DraftFeedbackViewModel.sentMessage)
                dismiss()
            }
        }
    }
}

/// The sheet's body, split out so its sections type-check on their own.
private struct DraftFeedbackForm: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DraftFeedbackViewModel

    var body: some View {
        Form {
            if !model.target.title.isEmpty {
                Section {
                    Text(model.target.title)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                .listRowBackground(theme.surface)
            }

            Section {
                HStack(spacing: Spacing.sm) {
                    ForEach(DraftFeedbackRating.allCases) { rating in
                        RatingButton(
                            rating: rating, isOn: model.rating == rating,
                            action: { model.toggle(rating) })
                    }
                }
                .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
            } header: {
                SectionHeader(title: "How is it")
            }
            .listRowBackground(theme.surface)

            Section {
                ForEach(DraftFeedbackCategory.allCases) { category in
                    Button {
                        Haptics.selection()
                        model.toggle(category)
                    } label: {
                        HStack {
                            Text(category.label)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            if model.isSelected(category) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accentText)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.isSelected(category) ? .isSelected : [])
                }
            } header: {
                SectionHeader(title: "About")
            }
            .listRowBackground(theme.surface)

            Section {
                TextField(
                    DraftFeedbackViewModel.commentPrompt, text: $model.comment,
                    prompt: Text(DraftFeedbackViewModel.commentPrompt).foregroundStyle(theme.textTertiary),
                    axis: .vertical)
                    .lineLimit(3...8)
            } footer: {
                FeedbackFooter(model: model)
            }
            .listRowBackground(theme.surface)
        }
        .font(.brand(.body))
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
    }
}

/// Good or Needs work, as two wide buttons; tapping the chosen one again clears it.
private struct RatingButton: View {
    @Environment(\.theme) private var theme
    let rating: DraftFeedbackRating
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Label(rating.label, systemImage: isOn ? "\(rating.systemImage).fill" : rating.systemImage)
                .font(.brand(.callout, weight: .medium))
                .foregroundStyle(isOn ? theme.accentText : theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Layout.touchTarget)
                .background(
                    isOn ? theme.accentSoft : theme.surface2,
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(isOn ? theme.accentLine : theme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// What leaves the phone, the characters left near the limit, and a failed send's reason.
private struct FeedbackFooter: View {
    @Environment(\.theme) private var theme
    let model: DraftFeedbackViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let error = model.error {
                Text(error)
                    .font(.brand(.caption, weight: .medium))
                    .foregroundStyle(theme.danger)
            }
            // Said before the tap. The server keeps the first 5,000 characters and drops the
            // rest, so someone typing past the limit is told rather than cut off unawares.
            if model.remainingCharacters < 500 {
                Text("\(max(model.remainingCharacters, 0)) characters left.")
                    .font(.brand(.caption))
                    .monospacedDigit()
                    .foregroundStyle(model.remainingCharacters < 0 ? theme.danger : theme.textTertiary)
            }
            Text(model.privacyNote)
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
    }
}
