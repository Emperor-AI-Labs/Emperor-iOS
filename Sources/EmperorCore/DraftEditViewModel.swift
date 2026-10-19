import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Which turn of a conversation an edit belongs to.
///
/// Position, as on the web (`withEditedDraft`): the edit goes into the assistant turn at `index`,
/// and only while that is still the last assistant turn of a conversation `messageCount` long. A
/// question asked since moves the conversation on, and the draft on screen can no longer take an
/// edit back.
struct DraftEditTarget: Equatable, Sendable {
    let index: Int
    let messageCount: Int
}

/// What the conversation did with an edit.
enum DraftEditCommitResult: Equatable, Sendable {
    /// Folded into the turn; `outcome` is what became of storing it.
    case folded(DraftEditSaveOutcome)
    /// The turn can no longer take this edit — the conversation moved on, or the message holds
    /// no document to put it in. Nothing was changed.
    case notPlaced
}

/// The conversation a draft was written in. `ChatViewModel` is the one real one.
@MainActor
protocol DraftEditCommitting: AnyObject {
    func commitDraftEdit(_ html: String, target: DraftEditTarget) async -> DraftEditCommitResult
}

/// The editing toolbar's commands — the subset of the web's `DocEditToolbar` that carries into the
/// Word file an advocate files. Each is one `document.execCommand`, so the page's own undo
/// stack stays whole.
enum DraftEditCommand: String, CaseIterable, Identifiable, Sendable {
    case bold, italic, underline
    case bulletList, numberedList
    case alignLeft, alignCentre, alignRight
    case undo, redo

    var id: String { rawValue }

    /// The `execCommand` name, and the name `queryCommandState` answers to.
    var execName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .bulletList: return "insertUnorderedList"
        case .numberedList: return "insertOrderedList"
        case .alignLeft: return "justifyLeft"
        case .alignCentre: return "justifyCenter"
        case .alignRight: return "justifyRight"
        case .undo: return "undo"
        case .redo: return "redo"
        }
    }

    var label: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .bulletList: return "Bulleted list"
        case .numberedList: return "Numbered list"
        case .alignLeft: return "Align left"
        case .alignCentre: return "Centre"
        case .alignRight: return "Align right"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }

    var systemImage: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .alignLeft: return "text.alignleft"
        case .alignCentre: return "text.aligncenter"
        case .alignRight: return "text.alignright"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        }
    }

    /// Whether the command has an on/off state worth showing.
    var hasState: Bool { self != .undo && self != .redo }

    /// In the order the toolbar lays them out: history, emphasis, lists, alignment.
    static let toolbarOrder: [DraftEditCommand] = [
        .undo, .redo, .bold, .italic, .underline, .bulletList, .numberedList,
        .alignLeft, .alignCentre, .alignRight,
    ]
}

/// The JavaScript the editing web view runs. Kept here, beside the rules it mirrors, so the view
/// only ever evaluates a string it is handed.
///
/// Every script runs in the app's own script world, never the page's: the document is
/// model-authored and its own JavaScript stays switched off while it is edited.
enum DraftEditScript {
    /// The element `ArtifactDocument.html(wrapping:)` puts the fragment in — the editable host.
    static let hostSelector = "body > .scroll"

    private static func literal(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        // Valid JSON, but not valid inside a JavaScript string before ES2019.
        return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    /// `exportHtml`'s subtraction (`editableDoc.js` `scrub`), on a clone of the host; answers the
    /// host's HTML. `DraftEdit.scrub` runs the same rules again on the string.
    private static let readBody = """
        function read(host) {
          var root = host.cloneNode(true);
          var all = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*')));
          var attrs = \(literal(DraftEdit.editAttributes.joined(separator: ",")).replacingOccurrences(of: "\"", with: "'")).split(',');
          all.forEach(function (el) {
            if (el.hasAttribute('data-ex-edit') || el.hasAttribute('data-ex-edited')) {
              attrs.forEach(function (a) { el.removeAttribute(a); });
            }
          });
          all.forEach(function (el) {
            if (el.hasAttribute('align')) {
              var v = el.getAttribute('align');
              if (v) { el.style.textAlign = v; }
              el.removeAttribute('align');
            }
          });
          Array.prototype.slice.call(root.querySelectorAll('font')).forEach(function (el) {
            var parent = el.parentNode;
            while (el.firstChild) { parent.insertBefore(el.firstChild, el); }
            parent.removeChild(el);
          });
          Array.prototype.slice.call(root.querySelectorAll('script,style,meta,link,base')).forEach(function (el) { el.remove(); });
          Array.prototype.slice.call(root.querySelectorAll('br.Apple-interchange-newline')).forEach(function (el) { el.remove(); });
          return root.innerHTML;
        }
        """

    /// Switches editing on over the rendered page and answers what it opened over — the baseline
    /// an edit is measured against, read the same way the edit will be. `null` when there is no
    /// page to edit.
    static let begin = """
        (function () {
          \(readBody)
          var host = document.querySelector('\(hostSelector)');
          if (!host) { return null; }
          host.setAttribute('contenteditable', 'true');
          host.setAttribute('spellcheck', 'true');
          host.setAttribute('data-ex-edit', '1');
          host.setAttribute('role', 'textbox');
          host.setAttribute('aria-multiline', 'true');
          try { document.execCommand('styleWithCSS', false, false); } catch (e) {}
          try { document.execCommand('defaultParagraphSeparator', false, 'p'); } catch (e) {}
          host.focus();
          return read(host);
        })()
        """

    /// The edited body, through the export funnel. `null` when there is no page.
    static let read = """
        (function () {
          \(readBody)
          var host = document.querySelector('\(hostSelector)');
          return host ? read(host) : null;
        })()
        """

    /// Switches editing off, leaving the page as it now reads.
    static let end = """
        (function () {
          var host = document.querySelector('\(hostSelector)');
          if (!host) { return null; }
          ['contenteditable', 'spellcheck', 'data-ex-edit', 'role', 'aria-multiline'].forEach(function (a) { host.removeAttribute(a); });
          host.blur();
          return 'ok';
        })()
        """

    /// Which commands are on where the caret is, as a JSON object of booleans.
    static let state: String = {
        let entries = DraftEditCommand.allCases.filter(\.hasState)
            .map { "\(literal($0.rawValue)): q(\(literal($0.execName)))" }
            .joined(separator: ", ")
        return """
            (function () {
              function q(c) { try { return document.queryCommandState(c); } catch (e) { return false; } }
              return JSON.stringify({ \(entries) });
            })()
            """
    }()

    /// Runs one command on the selection, then answers the state as `state` does.
    static func run(_ command: DraftEditCommand) -> String {
        """
        (function () {
          var host = document.querySelector('\(hostSelector)');
          if (!host || host.getAttribute('contenteditable') !== 'true') { return null; }
          try { document.execCommand(\(literal(command.execName)), false, null); } catch (e) {}
          return \(state);
        })()
        """
    }

    /// Scrolls the heading with this id to the top of the page.
    static func jump(to id: String) -> String {
        """
        (function () {
          var el = document.getElementById(\(literal(id)));
          if (!el) { return null; }
          el.scrollIntoView({ block: 'start', behavior: 'smooth' });
          return 'ok';
        })()
        """
    }

    /// The command states a `state` or `run` script answered with.
    static func activeCommands(from json: String?) -> Set<DraftEditCommand> {
        guard let data = json?.data(using: .utf8),
              let flags = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return [] }
        return Set(flags.compactMap { $0.value ? DraftEditCommand(rawValue: $0.key) : nil })
    }
}

/// Editing one drafted document in place, and saving it — the state behind the draft viewer's
/// Edit button.
///
/// One status, as the web's `useDocEditor` keeps one: reading → editing → saving → saved, kept or
/// failed, with Retry from the last two. "Saved" is a claim about the server, so it is made only
/// when the write confirmed; an edit that could not be written is still in the conversation and
/// says so. The web view is a thin bridge: it reports what it opened over and what it reads back,
/// and everything else is decided here.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class DraftEditViewModel {
    enum Phase: Equatable, Sendable {
        case reading
        case editing
        case saving
        /// The server holds the edit.
        case saved
        /// The edit is in the conversation on the phone; the next question stores it.
        case kept
        /// The write failed. The edit is still here.
        case failed
        /// The conversation moved on; the edit could not be put back.
        case notPlaced
    }

    private(set) var phase: Phase = .reading
    let title: String
    let kind: StreamArtifact.Kind
    /// The draft as it now stands — the model's, until an edit is folded in.
    private(set) var body: String
    private(set) var format: StreamArtifact.Format
    /// The page the web view shows: the body as the editor sees it, with an anchor on every heading.
    private(set) var page: String
    /// Bumped when the page must be loaded afresh although its text may not have changed — an
    /// edit thrown away leaves the typing on the page, and only a reload takes it off.
    private(set) var pageRevision = 0
    private(set) var outline: [DraftEdit.OutlineEntry]
    /// Whether this draft has been edited in this viewer.
    private(set) var isEdited = false
    /// Which toolbar commands are on where the caret is.
    var activeCommands: Set<DraftEditCommand> = []
    /// Shown while editing, when something did not work.
    private(set) var notice: String?

    /// What the editor opened over, read back from the page — the baseline "changed" is measured
    /// against. The page's own serialisation, never the string it was given.
    private var baseline: String?
    /// An edit that has not yet been confirmed stored, for Retry.
    private var pending: String?

    let target: DraftEditTarget?
    private weak var conversation: (any DraftEditCommitting)?

    /// - Parameters:
    ///   - target: the turn the draft came from, when it can take an edit back. Nil opens it
    ///     read-only.
    ///   - conversation: where an edit is folded and stored.
    init(
        artifact: StreamArtifact, target: DraftEditTarget?, conversation: (any DraftEditCommitting)?
    ) {
        self.title = artifact.title
        self.kind = artifact.kind
        self.body = artifact.body
        self.format = artifact.format
        self.target = target
        self.conversation = conversation
        let anchored = DraftEdit.anchored(DraftEdit.editableHTML(body: artifact.body, format: .html))
        self.page = anchored.html
        self.outline = artifact.format == .html ? anchored.outline : []
    }

    // MARK: - Reading

    /// Whether the page is drawn by the web view. A Markdown table is drawn natively until it is
    /// opened for editing.
    var showsPage: Bool { format == .html || phase == .editing }

    var isEditing: Bool { phase == .editing }
    var isSaving: Bool { phase == .saving }

    /// Whether the Edit button is offered at all.
    var isEditable: Bool { target != nil && conversation != nil }

    var canBeginEditing: Bool {
        isEditable && phase != .editing && phase != .saving && phase != .notPlaced
    }

    var canRetry: Bool { (phase == .failed || phase == .kept) && pending != nil }

    /// The outline is offered once there is more than one heading to move between, as the web's
    /// rail is.
    var showsOutline: Bool { showsPage && outline.count > 1 }

    /// One line on the state of the edit, or nil when there is nothing to say.
    var statusText: String? {
        switch phase {
        case .reading, .editing: return isEdited ? "Edited" : nil
        case .saving: return "Saving…"
        case .saved: return "Edited · saved"
        case .kept: return "Kept in this conversation. It is stored with your next question."
        case .failed: return "Not saved. The edit is still here — try again."
        case .notPlaced:
            return "A newer answer has arrived since this draft, so the edit cannot be put back into the conversation."
        }
    }

    var statusIsProblem: Bool { phase == .failed || phase == .notPlaced }

    // MARK: - Editing

    /// Opens the draft for editing. The view then switches the page over and reports back with
    /// `editorOpened(baseline:)`.
    func begin() {
        guard canBeginEditing else { return }
        notice = nil
        activeCommands = []
        baseline = nil
        // A Markdown table becomes the HTML table it is drawn as, and is edited as that.
        let anchored = DraftEdit.anchored(DraftEdit.editableHTML(body: body, format: format))
        page = anchored.html
        outline = anchored.outline
        phase = .editing
    }

    /// The page is editable; `baseline` is what it opened over, or nil when it could not be.
    func editorOpened(baseline: String?) {
        guard phase == .editing else { return }
        guard let baseline else {
            phase = .reading
            notice = "This draft could not be opened for editing."
            return
        }
        self.baseline = DraftEdit.scrub(baseline)
    }

    /// Whether `current` — the page as it now reads — differs from what the editor opened over.
    func hasChanges(_ current: String?) -> Bool {
        guard phase == .editing, let current, let baseline else { return false }
        return Self.normalised(DraftEdit.scrub(current)) != Self.normalised(baseline)
    }

    /// Whether closing now would lose typing — the guard the viewer asks before it goes.
    func closeNeedsConfirmation(current: String?) -> Bool { hasChanges(current) }

    /// Set when Cancel found typing to lose; the viewer asks before throwing it away.
    var isConfirmingDiscard = false

    /// Cancel, with the page as it now reads. True when there is nothing to lose and the editor
    /// can simply be closed; otherwise the viewer is asked to confirm first.
    func requestCancel(current: String?) -> Bool {
        guard closeNeedsConfirmation(current: current) else { return true }
        isConfirmingDiscard = true
        return false
    }

    /// Done: the page read back, folded into the conversation, stored.
    func finish(editedHTML: String?) async {
        guard phase == .editing else { return }
        guard let editedHTML else {
            notice = "The edit could not be read back from the page. It is still on screen."
            return
        }
        let html = DraftEdit.scrub(editedHTML).trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasChanges(html), !html.isEmpty else {
            // Nothing changed: leaving edit mode is all there is to do.
            phase = isEdited ? .saved : .reading
            return
        }
        pending = html
        await store(html)
    }

    /// Leaves edit mode without keeping what was typed. The page goes back to the draft as it
    /// stood.
    func discard() {
        isConfirmingDiscard = false
        guard phase == .editing else { return }
        let anchored = DraftEdit.anchored(DraftEdit.editableHTML(body: body, format: .html))
        page = anchored.html
        pageRevision += 1
        outline = format == .html ? anchored.outline : []
        baseline = nil
        phase = isEdited ? .saved : .reading
    }

    /// Stores the last edit again.
    func retry() async {
        guard canRetry, let pending else { return }
        await store(pending)
    }

    private func store(_ html: String) async {
        guard let conversation, let target else {
            phase = .notPlaced
            return
        }
        phase = .saving
        notice = nil
        let result = await conversation.commitDraftEdit(html, target: target)
        switch result {
        case .notPlaced:
            phase = .notPlaced
        case .folded(let outcome):
            body = html
            format = .html
            isEdited = true
            let anchored = DraftEdit.anchored(html)
            page = anchored.html
            outline = anchored.outline
            switch outcome {
            case .saved:
                pending = nil
                phase = .saved
            case .kept:
                phase = .kept
            case .failed:
                phase = .failed
            }
        }
    }

    private static func normalised(_ html: String) -> String {
        html.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension ChatViewModel: DraftEditCommitting {}
