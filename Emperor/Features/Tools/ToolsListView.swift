import SwiftUI

/// The platform's tool registry.
///
/// These are the twenty-nine tools behind `/w/:toolId`, which is the web app's **main
/// generation surface** — its Home is a deck of cards that open them. They were absent here
/// because an earlier gap analysis filed them under "30-tool drafting workspace, canvas editing"
/// and rejected the pair together. That was right about the canvas — a contenteditable A4 page with
/// a paginating rail is a different product — and wrong about the tools, which share none of its
/// machinery.
///
/// A tool is a form, a prompt template and a rendering hint. The compiled prompt goes out as an
/// ordinary chat message; `POST /chat` has no tool field at all. So this needed nothing from the
/// server, which is why it arrives with every prompt already pinned against the platform's own
/// output.
struct ToolsListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ANALYSIS_TOOLS) { row($0) }
                } header: {
                    SectionHeader(
                        title: "Analysis",
                        detail: "Run against a document you have attached")
                }

                Section {
                    ForEach(REGISTRY_TOOLS) { row($0) }
                } header: {
                    SectionHeader(title: "Drafting, research and review")
                } footer: {
                    // The web reaches most of these only by typing `/w/<id>` — its own sidebar
                    // links five. A phone has no address bar, so without this list twenty-four
                    // of them would be unreachable rather than merely unadvertised.
                    Text("Every tool the platform ships. Each one starts a conversation you can carry on afterwards.")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("Tools")
            // This is the deepest stack in the app — a tool pushes its form, and running it
            // pushes the conversation. Both of those get a back button for free; the list they
            // sit on top of is the one place the chain ran out, so someone who ran a tool had to
            // pop twice and then guess that a swipe closes the rest.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let tool = legalTool(id) {
                    ToolFormView(tool: tool)
                } else {
                    // Ids arrive off a navigation route, so an unknown one says so rather than
                    // showing an empty form.
                    ContentUnavailableView(
                        "Tool unavailable", systemImage: "wrench.and.screwdriver")
                }
            }
        }
    }

    private func row(_ tool: ToolSpec) -> some View {
        NavigationLink(value: tool.id) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.brand(.subheadline))
                Text(tool.short)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
        }
    }
}
