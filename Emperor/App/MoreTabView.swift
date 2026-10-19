import SwiftUI

/// The **More** tab: everything that is not one of the other four.
///
/// Files and History were tabs of their own; they moved here when the bar became **Home ·
/// Matters · Ask · Calendar · More**, so both are rows below, each presenting its screen the way
/// You presents the Tools destinations — every one owns its own `NavigationStack` (see
/// `ToolDestination`), and pushing one into this stack would nest two.
///
/// Under them the web sidebar's two tool groups, **CASE TOOLS** and **DOC TOOLS**, at the
/// product owner's request. Only the rows are drawn — the case tools are not built in this app
/// yet, and the doc tools already live under You → Tools — so each is a no-op with a chevron,
/// the same stand-in the composer's wand and mic are. Wiring a row to its screen is a later
/// step; the layout and the labels are what this commit buys.
struct MoreTabView: View {
    @Environment(\.theme) private var theme

    @State private var isShowingFiles = false
    @State private var isShowingHistory = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Files", systemImage: "folder") { isShowingFiles = true }
                    row("History", systemImage: "clock") { isShowingHistory = true }
                }
                .listRowBackground(theme.surface)

                Section {
                    toolRow("Fetch Orders", systemImage: "doc.text.magnifyingglass")
                    toolRow("Devil's Advocate", systemImage: "shield")
                    toolRow("Doc Index", systemImage: "tablecells")
                    toolRow("List of Dates", systemImage: "calendar")
                } header: {
                    SectionHeader(title: "Case tools")
                }
                .listRowBackground(theme.surface)

                Section {
                    toolRow("OCR & Translate", systemImage: "doc.text.viewfinder")
                    toolRow("PDF to DOCX", systemImage: "doc.richtext")
                    toolRow("Split PDF", systemImage: "scissors")
                    toolRow("Merge PDF", systemImage: "doc.on.doc")
                } header: {
                    SectionHeader(title: "Doc tools")
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("More")
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
        }
    }

    /// A row: the tile, the label, a chevron — drawn here, as iOS supplies none for a row that
    /// presents rather than pushes. Named by its title alone, as the UI tests find it.
    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                IconRowLabel(title: title, systemImage: systemImage)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
    }

    /// A CASE TOOLS / DOC TOOLS row: drawn like `row` above, but with nowhere to go yet.
    private func toolRow(_ title: String, systemImage: String) -> some View {
        row(title, systemImage: systemImage) {}
    }
}
