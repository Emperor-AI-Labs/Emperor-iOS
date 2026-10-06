import SwiftUI

// Numbered citations as the reader sees them: a small badge where the answer cites `[2]`, a
// References list drawn as a list, and a card that shows one reference with a Copy button.
//
// Everything that decides *what* is a citation lives in `AnswerCitations.swift`, where it is
// tested against the web's own `citations.js`. This file only draws what that decided.

/// Inline markdown with the answer's citations drawn as badges, built once per text.
///
/// A badge is a link to `CitationLink`'s private scheme, so it can live inside a single `Text` —
/// which is what keeps text selection, line wrapping and Dynamic Type working across it — and
/// so a tap reaches `MarkdownContentView`'s `openURL` handler like any other link.
///
/// Takes its two colours rather than the `Theme`, so it holds no reference to main-actor state
/// and is plain data like the parse it is built from.
struct CitedInline {
    let attributed: AttributedString
    /// What VoiceOver reads in place of the text: each badge spoken as "citation 2" rather
    /// than as a bare "2" in the middle of a sentence.
    let spoken: String
    /// The references this text cites, first cited first, each once.
    let references: [CitationReference]

    init(
        _ text: String, citations: CitationIndex, holdingTrailingMarker: Bool,
        badgeText: Color, badgeFill: Color
    ) {
        let linked = CitationMarkup.linked(
            text, citations: citations, holdingTrailingMarker: holdingTrailingMarker)
        if !linked.references.isEmpty, let parsed = Self.parse(linked.markdown),
           !String(parsed.characters).contains(CitationLink.scheme) {
            var drawn = AttributedString()
            var spoken = ""
            for run in parsed.runs {
                if let url = run.link, let number = CitationLink.number(from: url),
                   citations.reference(for: number) != nil {
                    drawn.append(Self.badge(number, url: url, text: badgeText, fill: badgeFill))
                    spoken += "(citation \(number))"
                } else {
                    let piece = AttributedString(parsed[run.range])
                    spoken += String(piece.characters)
                    drawn.append(piece)
                }
            }
            attributed = drawn
            self.spoken = spoken
            references = linked.references
        } else {
            // No badges, or markdown the parser could not take with them in: the text exactly
            // as it was drawn before citations existed, never half-rewritten link syntax.
            attributed = Self.parse(text) ?? AttributedString(text)
            spoken = ""
            references = []
        }
    }

    /// The number as a badge: brand face, bold, a size below the text, in the accent on a wash
    /// of it — the web's pill (`src/ui/theme.css:1479`) as far as a run of text can carry one.
    ///
    /// Footnote rather than caption: at caption size beside body text the screenshot tour showed
    /// a mark too small to notice as a link and too small to tap reliably. It still scales with
    /// Dynamic Type, and its contrast is held to the same 4.5:1 (`CitationTests`).
    private static func badge(
        _ number: Int, url: URL, text: Color, fill: Color
    ) -> AttributedString {
        // Narrow no-break spaces either side give the wash some room round the digits, and keep
        // a badge from ever being split across two lines.
        var badge = AttributedString("\u{202F}\(number)\u{202F}")
        badge.link = url
        badge.font = Font.brand(.footnote, weight: .bold)
        badge.foregroundColor = text
        badge.backgroundColor = fill
        return badge
    }

    /// `.inlineOnlyPreservingWhitespace`, NOT `.full`. `.full` strips newlines and encodes
    /// breaks as `presentationIntent` runs, which SwiftUI's `Text` ignores — every multi-paragraph
    /// draft would render as one unbroken blob.
    static func parse(_ markdown: String) -> AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible))
    }

    /// A reference's text without its markdown — for VoiceOver and for the pasteboard, where
    /// `*Vishaka*` should arrive as Vishaka.
    static func plainText(_ markdown: String) -> String {
        parse(markdown).map { String($0.characters) } ?? markdown
    }

    static func actionName(for reference: CitationReference) -> String {
        "Citation \(reference.number): \(plainText(reference.text))"
    }
}

/// Inline markdown with citation badges, sized to its text. `InlineMarkdownText` is this at the
/// full width of a block; a table cell uses it as it is.
struct CitedText: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    let text: String
    var citations: CitationIndex = .empty
    var holdingTrailingMarker = false

    var body: some View {
        rendered(CitedInline(
            text, citations: citations, holdingTrailingMarker: holdingTrailingMarker,
            badgeText: theme.accentText, badgeFill: Color(theme.palette.citationFill)))
    }

    @ViewBuilder
    private func rendered(_ inline: CitedInline) -> some View {
        if inline.references.isEmpty {
            Text(inline.attributed)
                .textSelection(.enabled)
                // `accentText`, not the app's tint. Links are text, and `accentText` is the
                // palette's colour for text in the accent (`PaletteTests` holds it to 4.5:1); the
                // tint is the fill accent, which as text on the dark canvas measures about 3.6:1.
                .tint(theme.accentText)
        } else {
            Text(inline.attributed)
                .textSelection(.enabled)
                .tint(theme.accentText)
                .accessibilityLabel(Text(verbatim: inline.spoken))
                // A badge is too small a target to find by touch with VoiceOver, so each
                // citation is also an action on the paragraph: "Citation 2: Santosh Kumar…".
                .accessibilityActions {
                    ForEach(inline.references) { reference in
                        Button {
                            if let url = CitationLink.url(for: reference.number) { openURL(url) }
                        } label: {
                            Text(verbatim: CitedInline.actionName(for: reference))
                        }
                    }
                }
        }
    }
}

/// A reference's number, drawn to match the badges in the text that cite it.
struct CitationNumberBadge: View {
    @Environment(\.theme) private var theme
    /// Wide enough for two digits, so the text of `[9]` and `[10]` starts at the same place in
    /// a list — and scaled, so that stays true at every text size.
    @ScaledMetric(relativeTo: .caption) private var minWidth: CGFloat = 26
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.brand(.caption, weight: .bold))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: minWidth)
            .background(Color(theme.palette.citationFill), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.accentMuted, lineWidth: 1))
    }
}

/// An answer's References, as a list rather than as the `[1] …` lines the model wrote.
///
/// Each entry is a row in the shape of the web's reference box (`src/ui/theme.css:1612`): a
/// faint card, the number in its pill, the reference beside it. The number opens the same card a
/// badge in the text does, for the one-tap Copy.
struct CitationReferenceList: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    /// The badge's drawn height, scaled with its number — how far its 44-point target reaches
    /// above and below it, to be handed back so the row keeps its height. On the generous side,
    /// so the target never reaches past the row's own card.
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 20
    let references: [CitationReference]
    let citations: CitationIndex

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(references) { reference in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    // The badge at the leading edge of a 44-point target, which also spaces the
                    // reference from it. Vertically the extra is given back, so a list of
                    // references keeps the height of its lines.
                    Button {
                        if let url = CitationLink.url(for: reference.number) { openURL(url) }
                    } label: {
                        CitationNumberBadge(number: reference.number)
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -max(0, (44 - badgeHeight) / 2))
                    .accessibilityLabel("Reference \(reference.number)")
                    .accessibilityHint("Shows this reference on its own, to copy")

                    InlineMarkdownText(text: reference.text, citations: citations)
                        .font(.brand(.subheadline))
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(theme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .strokeBorder(theme.separator, lineWidth: 1))
            }
        }
    }
}

/// One reference, opened from a badge: what it is, and a way to copy it.
///
/// A small sheet rather than a scroll to the References — the web scrolls and highlights, but
/// the transcript's scroll view is not this answer's to move, and a card can be read and put
/// away without losing one's place. On an iPad the sheet is the system's form sheet.
struct CitationReferenceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// Tall enough for a full case citation and the button at the default text size, and
    /// growing with Dynamic Type; the medium detent is there for anything longer.
    @ScaledMetric(relativeTo: .body) private var compactHeight: CGFloat = 260
    let reference: CitationReference

    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        CitationNumberBadge(number: reference.number)
                            .accessibilityHidden(true)
                        InlineMarkdownText(text: reference.text)
                            .font(.brand(.body))
                            .foregroundStyle(theme.textPrimary)
                    }

                    Button {
                        UIPasteboard.general.string = CitedInline.plainText(reference.text)
                        didCopy = true
                    } label: {
                        if didCopy {
                            Label("Copied", systemImage: "checkmark")
                        } else {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.primaryAction)
                    .accessibilityHint("Copies this reference")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.canvas)
            .navigationTitle("Citation \(reference.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(compactHeight), .medium])
        .presentationDragIndicator(.visible)
    }
}
