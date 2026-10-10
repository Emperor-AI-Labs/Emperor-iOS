import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Rearrange PDF — the platform's `/tools/rearrange-pdf` (`src/pages/tools/RearrangePdf.jsx`).
///
/// The instruction is honoured exactly: `9-7` counts backwards, `5x3` makes three copies, and
/// nothing is sorted or de-duplicated behind the user's back (`PageOrder`). Because the tool
/// refuses to second-guess the instruction, the instruction has to be legible before it runs —
/// so the preview below it shows every page of the result, in order, drawn from the document
/// itself. "Backwards" and "three times" are obvious at a glance there in a way they are not in
/// a line of text (`RearrangePdf.jsx:257-262`).
///
/// A plain scroll view rather than a `Form`: the preview is a lazy grid, and a grid inside a list
/// row is laid out whole — five thousand thumbnails at once for the largest instruction allowed.
struct RearrangePDFView: View {
    @Environment(\.theme) private var theme

    @State private var model: RearrangeViewModel?
    @State private var thumbnails: PageThumbnails?
    @State private var isPicking = false
    @State private var isOpening = false
    @State private var openFailure: String?
    @FocusState private var isEditing: Bool

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .navigationTitle("Rearrange PDF")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil { model = RearrangeViewModel(engine: OnDeviceToolEngine()) }
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            Task { await open(url) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditing = false }
            }
        }
    }

    private func open(_ url: URL) async {
        guard let model else { return }
        isOpening = true
        openFailure = nil
        defer { isOpening = false }
        guard let file = await ToolImport.copy(url) else {
            openFailure = PDFTools.Failure.unreadable.errorDescription
            return
        }
        guard let pageCount = await ToolImport.pageCount(of: file) else {
            openFailure = PDFTools.Failure.unreadable.errorDescription
            return
        }
        model.load(file, pageCount: pageCount)
        thumbnails = PageThumbnails(url: file.url)
    }

    // MARK: - Layout

    @ViewBuilder
    private func content(_ model: RearrangeViewModel) -> some View {
        @Bindable var bindable = model
        let parsed = model.parsed

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                sourcePanel(model)

                if model.source != nil {
                    orderPanel(model, spec: $bindable.spec, errors: parsed.errors)
                    previewPanel(model, pages: parsed.pages)
                    actionPanel(model)
                }

                OnDeviceNote()
                    .padding(.horizontal, Spacing.xs)
            }
            .frame(maxWidth: 760)
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func sourcePanel(_ model: RearrangeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source = model.source {
                ToolSourceRow(
                    name: source.name,
                    detail: "\(FileSize.format(source.bytes)) · \(model.pageCount) page\(model.pageCount == 1 ? "" : "s")",
                    change: { isPicking = true })
            } else {
                Text("Put the pages in any order you describe — including backwards, and including the same page more than once.")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    isPicking = true
                } label: {
                    Label(isOpening ? "Opening…" : "Choose a PDF", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primaryAction)
                .disabled(isOpening)
            }
            if let openFailure {
                ToolFailureRow(message: openFailure)
            }
        }
        .padding(Spacing.lg)
        .panel()
    }

    private func orderPanel(
        _ model: RearrangeViewModel, spec: Binding<String>, errors: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Page order",
                detail: "\(model.pageCount) page\(model.pageCount == 1 ? "" : "s") available")

            TextField("e.g. last, 1-4, 2x3", text: spec, axis: .vertical)
                .font(.brand(.body).monospaced())
                .lineLimit(1...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isEditing)
                .padding(Spacing.md)
                .background(
                    theme.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(isEditing ? theme.accent : theme.separator,
                                      lineWidth: isEditing ? 1.5 : 1))
                .accessibilityLabel("Page order")

            Text("Pages come out in exactly the order you write them — nothing is sorted or tidied up. Write `9-7` to count backwards, `5x3` for three copies of page 5, and repeat a page as often as you like. `all`, `reverse`, `odd`, `even`, `first` and `last` also work.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(PageOrder.examples) { example in
                        Button {
                            model.apply(example)
                        } label: {
                            Text(example.label)
                        }
                        .buttonStyle(ChipButtonStyle(isSelected: false))
                        .disabled(model.state.isRunning)
                        .accessibilityHint(example.why)
                    }
                }
            }

            if !errors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                        ToolFailureRow(message: error)
                    }
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    theme.danger.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
        .padding(Spacing.lg)
        .panel()
    }

    @ViewBuilder
    private func previewPanel(_ model: RearrangeViewModel, pages: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Result preview", detail: model.countLine)

            if pages.isEmpty {
                Text("Nothing to build yet — describe the order above.")
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 10, alignment: .top)],
                    spacing: 10
                ) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { position, page in
                        RearrangePageChip(
                            position: position, page: page, total: pages.count,
                            thumbnails: thumbnails, model: model)
                    }
                }
            }

            if let notice = model.droppedNotice {
                // Stated rather than silently fixed: leaving pages out is a legitimate thing to
                // want here, so this is a notice, not an error.
                VStack(alignment: .leading, spacing: 6) {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.warning)
                    Button("Add them to the end") { model.appendDropped() }
                        .font(.brand(.caption, weight: .semibold))
                        .buttonStyle(.borderless)
                }
            }
        }
        .padding(Spacing.lg)
        .panel()
    }

    @ViewBuilder
    private func actionPanel(_ model: RearrangeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ToolRunButton(
                title: "Rearrange", runningTitle: "Building…",
                isRunning: model.state.isRunning, isEnabled: model.canRun
            ) {
                isEditing = false
                Task { await model.run() }
            }

            Button {
                model.resetOrder()
            } label: {
                Label("Reset order", systemImage: "arrow.counterclockwise")
                    .font(.brand(.subheadline, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(model.state.isRunning)

            if let failure = model.state.failureMessage {
                ToolFailureRow(message: failure)
            }

            if let output = model.output {
                Divider()
                if let message = model.resultMessage {
                    Text(message)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                ToolResultRow(file: output)
            }
        }
        .padding(Spacing.lg)
        .panel()
    }
}

/// One slot of the result: the page as it will appear, where it sits, and what can be done to it.
///
/// The actions rewrite the instruction rather than an edited copy of the order, so the text
/// above and this grid can never disagree.
private struct RearrangePageChip: View {
    @Environment(\.theme) private var theme

    let position: Int
    let page: Int
    let total: Int
    let thumbnails: PageThumbnails?
    let model: RearrangeViewModel

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Rectangle()
                            .fill(theme.surfaceElevated)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 124)
                .background(Color.white)

                Text("\(position + 1)")
                    .font(.brand(.caption2, weight: .bold).monospacedDigit())
                    .foregroundStyle(theme.onAccent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // The picture of the page and its position badge, for the eye. The line under them
            // says both in words.
            .accessibilityHidden(true)

            HStack(spacing: 4) {
                Text("p. \(page)")
                    .font(.brand(.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityLabel("Position \(position + 1) of \(total): page \(page)")
                Spacer(minLength: 0)
                Menu {
                    Button {
                        model.move(from: position, to: position - 1)
                    } label: {
                        Label("Move earlier", systemImage: "arrow.left")
                    }
                    .disabled(position == 0)
                    Button {
                        model.move(from: position, to: position + 1)
                    } label: {
                        Label("Move later", systemImage: "arrow.right")
                    }
                    .disabled(position == total - 1)
                    Button {
                        model.duplicate(at: position)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) {
                        model.remove(at: position)
                    } label: {
                        Label("Remove from the result", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.brand(.body))
                        .foregroundStyle(theme.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Change position \(position + 1)")
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .padding(4)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .task(id: page) {
            image = thumbnails?.image(for: page)
        }
    }
}

/// Page pictures for the preview, drawn on demand and kept.
///
/// A repeated page is drawn once however many slots show it, and only the slots on screen are
/// drawn at all — the grid is lazy — so a four-hundred-page paperbook is not rasterised up front.
@MainActor
final class PageThumbnails {
    private let document: PDFDocument?
    private var cache: [Int: UIImage] = [:]

    init(url: URL) {
        document = PDFDocument(url: url)
    }

    /// The 1-based page, drawn small. `nil` for a page that is not there.
    func image(for page: Int) -> UIImage? {
        if let cached = cache[page] { return cached }
        guard let pdfPage = document?.page(at: page - 1) else { return nil }
        let image = pdfPage.thumbnail(of: CGSize(width: 180, height: 248), for: .cropBox)
        cache[page] = image
        return image
    }
}
