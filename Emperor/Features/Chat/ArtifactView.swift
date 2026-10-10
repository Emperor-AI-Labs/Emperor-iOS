import SwiftUI
import WebKit

/// The draft: a drafted document or table on paper, full screen.
///
/// Drafts arrive as inline-styled HTML fragments — centred headings, underlined court names,
/// bordered tables of contents. A lawyer needs to see that as it will read on paper, so it is
/// rendered rather than shown as source, on the paper colour against a recessed ground.
///
/// The eye in the bar shows or hides the citation numbers on the page, remembered for the
/// account on this device (`DraftCitationsPreference`); a draft without any has no eye. Hiding is
/// a display choice — the stored draft is never rewritten — and the download menu asks again,
/// for Word and for PDF, whether to carry them.
struct ArtifactDetailView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    let artifact: StreamArtifact
    @Environment(\.dismiss) private var dismiss

    @State private var showsCitations = true
    private let preferences = Preferences()

    private var hasCitations: Bool { DraftCitations.hasMarkers(artifact.body) }

    private var shownBody: String {
        showsCitations || !hasCitations ? artifact.body : DraftCitations.withoutMarkers(artifact.body)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    switch artifact.format {
                    case .html:
                        DocumentWebView(html: shownBody)
                    case .markdown:
                        // Not monospaced source: a chronology is a table, and rendering the pipe
                        // syntax verbatim is a visibly broken answer.
                        MarkdownArtifactView(markdown: shownBody)
                    }
                }
                .background(theme.paper)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.separator, lineWidth: 1))
                .shadow(color: theme.cardShadow, radius: 12, x: 0, y: 8)
                .padding(.horizontal, 14)
                .padding(.top, Spacing.lg)

                if hasCitations {
                    Text(showsCitations
                         ? "Citation numbers point to the references in the answer."
                         : "Citations hidden on the page. Downloads still ask.")
                        .font(.brand(size: 12.5, relativeTo: .caption))
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, Spacing.md)
                        .padding(.horizontal, Spacing.lg)
                }
            }
            .background(theme.surface2.ignoresSafeArea())
            .navigationTitle(artifact.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if hasCitations {
                        Button {
                            Haptics.selection()
                            showsCitations.toggle()
                            DraftCitationsPreference.save(
                                showsCitations, to: preferences, userID: session.currentUser?.id)
                        } label: {
                            Image(systemName: showsCitations ? "eye" : "eye.slash")
                        }
                        .accessibilityLabel(showsCitations ? "Hide citations" : "Show citations")
                    }
                    // Was a share of the raw body, which handed over markup rather than a
                    // document. A drafted pleading is something an advocate files.
                    DocumentExportMenu(
                        content: artifact.body,
                        isHTML: artifact.format == .html,
                        title: artifact.title,
                        offersCitationChoice: hasCitations)
                }
            }
            .onAppear {
                showsCitations = DraftCitationsPreference.showsCitations(
                    in: preferences, userID: session.currentUser?.id)
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
/// Shared with `DraftReaderView`, which reads the same documents — so **not** file-private,
/// however much it looks like a detail of this file.
struct DocumentWebView: UIViewRepresentable {
    /// A web view does not honour Dynamic Type on its own: 17px is 17px however large the
    /// reader has set their text. Held here rather than passed in so both callers get it, and
    /// so SwiftUI re-runs `updateUIView` when the setting changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let html: String

    private var pointSize: Double {
        Double(UIFontMetrics.default.scaledValue(for: CGFloat(ArtifactDocument.basePointSize)))
    }

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
        // Compared on the rendered page rather than the fragment: the fragment is unchanged when
        // only the text size moves, and keying on it would leave the document at its old size.
        let page = ArtifactDocument.html(wrapping: html, pointSize: pointSize)
        guard context.coordinator.lastRendered != page else { return }
        context.coordinator.lastRendered = page
        view.loadHTMLString(page, baseURL: nil)
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

    /// "Citation 2, AWARD.pdf, page 3" — what VoiceOver says for a source, and the label the
    /// design gives a citation.
    static func spokenLabel(number: Int, mention: AnnexureMention) -> String {
        let name = DisplayText.fileName(mention.fileName)
        guard let start = mention.startPage else { return "Citation \(number), \(name)" }
        if let end = mention.endPage, end != start {
            return "Citation \(number), \(name), pages \(start) to \(end)"
        }
        return "Citation \(number), \(name), page \(start)"
    }

    /// The answer's Sources, as the design lists them: the number, the file and its page, and a
    /// "p. N" chip — each row opening the page it cites, the quoted words marked.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sources")
                .recordText(RecordTokens.Typography.label)
                .foregroundStyle(theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Spacing.xs)
            ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                if index > 0 {
                    // The design's dashed rule between sources.
                    Line()
                        .stroke(theme.separator, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                Button {
                    Haptics.selection()
                    VoiceOver.announce("Opening \(DisplayText.fileName(mention.fileName))"
                        + (mention.startPage.map { ", page \($0)" } ?? ""))
                    onSelect(mention)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .recordText(RecordTokens.Typography.citation)
                            .monospacedDigit()
                            .foregroundStyle(theme.accentText)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(theme.accentWash, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DisplayText.fileName(mention.fileName))
                                .font(.brand(size: 13.5, weight: .semibold, relativeTo: .footnote))
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            // The mark the document carries in the record — "Annexure P-3".
                            if !mention.mark.isEmpty {
                                Text(mention.mark)
                                    .font(.brand(size: 13.5, relativeTo: .footnote))
                                    .foregroundStyle(theme.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        PageChip(text: mention.pageDescription ?? "Open")
                    }
                    .padding(.vertical, 9)
                    .frame(minHeight: Layout.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.recordRow)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenLabel(number: index + 1, mention: mention))
                .accessibilityHint("Opens the page it cites")
            }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }

    /// A horizontal line, for the dashed rule.
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
