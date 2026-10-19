import PhotosUI
import SwiftUI
import UIKit

/// "Report a bug" — the web's Help menu dialog: what happened, optional screenshots, send.
///
/// Everything it decides is `BugReportViewModel`; this lays it out and turns picked photos into
/// JPEG attachments, which needs UIKit.
struct BugReportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// The screen the report is made from.
    let screen: String

    @State private var model: BugReportViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    BugReportForm(model: model)
                } else {
                    ProgressView()
                }
            }
            .background(theme.groupedBackground)
            .navigationTitle("Report a bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model?.isSending ?? false)
                }
                ToolbarItem(placement: .confirmationAction) {
                    sendButton
                }
            }
        }
        .interactiveDismissDisabled(model?.isSending ?? false)
        .task {
            guard model == nil else { return }
            model = BugReportViewModel(screen: screen, service: session.supportFeedback)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if let model, !model.isSent {
            if model.isSending {
                ProgressView()
            } else {
                Button("Send") {
                    Task {
                        if await model.send() {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            dismiss()
                        }
                    }
                }
                .disabled(!model.canSend)
            }
        }
    }
}

private struct BugReportForm: View {
    @Environment(\.theme) private var theme
    @Bindable var model: BugReportViewModel
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        if model.isSent {
            ContentUnavailableView(
                BugReportViewModel.sentTitle,
                systemImage: "checkmark.circle",
                description: Text(BugReportViewModel.sentMessage))
        } else {
            form
        }
    }

    private var form: some View {
        List {
            Section {
                TextField(
                    "What you were doing, what you expected, and what happened instead…",
                    text: $model.description, axis: .vertical)
                    .lineLimit(4...12)
                    .disabled(model.isSending)
            } header: {
                SectionHeader(title: "What happened?")
            } footer: {
                Text("Tell us what broke — it goes straight to the team.")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
            }
            .listRowBackground(theme.surface)

            screenshotsSection

            if let error = model.error {
                Section {
                    Text(error)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.danger)
                }
                .listRowBackground(theme.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await attach(items) }
        }
    }

    private var screenshotsSection: some View {
        Section {
            ForEach(model.attachments) { file in
                BugReportAttachmentRow(file: file) { model.remove(file.id) }
            }
            PhotosPicker(
                selection: $picked,
                maxSelectionCount: max(1, model.remainingSlots),
                matching: .images
            ) {
                Label("Add screenshots (optional)", systemImage: "photo.badge.plus")
            }
            .disabled(!model.canAddAttachments)
        } footer: {
            Text("A picture of the broken screen helps most. Up to \(model.maxAttachments).")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }

    /// Each picked photo as a JPEG — whatever the library holds it as, HEIC included.
    private func attach(_ items: [PhotosPickerItem]) async {
        var jpegs: [Data] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.8)
            else { continue }
            jpegs.append(jpeg)
        }
        model.addScreenshots(jpegs)
    }
}

/// One attached screenshot, with a way to take it off.
private struct BugReportAttachmentRow: View {
    @Environment(\.theme) private var theme
    let file: SupportAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let image = UIImage(data: file.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            Text(file.name)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .foregroundStyle(theme.danger)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(file.name)")
        }
    }
}
