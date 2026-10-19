import SwiftUI
import UIKit

/// "List of Annexures" under a finished draft — every document the draft cites, each opening to
/// its original or its typed copy. Drawn only when the list has something in it.
///
/// All of its behaviour is `AnnexureListViewModel`'s; this only lays it out.
struct AnnexuresCard: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    let chatID: String

    @State private var model: AnnexureListViewModel?
    @State private var opened: FilingAnnexure?

    var body: some View {
        Group {
            if let model, model.isVisible {
                content(model)
            }
        }
        .task(id: chatID) {
            let created = model ?? AnnexureListViewModel(
                chatID: chatID, service: session.filingAnnexures)
            model = created
            await created.load()
        }
        .sheet(item: $opened) { annexure in
            if let model {
                AnnexureSheet(model: model, annexure: annexure)
            }
        }
    }

    private func content(_ model: AnnexureListViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("List of Annexures")
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(AnnexureListViewModel.notice)
                .font(.brand(.footnote))
                .foregroundStyle(theme.accentText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            ForEach(model.rows) { annexure in
                Button {
                    opened = annexure
                } label: {
                    AnnexureRow(annexure: annexure)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One annexure: its mark, its title, and the form it takes in the filing.
private struct AnnexureRow: View {
    @Environment(\.theme) private var theme
    let annexure: FilingAnnexure

    var body: some View {
        HStack(spacing: Spacing.md) {
            Text(annexure.mark)
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(annexure.title)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(2)
                Text(detail)
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            RowChevron()
        }
        .padding(Spacing.md)
        .frame(minHeight: Layout.touchTarget)
        .panel(radius: Radius.card)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Annexure \(annexure.mark): \(annexure.title), \(detail)")
        .accessibilityHint("Opens the annexure")
    }

    private var detail: String {
        var parts = [annexure.formLabel]
        if let pages = annexure.pageLabel { parts.append(pages) }
        if let earlier = annexure.duplicateOf { parts.append("same document as \(earlier)") }
        return parts.joined(separator: " · ")
    }
}

/// One annexure opened: the original drawn as a PDF or a picture, the typed copy as a page, or
/// why there is nothing to show.
private struct AnnexureSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: AnnexureListViewModel
    let annexure: FilingAnnexure

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.surface2.ignoresSafeArea())
                .navigationTitle("Annexure \(annexure.mark)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await model.open(annexure) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state(for: annexure) {
        case nil, .loading:
            ProgressView(annexure.isTypedCopy ? "Preparing the typed copy…" : "Preparing the original…")
        case .original(let data, let kind):
            OriginalView(data: data, kind: kind)
        case .typedCopy(let html):
            // The same paper rendering the draft uses: JavaScript off, no network, no file access.
            DocumentWebView(html: html)
                .background(theme.paper)
        case .skipped(let reason):
            message(reason, symbol: "doc.text")
        case .failed(let reason):
            message(reason, symbol: "exclamationmark.triangle")
        case .refused(let refusal):
            RefusalCard(refusal: refusal)
                .padding(Spacing.lg)
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .font(.brand(.body))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.xl)
    }
}

/// An original document: a PDF in the shared PDF view, or a photograph fitted to the screen.
private struct OriginalView: View {
    let data: Data
    let kind: AnnexureFileKind

    var body: some View {
        if kind == .image, let image = UIImage(data: data) {
            ScrollView {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("The original document")
            }
        } else {
            PDFDataView(data: data)
        }
    }
}
