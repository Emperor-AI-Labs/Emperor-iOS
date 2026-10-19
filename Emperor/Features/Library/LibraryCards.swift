import SwiftUI

// The Library's small shared pieces — the web's `DocCard`, `BookCard`, `Shelf`, `FacetChips`,
// `YearRange`, `LibraryEmpty`: a document as a card, a titled row of covers on a plank, the
// filter chips, a year range, and what a shelf says when it holds nothing.

/// A document as a card: its cover, its title, a meta line. Grid (cover above, label below) or
/// list (small cover left, title and facts right, with the court badge and a passage).
struct LibraryDocCard: View {
    @Environment(\.theme) private var theme

    let doc: CatalogueDocument
    var variant: LibraryCollectionProfile.Layout = .grid
    var caption: LibraryCaption?
    var badge: String?
    var query: String?
    let onOpen: (CatalogueDocument) -> Void

    private var title: String { caption?.title ?? LibraryTitles.tidyTitle(doc) }
    private var facts: [String] {
        let all = caption?.meta ?? LibraryTitles.meta(doc)
        // A list row's badge (often the court) is not repeated in its meta line.
        return all.filter { !(variant == .list && $0 == badge) }
    }

    var body: some View {
        Button {
            onOpen(doc)
        } label: {
            if variant == .list { listLabel } else { gridLabel }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibleName))
        .accessibilityHint("Opens the document")
    }

    private var accessibleName: String {
        var parts: [String] = []
        if let eyebrow = caption?.eyebrow { parts.append(eyebrow) }
        if let headline = caption?.headline { parts.append(headline) }
        parts.append(title)
        parts.append(contentsOf: facts)
        return parts.joined(separator: ", ")
    }

    private var gridLabel: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LibraryCoverView(doc: doc, size: .fill, headline: caption?.headline, kicker: caption?.kicker)
                .overlay(alignment: .bottomTrailing) { callNumber }
            LibraryCardCaption(title: title, facts: facts, eyebrow: caption?.eyebrow, headline: caption?.headline)
        }
        .contentShape(Rectangle())
    }

    private var listLabel: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            LibraryCoverView(doc: doc, size: .small, image: doc.isPDF, headline: caption?.headline, kicker: caption?.kicker)
            VStack(alignment: .leading, spacing: 3) {
                Text(badge ?? doc.theme.cap)
                    .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(doc.theme.ink(dark: theme.isDark)))
                LibraryCardCaption(title: title, facts: facts, eyebrow: caption?.eyebrow, headline: caption?.headline)
                if let bench = doc.bench?.nilIfEmpty {
                    Text("Bench: \(bench)")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                }
                if let snippet = doc.snippet {
                    LibraryPassageText(snippet: snippet, query: query ?? "")
                }
            }
            Spacer(minLength: 0)
            RowChevron()
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var callNumber: some View {
        if let label = caption?.label {
            VStack(spacing: 0) {
                Text(label.top.uppercased())
                    .font(.brand(size: 8, weight: .bold, relativeTo: .caption2))
                if !label.bottom.isEmpty {
                    Text(label.bottom)
                        .font(.brand(size: 8, weight: .medium, relativeTo: .caption2))
                }
            }
            .foregroundStyle(Color(PaletteColor(hex: 0x2B2A26)))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color(PaletteColor(hex: 0xF3EBD6)), in: RoundedRectangle(cornerRadius: 1.5))
            .padding(.trailing, 8)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
        }
    }
}

/// The words under a cover: an eyebrow, a serif headline, the title, the facts.
struct LibraryCardCaption: View {
    @Environment(\.theme) private var theme
    let title: String
    let facts: [String]
    var eyebrow: String?
    var headline: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let eyebrow {
                Text(eyebrow)
                    .font(.brand(.caption2, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            if let headline {
                Text(headline)
                    .font(.display(size: 15, relativeTo: .subheadline))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            Text(title)
                .font(.brand(.subheadline, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.leading)
                .dynamicLineLimit(3)
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.brand(.caption2))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }
        }
    }
}

/// A matched passage, the query's words marked.
struct LibraryPassageText: View {
    @Environment(\.theme) private var theme
    let snippet: LibrarySnippet
    let query: String

    var body: some View {
        Text(marked)
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(3)
    }

    private var marked: AttributedString {
        var text = AttributedString((snippet.before ? "… " : "") + snippet.text + (snippet.after ? " …" : ""))
        let terms = query.replacingOccurrences(of: "\"", with: "").split(separator: " ").map(String.init).filter { $0.count >= 2 }
        let plain = String(text.characters)
        for term in terms {
            var searchFrom = plain.startIndex
            while let found = plain.range(of: term, options: [.caseInsensitive], range: searchFrom..<plain.endIndex) {
                if let lower = AttributedString.Index(found.lowerBound, within: text),
                   let upper = AttributedString.Index(found.upperBound, within: text) {
                    text[lower..<upper].backgroundColor = theme.accentSoft
                    text[lower..<upper].foregroundColor = theme.accentText
                }
                searchFrom = found.upperBound
            }
        }
        return text
    }
}

/// A titled row of covers standing on a plank — the web's `Shelf`.
struct LibraryShelfRow<Card: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    var blurb: String?
    var count: Int?
    var ink: Color?
    var onSeeAll: (() -> Void)?
    @ViewBuilder let cards: () -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LibrarySectionHeading(title: title, blurb: blurb, count: count, ink: ink, onSeeAll: onSeeAll)
                .padding(.horizontal, Spacing.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.md) { cards() }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.bottom, Spacing.md)
            }
            .background(alignment: .bottom) {
                // The plank: the one warm note in the cool Record palette.
                Rectangle()
                    .fill(LinearGradient(colors: [Color(PaletteColor(hex: 0x8A6A3F)), Color(PaletteColor(hex: 0x6B4F2E))], startPoint: .top, endPoint: .bottom))
                    .frame(height: 8)
                    .padding(.bottom, Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A serif heading with a count beside it and "See all" at the far edge.
struct LibrarySectionHeading: View {
    @Environment(\.theme) private var theme
    let title: String
    var blurb: String?
    var count: Int?
    var ink: Color?
    var onSeeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(title)
                    .font(.display(size: 20, relativeTo: .title3))
                    .foregroundStyle(ink ?? theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let count {
                    Text(LibraryTitles.count(count))
                        .font(.brand(.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer(minLength: Spacing.sm)
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        HStack(spacing: 4) {
                            Text("See all")
                            Image(systemName: "arrow.right").imageScale(.small)
                        }
                        .font(.brand(.caption, weight: .semibold))
                        .foregroundStyle(ink ?? theme.accentText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all \(title)")
                }
            }
            if let blurb {
                Text(blurb)
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One filter chip: its words and, where it has one, its count.
struct LibraryChip: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(title: title, count: count, isSelected: isSelected)
        }
        .buttonStyle(ChipButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A row of chips for one facet: "All", then each choice with its count.
struct LibraryFacetChipsRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let options: [LibraryFacetOption]
    let selection: String?
    var allLabel = "All"
    var labelFor: ((LibraryFacetOption) -> String)?
    let onPick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            LibraryCapLabel(text: label)
                .padding(.horizontal, Spacing.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs + 2) {
                    LibraryChip(title: allLabel, isSelected: selection == nil) { onPick(nil) }
                    ForEach(options) { option in
                        LibraryChip(
                            title: labelFor?(option) ?? option.displayLabel,
                            count: option.count,
                            isSelected: selection == option.value
                        ) { onPick(option.value) }
                    }
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.vertical, 2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The A–Z bar: a letter with nothing in it is shown but cannot be chosen.
struct LibraryLetterRow: View {
    @Environment(\.theme) private var theme
    let letters: [LibraryLetterCount]
    let selection: String?
    let onPick: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(letters) { entry in
                    let on = selection == entry.letter
                    Button {
                        onPick(on ? nil : entry.letter)
                    } label: {
                        Text(entry.letter)
                            .font(.brand(.footnote, weight: on ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(on ? theme.accentText : (entry.count > 0 ? theme.textSecondary : theme.textTertiary.opacity(0.5)))
                            .frame(minWidth: 30, minHeight: 34)
                            .background(on ? theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.count == 0 && !on)
                    .accessibilityLabel(entry.letter == "#" ? "Other characters, \(entry.count)" : "\(entry.letter), \(entry.count)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.gutter)
        }
    }
}

/// Two year fields, committed on return — a half-typed year never fetches.
struct LibraryYearRangeRow: View {
    @Environment(\.theme) private var theme
    let range: LibraryYearRange
    let from: Int?
    let to: Int?
    let onCommit: (Int?, Int?) -> Void

    @State private var fromText = ""
    @State private var toText = ""

    var body: some View {
        HStack(spacing: Spacing.sm) {
            LibraryCapLabel(text: "Year")
            field("From \(range.min)", text: $fromText, label: "From year")
            Text("–").foregroundStyle(theme.textTertiary).accessibilityHidden(true)
            field("To \(range.max)", text: $toText, label: "To year")
            if from != nil || to != nil {
                Button("All years") { onCommit(nil, nil) }
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.gutter)
        .onAppear { sync() }
        .onChange(of: from) { _, _ in sync() }
        .onChange(of: to) { _, _ in sync() }
    }

    private func sync() {
        fromText = from.map(String.init) ?? ""
        toText = to.map(String.init) ?? ""
    }

    private func field(_ prompt: String, text: Binding<String>, label: String) -> some View {
        TextField(prompt, text: text)
            .keyboardType(.numberPad)
            .font(.brand(.footnote))
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .frame(width: 92, height: Layout.compactButtonHeight)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(theme.borderStrong, lineWidth: 1))
            .onSubmit { commit() }
            .accessibilityLabel(label)
    }

    private func commit() {
        let a = Int(fromText.filter(\.isNumber).prefix(4))
        let b = Int(toText.filter(\.isNumber).prefix(4))
        onCommit(a, b)
    }
}

/// What a shelf says when it holds nothing, or could not be loaded: a drawn shelf with three
/// books, a title, a line of direction, and the one thing to do about it.
struct LibraryEmptyView<Actions: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var hint: String?
    var isError = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack(alignment: .bottom, spacing: 3) {
                book(height: 36, hex: "#6E1F2A")
                book(height: 44, hex: "#1F2E4D")
                book(height: 32, hex: "#1F4A3A").rotationEffect(.degrees(12), anchor: .bottomLeading)
            }
            .frame(height: 48)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(PaletteColor(hex: 0x8A6A3F))).frame(width: 90, height: 4).offset(y: 4)
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.display(size: 20, relativeTo: .title3))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let hint {
                Text(hint)
                    .font(.brand(.subheadline))
                    .foregroundStyle(isError ? theme.danger : theme.textFaint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
        .frame(maxWidth: .infinity)
    }

    private func book(height: CGFloat, hex: String) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.libraryHex(hex))
            .frame(width: 14, height: height)
    }
}

extension LibraryEmptyView where Actions == EmptyView {
    init(title: String, hint: String? = nil, isError: Bool = false) {
        self.init(title: title, hint: hint, isError: isError) { EmptyView() }
    }
}

/// The last row of a paged list: a spinner while the next page comes, or nothing.
struct LibraryLoadMoreFooter: View {
    let isLoading: Bool
    let canLoadMore: Bool
    let load: () async -> Void

    var body: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, Spacing.lg)
        } else if canLoadMore {
            Color.clear
                .frame(height: 1)
                .task { await load() }
        }
    }
}

/// The grid every collection draws its covers in.
enum LibraryGrid {
    static let columns = [GridItem(.adaptive(minimum: 136, maximum: 200), spacing: Spacing.md, alignment: .top)]
    static let wideColumns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: Spacing.lg, alignment: .top)]
}

/// A small-capitals caption over a row of chips — the web's `.rc-cap`.
struct LibraryCapLabel: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.brand(size: 10.5, weight: .bold, relativeTo: .caption2))
            .tracking(0.7)
            .foregroundStyle(theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}
