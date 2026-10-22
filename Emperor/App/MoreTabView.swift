import SwiftUI

/// The **More** tab: the workspace's own screens, then the two tool groups.
///
/// Files, History, All Notifications and Library are the workspace management rows — each
/// presents its screen the way You presents the Tools destinations (every one owns its own
/// `NavigationStack`; see `ToolDestination`). Under them the web sidebar's **Case tools** and
/// **Doc tools**: the case tools are drawn as cards — they are not built in this app yet, so
/// each is a stand-in the same way the composer's wand and mic are — and the doc tools are wired
/// to the screens they already have (OCR, the PDF tools). The search field filters every row
/// on the screen, as a search on a screen of destinations should.
struct MoreTabView: View {
    @Environment(\.theme) private var theme

    @State private var query = ""
    @State private var isShowingFiles = false
    @State private var isShowingHistory = false
    @State private var isShowingNotifications = false
    @State private var tool: ToolDestination?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RecordSearchField(text: $query, prompt: "Search tools, files, or utilities")
                        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md))
                        .listRowBackground(Color.clear)
                }

                if matches("Files") || matches("History") || matches("Notifications")
                    || matches("Library") {
                    Section {
                        if matches("Files") {
                            row("Files", systemImage: "folder",
                                subtitle: "Annexures, validations & drafts") { isShowingFiles = true }
                        }
                        if matches("History") {
                            row("History", systemImage: "clock",
                                subtitle: "Saved research threads, queries & citations") { isShowingHistory = true }
                        }
                        if matches("Notifications") {
                            row("All Notifications", systemImage: "bell.badge",
                                subtitle: "Daily cause list alerts, bench updates & listings") { isShowingNotifications = true }
                        }
                        if matches("Library") {
                            row("Library", systemImage: "books.vertical",
                                subtitle: "Bare Acts, SCC digests, High Court compendiums") { tool = .library }
                        }
                    } header: {
                        SectionHeader(title: "Workspace management")
                    }
                    .listRowBackground(theme.surface)
                }

                if caseToolItems.contains(where: { matches($0.title) }) {
                    Section {
                        caseToolGrid
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.sm, bottom: Spacing.xs, trailing: Spacing.sm))
                            .listRowBackground(Color.clear)
                    } header: {
                        SectionHeader(title: "Case tools", detail: "Litigation suite")
                    }
                }

                if docToolItems.contains(where: { matches($0.title) }) {
                    Section {
                        ForEach(docToolItems.filter { matches($0.title) }) { item in
                            docToolRow(item)
                        }
                    } header: {
                        SectionHeader(title: "Doc tools", detail: "PDF & document engine")
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("More services & tools")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $isShowingFiles) {
                // The Files tab's own title, with Done to leave the sheet — the pair the UI
                // tests open it by.
                MyFilesView(isTab: true, onDone: { isShowingFiles = false })
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingHistory) {
                ChatListView(onDone: { isShowingHistory = false })
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingNotifications) {
                NotificationsView()
                    .pageSizedSheet()
            }
            .sheet(item: $tool) { chosen in
                chosen.screen
                    .pageSizedSheet()
            }
        }
    }

    // MARK: - Workspace rows

    /// A workspace row: the tile, the label and its subtitle, a chevron — drawn here, as iOS
    /// supplies none for a row that presents rather than pushes. Named by its title alone, as
    /// the UI tests find it.
    private func row(
        _ title: String, systemImage: String, subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                IconTile(systemImage: systemImage)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title)
                        .font(.brand(.body, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                    Text(subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(2)
                }
                Spacer(minLength: Spacing.sm)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
    }

    // MARK: - Case tools

    /// One drawn case-tool card; nowhere to go yet, the same stand-in the doc rows were before
    /// their screens were wired.
    private struct CaseTool: Identifiable {
        let title: String
        let subtitle: String
        let systemImage: String
        let tag: String
        var id: String { title }
    }

    private var caseToolItems: [CaseTool] {
        [
            CaseTool(title: "Fetch Orders", subtitle: "Autopull from SC & Delhi HC portals",
                     systemImage: "doc.text.magnifyingglass", tag: "Live Court"),
            CaseTool(title: "Devil's Advocate", subtitle: "AI adversary cross-exam prep",
                     systemImage: "shield", tag: "Adversary AI"),
            CaseTool(title: "Doc Index", subtitle: "Pagination & court filing indices",
                     systemImage: "tablecells", tag: "E-Filing"),
            CaseTool(title: "List of Dates", subtitle: "Chronology generator for SLP & writs",
                     systemImage: "calendar", tag: "SLP Ready"),
        ]
    }

    /// The mock's two-up cards, as a grid of Record panels — SF Symbol, title, one line of
    /// what it is, and the product tag, all in the kit's type and radii.
    private var caseToolGrid: some View {
        let columns = [GridItem(.flexible(), spacing: Spacing.sm),
                       GridItem(.flexible(), spacing: Spacing.sm)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.sm) {
            ForEach(caseToolItems.filter { matches($0.title) }) { item in
                caseToolCard(item)
            }
        }
    }

    private func caseToolCard(_ item: CaseTool) -> some View {
        Button {
            // Not built in this app yet — the card is the promise, the wiring is a later step.
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                IconTile(systemImage: item.systemImage)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(item.title)
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                    Text(item.subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(2)
                }
                StatusPill(text: item.tag, tone: .accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 132, alignment: .topLeading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.title))
        .accessibilityHint(Text(item.subtitle))
    }

    // MARK: - Doc tools

    private struct DocTool: Identifiable {
        let title: String
        let subtitle: String
        let systemImage: String
        let destination: ToolDestination
        var id: String { title }
    }

    /// The web's document engine, row for row. Every one opens the screen it names — OCR and
    /// the PDF tools already exist under You's Tools; each row here is a second way in.
    private var docToolItems: [DocTool] {
        [
            DocTool(title: "OCR & Translate", subtitle: "Extract text from scans; translate documents",
                    systemImage: "doc.text.viewfinder", destination: .ocr),
            DocTool(title: "PDF to DOCX", subtitle: "Convert PDFs with margins, stamps & typography",
                    systemImage: "doc.richtext", destination: .fileTools),
            DocTool(title: "Split PDF", subtitle: "Separate petition, annexures & impugned orders",
                    systemImage: "scissors", destination: .fileTools),
            DocTool(title: "Merge PDF", subtitle: "Combine into one paper-book with automated index",
                    systemImage: "doc.on.doc", destination: .fileTools),
            DocTool(title: "Rearrange PDF", subtitle: "Drag & drop reordering of petition pages",
                    systemImage: "arrow.up.arrow.down", destination: .fileTools),
            DocTool(title: "Compress PDF", subtitle: "Shrink size for High Court e-filing",
                    systemImage: "archivebox", destination: .fileTools),
            DocTool(title: "Image to PDF", subtitle: "Convert receipts, certified deeds & exhibits",
                    systemImage: "photo.on.rectangle", destination: .fileTools),
            DocTool(title: "Compress Image", subtitle: "Optimise signature & stamp files",
                    systemImage: "photo.badge.arrow.down", destination: .fileTools),
        ]
    }

    private func docToolRow(_ item: DocTool) -> some View {
        Button {
            tool = item.destination
        } label: {
            HStack(spacing: Spacing.sm) {
                IconTile(systemImage: item.systemImage)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(item.title)
                        .font(.brand(.body, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                    Text(item.subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(2)
                }
                Spacer(minLength: Spacing.sm)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(item.title))
    }

    // MARK: - Search

    /// Case-insensitive contains, so an empty query shows everything.
    private func matches(_ text: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(needle)
    }
}
