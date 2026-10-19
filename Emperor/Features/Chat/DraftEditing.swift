import SwiftUI
import WebKit

/// The thin bridge between `DraftEditViewModel` and the page: it runs a script and hands back
/// the string the script answered. Nothing is decided here.
///
/// Every script runs in the app's own script world (`.defaultClient`), never the page's. The page
/// is model-authored and its own JavaScript stays switched off — while it is read and while it is
/// edited — so the only code that can touch it is the code in `DraftEditScript`.
@MainActor
final class DraftWebBridge {
    fileprivate weak var webView: WKWebView?
    private var isLoaded = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// A page is about to be loaded; scripts wait for it rather than run against the old one.
    func expectLoad() { isLoaded = false }

    fileprivate func attach(_ view: WKWebView) {
        webView = view
        isLoaded = false
    }

    fileprivate func loadEnded() {
        isLoaded = true
        let ready = waiting
        waiting = []
        for continuation in ready { continuation.resume() }
    }

    /// Runs `script` once the page has loaded. Nil when there is no page, or the script failed or
    /// answered something other than a string.
    func run(_ script: String) async -> String? {
        if !isLoaded {
            await withCheckedContinuation { continuation in waiting.append(continuation) }
        }
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// A drafted document on paper, which can be switched into editing.
///
/// The same safety as `DocumentWebView`: the page's JavaScript is off, the base URL is nil, and
/// navigation to anything but the initial load is refused. A reload keeps the reader's place, so
/// coming out of an edit does not throw them back to the first page.
struct EditableDocumentWebView: UIViewRepresentable {
    /// Read so SwiftUI re-runs `updateUIView` when the text size changes — see `DocumentWebView`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let html: String
    /// Bumped to load the page afresh although `html` has not changed.
    let revision: Int
    let bridge: DraftWebBridge

    private var pointSize: Double {
        Double(UIFontMetrics.default.scaledValue(for: CGFloat(ArtifactDocument.basePointSize)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        bridge.attach(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let page = ArtifactDocument.html(wrapping: html, pointSize: pointSize)
        let key = "\(revision)\n\(page)"
        guard context.coordinator.lastRendered != key else { return }
        let isFirst = context.coordinator.lastRendered == nil
        context.coordinator.lastRendered = key
        context.coordinator.restoreOffset = isFirst ? nil : view.scrollView.contentOffset
        bridge.expectLoad()
        view.loadHTMLString(page, baseURL: nil)
    }

    /// - Important: `@MainActor` is load-bearing — see `DocumentWebView.Coordinator`. Without it
    ///   the navigation block below is silently never called.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let bridge: DraftWebBridge
        var lastRendered: String?
        var restoreOffset: CGPoint?

        init(bridge: DraftWebBridge) {
            self.bridge = bridge
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let restoreOffset {
                webView.scrollView.setContentOffset(restoreOffset, animated: false)
                self.restoreOffset = nil
            }
            bridge.loadEnded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            bridge.loadEnded()
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            bridge.loadEnded()
        }
    }
}

/// The formatting bar above the keyboard while a draft is edited.
struct DraftEditToolbar: View {
    @Environment(\.theme) private var theme
    let active: Set<DraftEditCommand>
    let onCommand: (DraftEditCommand) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(DraftEditCommand.toolbarOrder) { command in
                    DraftEditToolbarButton(
                        command: command, isOn: active.contains(command),
                        action: { onCommand(command) })
                    if command == .redo || command == .underline || command == .numberedList {
                        Rectangle()
                            .fill(theme.separator)
                            .frame(width: 1, height: 20)
                            .padding(.horizontal, Spacing.xs)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xxs)
        }
        .background(theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: 1)
        }
    }
}

private struct DraftEditToolbarButton: View {
    @Environment(\.theme) private var theme
    let command: DraftEditCommand
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: command.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isOn ? theme.accentText : theme.textSecondary)
                .frame(width: Layout.touchTarget, height: Layout.touchTarget)
                .background(
                    isOn ? theme.accentWash : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(command.label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The draft's headings, each one a jump to where it is on the page — the web's index rail.
struct DraftOutlineSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let outline: [DraftEdit.OutlineEntry]
    let onSelect: (DraftEdit.OutlineEntry) -> Void

    var body: some View {
        NavigationStack {
            List(outline) { entry in
                Button {
                    onSelect(entry)
                    dismiss()
                } label: {
                    Text(entry.text)
                        .font(.brand(.body, weight: entry.level == 1 ? Font.Weight.semibold : Font.Weight.regular))
                        .foregroundStyle(theme.textPrimary)
                        .dynamicLineLimit(2)
                        .padding(.leading, CGFloat(max(0, entry.level - 1)) * 14)
                        .frame(maxWidth: .infinity, minHeight: Layout.touchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Scrolls the draft to this heading")
            }
            .listStyle(.plain)
            .navigationTitle("Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Where the edit stands, under the page: "Saving…", "Edited · saved", or what went wrong and a
/// Retry.
struct DraftEditStatusLine: View {
    @Environment(\.theme) private var theme
    let text: String
    let isProblem: Bool
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(text)
                .font(.brand(size: 12.5, relativeTo: .caption))
                .foregroundStyle(isProblem ? theme.danger : theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(.brand(size: 12.5, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(theme.accentText)
                    .frame(minHeight: Layout.touchTarget)
                    .accessibilityHint("Tries saving the edit again")
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .accessibilityElement(children: .combine)
    }
}
