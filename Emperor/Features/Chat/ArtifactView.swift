import SwiftUI
import WebKit

/// Full-page presentation of a drafted document or table.
///
/// Drafts arrive as inline-styled HTML fragments — centred headings, underlined court names,
/// bordered tables of contents. A lawyer needs to see that as it will read on paper, so it is
/// rendered rather than shown as source.
struct ArtifactDetailView: View {
    @Environment(\.theme) private var theme
    let artifact: StreamArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch artifact.format {
                case .html:
                    DocumentWebView(html: artifact.body)
                case .markdown:
                    // Not monospaced source: a chronology is a table, and rendering the pipe
                    // syntax verbatim is a visibly broken answer.
                    MarkdownArtifactView(markdown: artifact.body)
                }
            }
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: artifact.body) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

/// Renders a model-authored HTML fragment. The page wrapper is `ArtifactDocument.html`.
///
/// - Important: this content is model-authored and never sanitised upstream — the platform's
///   web renderer uses `rehype-raw` with no `rehype-sanitize`. So JavaScript is disabled, and
///   the base URL is nil, meaning no network loads and no local file access. Navigation to
///   anything other than the initial load is refused.
private struct DocumentWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        // Keep any cookies or storage out of the shared pool.
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastRendered != html else { return }
        context.coordinator.lastRendered = html
        view.loadHTMLString(ArtifactDocument.html(wrapping: html), baseURL: nil)
    }

    /// - Important: `@MainActor` is load-bearing, not decoration. `WKNavigationDelegate` is
    ///   main-actor isolated under Swift 6, so an un-isolated conformance leaves the method
    ///   *nearly* matching the optional requirement — it compiles with a warning and is then
    ///   **never called**. The navigation block below is the only thing stopping a link in
    ///   model-authored markup from navigating this web view, so silently not running it is a
    ///   security failure, not a cosmetic one.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRendered: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Only the initial in-memory load is permitted; a link in model-authored markup
            // must not be able to navigate this view anywhere.
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}

/// The paper trail: which document and page an answer rests on.
///
/// This is the platform's central claim — nothing is offered on trust — so citations get
/// their own affordance rather than being buried in the prose.
struct CitationStrip: View {
    @Environment(\.theme) private var theme
    let mentions: [AnnexureMention]
    var onSelect: (AnnexureMention) -> Void

    private func citationLabel(for mention: AnnexureMention) -> String {
        let name = DisplayText.fileName(mention.fileName)
        guard let pages = mention.pageDescription else { return name }
        return "\(name), \(pages)"
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(mentions) { mention in
                    Button {
                        onSelect(mention)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text(DisplayText.fileName(mention.fileName))
                                .lineLimit(1)
                            if let pages = mention.pageDescription {
                                Text(pages).foregroundStyle(theme.textSecondary)
                            }
                        }
                        .font(.brand(.caption2))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // Read as one phrase. Separately, VoiceOver announces a filename and a
                    // page number with no relationship between them.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(citationLabel(for: mention))
                    .accessibilityHint("Opens the source document at the cited page")
                }
            }
            .padding(.vertical, 1)
        }
    }
}
