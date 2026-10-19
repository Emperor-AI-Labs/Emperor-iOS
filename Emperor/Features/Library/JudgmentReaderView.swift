import SwiftUI
import UIKit

// The judgment reader — the web's `caselaw/JudgmentView.jsx`: a header card (the court's seal,
// "A v. B", the number, Decided / Bench / Judgment by / Length, the citations as copy-able chips),
// the typeset blocks (hanging paragraph numbers, headings, quotes, lists, the cause title as rows,
// tables in monospace, the signature block), a reader bar (find, reading comfort), a contents
// sheet, and "go to paragraph". Every sentence comes from `JudgmentReaderViewModel`.

struct JudgmentReaderView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    let doc: CatalogueDocument

    @State private var model: JudgmentReaderViewModel?
    @State private var showsContents = false
    @State private var showsSettings = false
    @State private var toast: String?

    var body: some View {
        Group {
            if let model {
                JudgmentReaderBody(model: model, showsContents: $showsContents, showsSettings: $showsSettings)
            } else {
                ProgressView()
            }
        }
        .task {
            guard model == nil else { return }
            let created = JudgmentReaderViewModel(doc: doc, service: session.library, store: Preferences())
            model = created
            await created.load()
        }
        .onChange(of: model?.notice) { _, notice in
            if let notice { toast = notice; model?.notice = nil }
        }
        .recordToast($toast)
        .sheet(isPresented: $showsContents) {
            if let model { JudgmentContentsSheet(model: model) }
        }
        .sheet(isPresented: $showsSettings) {
            if let model { JudgmentReadingSettingsSheet(model: model).presentationDetents([.medium]) }
        }
    }
}

private struct JudgmentReaderBody: View {
    @Environment(\.theme) private var theme
    let model: JudgmentReaderViewModel
    @Binding var showsContents: Bool
    @Binding var showsSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            JudgmentReaderBar(model: model, showsContents: $showsContents, showsSettings: $showsSettings)
            Divider()
            if let failure = model.state.failure {
                ScrollView {
                    LibraryEmptyView(title: model.failureTitle, hint: model.failureHint, isError: !model.isMissing) {
                        if model.canRetry { Button("Try again") { Task { await model.load() } }.buttonStyle(.compactSecondaryAction) }
                        if model.offersDownload { JudgmentDownloadLink(model: model) }
                    }
                    .padding(.top, Spacing.xl)
                    Text(failure.message).font(.brand(.caption2)).foregroundStyle(theme.textTertiary).padding(.horizontal, Spacing.gutter)
                }
            } else if !model.state.hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                JudgmentPaper(model: model)
            }
        }
        .background(paperBackground)
    }

    private var paperBackground: Color {
        switch model.preferences.paper {
        case .light: return Color(PaletteColor(hex: 0xFFFFFF))
        case .sepia: return Color(PaletteColor(hex: 0xF4ECD8))
        case .dark: return Color(PaletteColor(hex: 0x17191F))
        case .auto: return theme.canvas
        }
    }
}

/// The reader's sticky toolbar: contents, find in this judgment, reading settings.
private struct JudgmentReaderBar: View {
    @Environment(\.theme) private var theme
    let model: JudgmentReaderViewModel
    @Binding var showsContents: Bool
    @Binding var showsSettings: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Spacing.sm) {
            Button { showsContents = true } label: { Image(systemName: "list.bullet.indent") }
                .accessibilityLabel(JudgmentReaderViewModel.Copy.contents)
                .disabled(!model.state.hasLoaded)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.textTertiary).accessibilityHidden(true)
                TextField(JudgmentReaderViewModel.Copy.findPrompt, text: $model.find)
                    .font(.brand(.footnote))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($findFocused)
                    .onSubmit { model.stepFind(1) }
                    .accessibilityLabel(JudgmentReaderViewModel.Copy.findPrompt)
                if let count = model.findCountLine {
                    Text(count).font(.brand(.caption2, weight: .semibold)).monospacedDigit().foregroundStyle(theme.textTertiary)
                        .accessibilityLabel("Matches \(count)")
                    Button { model.stepFind(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled(model.search.total == 0).accessibilityLabel("Previous match")
                    Button { model.stepFind(1) } label: { Image(systemName: "chevron.down") }
                        .disabled(model.search.total == 0).accessibilityLabel("Next match")
                    Button { model.clearFind(); findFocused = false } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: Layout.compactButtonHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(theme.borderStrong, lineWidth: 1))
            Button { showsSettings = true } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel(JudgmentReaderViewModel.Copy.reading)
        }
        .font(.brand(.body))
        .foregroundStyle(theme.accentText)
        .padding(.horizontal, Spacing.gutter)
        .padding(.vertical, Spacing.sm)
        .background(theme.chrome)
    }
}

/// The sheet of paper: the header card, then the blocks, drawn lazily.
private struct JudgmentPaper: View {
    @Environment(\.theme) private var theme
    let model: JudgmentReaderViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    JudgmentHeaderCard(model: model)
                        .id(JudgmentReaderViewModel.topID)
                    if let note = model.plainTextNote { readerNote(note) }
                    ForEach(Array(model.blocks.enumerated()), id: \.element.id) { index, block in
                        JudgmentBlockView(block: block, index: index, model: model)
                            .id(block.id)
                    }
                    if let note = model.noTextNote { readerNote(note) } else if !model.blocks.isEmpty {
                        Text(JudgmentReaderViewModel.Copy.end)
                            .font(.brand(.caption)).foregroundStyle(theme.textTertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, Spacing.xl)
                            .accessibilityHidden(true)
                    }
                    JudgmentDownloadLink(model: model).padding(.bottom, Spacing.xxl)
                }
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target.blockID, anchor: .top) }
            }
        }
    }

    private var horizontalPadding: CGFloat { Spacing.gutter }
    private var maxWidth: CGFloat? {
        switch model.preferences.width {
        case .narrow: return 520
        case .normal: return 680
        case .wide: return nil
        }
    }

    private func readerNote(_ text: String) -> some View {
        Text(text)
            .font(.brand(.footnote))
            .foregroundStyle(theme.textSecondary)
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .padding(.vertical, Spacing.md)
    }
}

private struct JudgmentDownloadLink: View {
    @Environment(\.theme) private var theme
    let model: JudgmentReaderViewModel

    var body: some View {
        if model.state.hasLoaded, !model.blocks.isEmpty,
           let url = ShareableFile.url(for: Data(model.plainText.utf8), named: "\(model.caseTitle.prefix(100)).txt") {
            ShareLink(item: url) {
                Label(JudgmentReaderViewModel.Copy.download, systemImage: "square.and.arrow.up")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.accentText)
            }
        }
    }
}

/// The header card: seal, court, title, number, facts, citations, actions.
private struct JudgmentHeaderCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let model: JudgmentReaderViewModel
    @State private var allCitations = false

    var body: some View {
        VStack(spacing: Spacing.md) {
            CourtSealView(court: model.court, diameter: 56)
            Text(model.court.name)
                .font(.brand(size: 11, weight: .bold, relativeTo: .caption))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.libraryHex(theme.isDark ? model.court.inkDark : model.court.ink))
            CaseLawTitleText(doc: model.doc, header: model.header, size: 24 * model.preferences.scale)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let number = model.caseNumberLine {
                Text(number).font(.brand(.footnote, weight: .medium)).foregroundStyle(theme.textSecondary).multilineTextAlignment(.center)
            }
            facts
            citations
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .accessibilityElement(children: .contain)
    }

    private var facts: some View {
        let items = model.facts
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.md, alignment: .top)], alignment: .center, spacing: Spacing.md) {
            ForEach(items, id: \.label) { fact in
                VStack(spacing: 2) {
                    LibraryCapLabel(text: fact.label)
                    Text(fact.value).font(.brand(.footnote)).foregroundStyle(theme.textPrimary).multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var citations: some View {
        let all = model.citations
        if !all.isEmpty {
            let fold = 4
            let shown = allCitations ? all : Array(all.prefix(fold))
            FlowRow(spacing: 6) {
                ForEach(shown, id: \.self) { citation in
                    Button {
                        UIPasteboard.general.string = citation
                        model.copied("Citation")
                    } label: {
                        HStack(spacing: 4) {
                            Text(citation)
                            Image(systemName: "doc.on.doc").imageScale(.small)
                        }
                        .font(.brand(.caption, weight: citation == model.neutralCitation ? .semibold : .medium))
                        .foregroundStyle(citation == model.neutralCitation ? Color.libraryHex(theme.isDark ? model.court.inkDark : model.court.ink) : theme.textSecondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 5)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy citation \(citation)")
                }
                if all.count > fold {
                    Button(allCitations ? "Fewer" : "+\(all.count - fold) more") { allCitations.toggle() }
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.lg) {
            Button {
                UIPasteboard.general.string = model.citationLine
                model.copied("Citation")
            } label: {
                Label(JudgmentReaderViewModel.Copy.copyCitation, systemImage: "quote.opening")
            }
            if let url = model.sourceURL {
                Button { openURL(url) } label: { Label(JudgmentReaderViewModel.Copy.indianKanoon, systemImage: "arrow.up.right.square") }
            }
            if let cites = model.citesLine {
                Text(cites).foregroundStyle(theme.textTertiary)
            }
        }
        .font(.brand(.caption, weight: .semibold))
        .foregroundStyle(theme.accentText)
        .buttonStyle(.plain)
    }
}

/// Buttons wrapped onto as many lines as they need.
struct FlowRow: SwiftUI.Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One typeset block, the find's hits marked.
private struct JudgmentBlockView: View {
    @Environment(\.theme) private var theme
    let block: JudgmentBlock
    let index: Int
    let model: JudgmentReaderViewModel

    private var scale: Double { model.preferences.scale }
    private var bodyFont: Font {
        model.preferences.face == .serif ? .display(size: 17 * scale, relativeTo: .body) : .brand(size: 16 * scale, relativeTo: .body)
    }
    private var ink: Color {
        switch model.preferences.paper {
        case .light, .sepia: return Color(PaletteColor(hex: 0x1B1B1B))
        case .dark: return Color(PaletteColor(hex: 0xE8E6E0))
        case .auto: return theme.textPrimary
        }
    }

    var body: some View {
        content
            .padding(.vertical, Spacing.xs)
            .padding(.vertical, block.type == "heading" ? Spacing.md : 0)
            .overlay(alignment: .leading) {
                if model.scrollTarget?.blockID == block.id, model.scrollTarget?.flash == true {
                    Rectangle().fill(theme.accent).frame(width: 3).padding(.leading, -Spacing.sm)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch block.type {
        case "heading":
            Text(marked(block.text))
                .font(block.level == 1 ? .display(size: 20 * scale, relativeTo: .title3) : .brand(size: 15 * scale, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: block.level == 1 ? .center : .leading)
                .textCase(block.level == 1 ? .uppercase : nil)
                .accessibilityAddTraits(.isHeader)
        case "cause":
            JudgmentCauseBlock(block: block, font: bodyFont, ink: ink)
        case "quote":
            if JudgmentReaderModel.isElision(block.text) {
                Text(block.text).font(bodyFont).foregroundStyle(theme.textTertiary).frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .top, spacing: Spacing.md) {
                    Rectangle().fill(theme.borderStrong).frame(width: 2)
                    Text(marked(block.text)).font(bodyFont).foregroundStyle(ink.opacity(0.9)).italic()
                }
                .padding(.leading, Spacing.lg)
            }
        case "list":
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(block.marker ?? "•").font(bodyFont).foregroundStyle(theme.textTertiary).frame(minWidth: 28, alignment: .trailing)
                Text(marked(block.text)).font(bodyFont).foregroundStyle(ink)
            }
            .padding(.leading, Spacing.md)
        case "table":
            ScrollView(.horizontal, showsIndicators: true) {
                Text(block.displayLines.joined(separator: "\n"))
                    .font(.system(size: 12 * scale, design: .monospaced))
                    .foregroundStyle(ink)
                    .padding(Spacing.sm)
            }
            .background(theme.surface2, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .accessibilityLabel("Table")
        case "meta":
            VStack(alignment: block.role == "signature" ? .trailing : .leading, spacing: 2) {
                ForEach(Array(block.displayLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.brand(size: 14 * scale, relativeTo: .footnote))
                        .foregroundStyle(JudgmentReaderModel.isCopyLine(line) ? theme.textTertiary : theme.textSecondary)
                        .multilineTextAlignment(block.role == "signature" ? .trailing : .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: block.role == "signature" ? .trailing : .leading)
            .padding(.vertical, Spacing.xs)
        default:
            if let n = block.n {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                    Button {
                        UIPasteboard.general.string = "\(n). \(block.text)"
                        model.copied("Paragraph \(n)")
                    } label: {
                        Text(n)
                            .font(.brand(size: 12 * scale, weight: .semibold, relativeTo: .caption))
                            .monospacedDigit()
                            .foregroundStyle(theme.accentText)
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Paragraph \(n). Copy it")
                    Text(marked(block.text)).font(bodyFont).foregroundStyle(ink)
                }
            } else if JudgmentReaderModel.isElision(block.text) {
                Text(block.text).font(bodyFont).foregroundStyle(theme.textTertiary).frame(maxWidth: .infinity)
            } else {
                Text(marked(block.text)).font(bodyFont).foregroundStyle(ink).padding(.leading, 30 + Spacing.sm)
            }
        }
    }

    /// The block's text with this block's hits highlighted, the current one strongest.
    private func marked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let hits = model.hits(in: index)
        guard !hits.isEmpty else { return out }
        let current = model.currentHitIndex(in: index)
        let ns = text as NSString
        for hit in hits where hit.end <= ns.length {
            let start = String.Index(utf16Offset: hit.start, in: text)
            let end = String.Index(utf16Offset: hit.end, in: text)
            guard let lower = AttributedString.Index(start, within: out), let upper = AttributedString.Index(end, within: out) else { continue }
            out[lower..<upper].backgroundColor = hit.index == current ? theme.accent : theme.accentSoft
            out[lower..<upper].foregroundColor = hit.index == current ? theme.onAccent : theme.accentText
        }
        return out
    }
}

/// The cause title as rows: parties with their roles, "Versus", the tags, the prayer.
private struct JudgmentCauseBlock: View {
    @Environment(\.theme) private var theme
    let block: JudgmentBlock
    let font: Font
    let ink: Color
    @State private var open = false

    var body: some View {
        let rows = JudgmentReaderModel.causeRows(block.displayLines)
        let fold = JudgmentReaderModel.causeFold(rows)
        let shown = (fold != nil && !open) ? Array(rows.prefix(fold!)) : rows
        VStack(alignment: .center, spacing: 4) {
            ForEach(shown) { row in
                causeRow(row)
            }
            if let fold {
                Button(open ? "Show less" : "Show the full title (\(LibraryTitles.count(rows.count - fold)) more lines)") { open.toggle() }
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .buttonStyle(.plain)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .padding(.horizontal, Spacing.sm)
        .background(theme.surface2.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func causeRow(_ row: JudgmentReaderModel.CauseRow) -> some View {
        switch row.kind {
        case .gap:
            Spacer().frame(height: Spacing.sm)
        case .versus:
            Text("Versus").font(.display(size: 14, italic: true, relativeTo: .caption)).foregroundStyle(theme.textTertiary)
        case .tag:
            Text(row.text).font(.brand(.caption2, weight: .semibold)).foregroundStyle(theme.textTertiary).textCase(.uppercase)
        case .party:
            VStack(spacing: 1) {
                Text(row.text).font(font).fontWeight(.semibold).foregroundStyle(ink).multilineTextAlignment(.center)
                if let role = row.role {
                    Text(role).font(.brand(.caption, weight: .medium)).foregroundStyle(theme.textTertiary).italic()
                }
            }
        case .caps:
            Text(row.text).font(.brand(.footnote, weight: .semibold)).foregroundStyle(ink).multilineTextAlignment(.center).textCase(.uppercase)
        case .prayer, .text:
            Text(row.text)
                .font(JudgmentReaderModel.isProse(row.text) || row.kind == .prayer ? .brand(.footnote) : .brand(.footnote, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(JudgmentReaderModel.isProse(row.text) || row.kind == .prayer ? .leading : .center)
                .frame(maxWidth: .infinity, alignment: JudgmentReaderModel.isProse(row.text) || row.kind == .prayer ? .leading : .center)
        }
    }
}

/// The contents: go to paragraph, the headings, a strip of paragraph numbers, the length.
private struct JudgmentContentsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: JudgmentReaderViewModel
    @State private var paragraph = ""

    var body: some View {
        NavigationStack {
            List {
                if model.lastParagraph != nil {
                    Section {
                        HStack {
                            TextField("1–\(model.lastParagraph ?? "")", text: $paragraph)
                                .keyboardType(.decimalPad)
                                .onSubmit(go)
                                .accessibilityLabel(JudgmentReaderViewModel.Copy.goToParagraph)
                            Button("Go", action: go).disabled(paragraph.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        SectionHeader(title: JudgmentReaderViewModel.Copy.goToParagraph)
                    }
                    .listRowBackground(theme.surface)
                }
                Section {
                    Button(JudgmentReaderViewModel.Copy.caseDetails) { model.jump(to: JudgmentReaderViewModel.topID, flash: false); dismiss() }
                    ForEach(model.headings) { heading in
                        Button {
                            model.jump(to: heading.id, flash: false)
                            dismiss()
                        } label: {
                            Text(heading.label)
                                .font(.brand(heading.level == 1 ? .body : .subheadline, weight: heading.level == 1 ? .semibold : .regular))
                                .padding(.leading, heading.level == 1 ? 0 : Spacing.md)
                        }
                    }
                } header: {
                    SectionHeader(title: JudgmentReaderViewModel.Copy.contents)
                }
                .listRowBackground(theme.surface)
                if !model.paragraphMarks.isEmpty {
                    Section {
                        FlowRow(spacing: 8) {
                            ForEach(model.paragraphMarks, id: \.id) { mark in
                                Button(String(mark.n)) { model.jump(to: mark.id); dismiss() }
                                    .buttonStyle(ChipButtonStyle(isSelected: false))
                                    .accessibilityLabel("Paragraph \(mark.n)")
                            }
                        }
                        .listRowBackground(Color.clear)
                    } header: {
                        SectionHeader(title: "Paragraphs")
                    }
                }
                if let length = model.lengthLine {
                    Section {
                        Text(length).font(.brand(.caption)).foregroundStyle(theme.textTertiary)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(JudgmentReaderViewModel.Copy.contents)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func go() {
        model.goToParagraph(paragraph)
        dismiss()
    }
}

/// Text size, serif or sans, line width, paper.
private struct JudgmentReadingSettingsSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let model: JudgmentReaderViewModel

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Text size")
                        Spacer()
                        Button { model.shrink() } label: { Text("A−").font(.brand(.footnote, weight: .semibold)) }
                            .disabled(!model.preferences.canShrink).accessibilityLabel("Smaller text")
                        Text("\(model.preferences.percent)%").font(.brand(.footnote)).monospacedDigit().frame(minWidth: 44)
                        Button { model.grow() } label: { Text("A+").font(.brand(.body, weight: .semibold)) }
                            .disabled(!model.preferences.canGrow).accessibilityLabel("Larger text")
                    }
                    .buttonStyle(.borderless)
                    Picker("Font", selection: $model.preferences.face) {
                        Text("Serif").tag(JudgmentReaderModel.Preferences.Face.serif)
                        Text("Sans").tag(JudgmentReaderModel.Preferences.Face.sans)
                    }
                    .pickerStyle(.segmented)
                    Picker("Line width", selection: $model.preferences.width) {
                        Text("Narrow").tag(JudgmentReaderModel.Preferences.Width.narrow)
                        Text("Normal").tag(JudgmentReaderModel.Preferences.Width.normal)
                        Text("Wide").tag(JudgmentReaderModel.Preferences.Width.wide)
                    }
                    .pickerStyle(.segmented)
                    Picker("Paper", selection: $model.preferences.paper) {
                        Text("Auto").tag(JudgmentReaderModel.Preferences.Paper.auto)
                        Text("Light").tag(JudgmentReaderModel.Preferences.Paper.light)
                        Text("Sepia").tag(JudgmentReaderModel.Preferences.Paper.sepia)
                        Text("Dark").tag(JudgmentReaderModel.Preferences.Paper.dark)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    SectionHeader(title: "Reading settings")
                }
                .listRowBackground(theme.surface)
            }
            .font(.brand(.body))
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle(JudgmentReaderViewModel.Copy.reading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
