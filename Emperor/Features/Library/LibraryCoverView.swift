import SwiftUI
import UIKit

// The one cover every Library card uses — the web's `Cover.jsx`.
//
// Always drawn: a designed typographic cover (the collection's cloth, a spine shade at the left
// edge, the title in the display serif, a foot line). For PDFs the page-1 image from `/cover`
// fades in over it; while it loads, or if it never comes, the typographic cover stands. The
// image is fetched through `LibraryCoverLoader`, which remembers every answer for the session.

/// The session's cover cache, handed down the Library's view tree.
private struct LibraryCoversKey: EnvironmentKey {
    static let defaultValue: LibraryCoverLoader? = nil
}

extension EnvironmentValues {
    var libraryCovers: LibraryCoverLoader? {
        get { self[LibraryCoversKey.self] }
        set { self[LibraryCoversKey.self] = newValue }
    }
}

extension Color {
    /// A cover's cloth, from the collection vocabulary's `#RRGGBB`.
    static func libraryHex(_ hex: String, fallback: UInt32 = 0x3A3F5C) -> Color {
        Color(LibraryCollectionTheme.color(hex) ?? PaletteColor(hex: fallback))
    }
}

/// How large a cover is drawn. Height is always 4:3 of the width.
enum LibraryCoverSize {
    case small, medium, large, fill

    /// The width the server renders for this size.
    var imageWidth: Int {
        switch self {
        case .small: return 160
        case .medium, .fill: return 320
        case .large: return 640
        }
    }

    var fixedWidth: CGFloat? {
        switch self {
        case .small: return 68
        case .medium: return 148
        case .large: return 208
        case .fill: return nil
        }
    }
}

struct LibraryCoverView: View {
    @Environment(\.libraryCovers) private var covers

    let doc: CatalogueDocument
    var size: LibraryCoverSize = .fill
    /// Try the page-1 image for a PDF. Off where the cover is tiny (a list row's thumbnail).
    var image = true
    /// What the typographic cover prints instead of the row's own fields.
    var headline: String?
    var kicker: String?
    /// VoiceOver's name for the cover; without one it is decorative, the card carrying the title.
    var label: String?

    @State private var loaded: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            LibraryTypographicCover(doc: doc, headline: headline, kicker: kicker)
            if let loaded {
                Image(uiImage: loaded)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
            LibraryCoverSpine()
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .frame(width: size.fixedWidth)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
        .task(id: doc.id) { await fetch() }
    }

    private func fetch() async {
        guard image, doc.isPDF, let covers else { return }
        if let cached = await covers.cachedImage(for: doc, width: size.imageWidth), let ui = UIImage(data: cached) {
            loaded = ui
            return
        }
        guard let data = await covers.image(for: doc, width: size.imageWidth), let ui = UIImage(data: data) else { return }
        withAnimation(.easeOut(duration: 0.25)) { loaded = ui }
    }
}

/// The spine shade at the left edge: a scanned page still reads as a bound book.
struct LibraryCoverSpine: View {
    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.28), .black.opacity(0.0)],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: 8)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }
}

/// The designed cover: cloth, gilt rules per motif, kicker, title or parties, foot.
struct LibraryTypographicCover: View {
    let doc: CatalogueDocument
    var headline: String?
    var kicker: String?

    private var fields: LibraryTitles.CoverFields { LibraryTitles.coverFields(doc) }
    private var ink: Color { Color.libraryHex(LibraryCollectionTheme.coverInk) }
    private var gilt: Color { Color.libraryHex(LibraryCollectionTheme.coverGilt) }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack {
                Color.libraryHex(LibraryTitles.cloth(doc))
                LibraryCoverMotif(motif: doc.theme.motif, gilt: gilt)
                VStack(alignment: .leading, spacing: 0) {
                    Text((kicker ?? fields.kicker).uppercased())
                        .font(.system(size: max(6.5, w * 0.055), weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(gilt)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    titleBlock(width: w)
                    Spacer(minLength: 4)
                    if !fields.foot.isEmpty {
                        Text(fields.foot.joined(separator: "  ·  "))
                            .font(.system(size: max(6.5, w * 0.055), weight: .medium))
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, w * 0.14)
                .padding(.trailing, w * 0.09)
                .padding(.vertical, w * 0.1)
                .frame(width: w, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func titleBlock(width w: CGFloat) -> some View {
        if let headline {
            Text(headline)
                .font(.display(size: max(9, w * titleScale(headline)), relativeTo: .headline))
                .foregroundStyle(ink)
                .lineLimit(6)
                .minimumScaleFactor(0.7)
        } else if let parties = fields.parties {
            VStack(alignment: .leading, spacing: 2) {
                Text(parties.0)
                    .font(.display(size: max(8, w * 0.085), relativeTo: .subheadline))
                    .lineLimit(3)
                Text("versus")
                    .font(.display(size: max(7, w * 0.06), italic: true, relativeTo: .caption))
                    .foregroundStyle(gilt)
                Text(parties.1)
                    .font(.display(size: max(8, w * 0.085), relativeTo: .subheadline))
                    .lineLimit(3)
            }
            .foregroundStyle(ink)
            .minimumScaleFactor(0.7)
        } else {
            let title = fields.title ?? ""
            Text(title)
                .font(.display(size: max(9, w * titleScale(title)), relativeTo: .headline))
                .foregroundStyle(ink)
                .lineLimit(7)
                .minimumScaleFactor(0.65)
        }
    }

    /// Shorter titles are set larger, as the web's `t-s … t-xl` classes do.
    private func titleScale(_ text: String) -> CGFloat {
        let n = text.count
        return n <= 26 ? 0.13 : n <= 58 ? 0.105 : n <= 105 ? 0.085 : 0.072
    }
}

/// Gilt rules per collection: bands, a frame, a report's rules, a seal.
struct LibraryCoverMotif: View {
    let motif: String
    let gilt: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            switch motif {
            case "bands":
                VStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(gilt.opacity(0.9)).frame(height: 2)
                    Rectangle().fill(.clear).frame(height: 4)
                    Rectangle().fill(gilt.opacity(0.9)).frame(height: 1)
                }
                .padding(.bottom, h * 0.16)
                .padding(.horizontal, w * 0.08)
            case "frame":
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(gilt.opacity(0.8), lineWidth: 1)
                    .padding(.leading, w * 0.11)
                    .padding(.trailing, w * 0.06)
                    .padding(.vertical, w * 0.06)
            case "seal":
                Circle()
                    .strokeBorder(gilt.opacity(0.55), lineWidth: 1.5)
                    .frame(width: w * 0.28, height: w * 0.28)
                    .position(x: w * 0.78, y: h * 0.84)
            default:
                VStack(spacing: 3) {
                    Rectangle().fill(gilt.opacity(0.85)).frame(height: 1.5)
                    Rectangle().fill(gilt.opacity(0.5)).frame(height: 0.8)
                }
                .padding(.top, h * 0.19)
                .padding(.leading, w * 0.14)
                .padding(.trailing, w * 0.09)
            }
        }
        .allowsHitTesting(false)
    }
}

/// An Act's cover: a cloth-bound statute volume — the web's `ActCover.jsx`. Typographic by
/// design: page 1 of a statute PDF is a gazette header, not a face.
struct ActCoverView: View {
    let doc: CatalogueDocument
    var size: LibraryCoverSize = .fill
    var showsCounts = true
    /// The index's active "Contains" filter, whose count is printed first.
    var first: String?
    var label: String?

    private var ink: Color { Color.libraryHex(LibraryCollectionTheme.coverInk) }
    private var gilt: Color { Color.libraryHex(LibraryCollectionTheme.coverGilt) }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let jurisdiction = LibraryActText.jurisdiction(of: doc)
            let split = LibraryActText.splitTitle(doc)
            let name = doc.groupTitle?.nilIfEmpty ?? split.name
            let parts = showsCounts ? Array(LibraryActText.countParts(doc.tabCounts, first: first).prefix(2)) : []
            ZStack(alignment: .bottom) {
                Color.libraryHex(LibraryActText.cloth(doc))
                if size != .small {
                    VStack(alignment: .leading, spacing: 0) {
                        Text((LibraryActText.isRepealed(doc) ? "Repealed" : LibraryActText.kicker(doc)).uppercased())
                            .font(.system(size: max(6.5, w * 0.055), weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(gilt)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(name)
                            .font(.display(size: max(9, w * (name.count <= 22 ? 0.13 : name.count <= 48 ? 0.1 : name.count <= 90 ? 0.082 : 0.07)), relativeTo: .headline))
                            .foregroundStyle(ink)
                            .lineLimit(6)
                            .minimumScaleFactor(0.65)
                        Spacer(minLength: 4)
                        HStack(alignment: .lastTextBaseline) {
                            if !split.year.isEmpty {
                                Text(split.year)
                                    .font(.display(size: max(11, w * 0.17), relativeTo: .title2))
                                    .foregroundStyle(gilt)
                            }
                            Spacer(minLength: 2)
                            if !parts.isEmpty {
                                Text(parts.joined(separator: " · "))
                                    .font(.system(size: max(6, w * 0.05), weight: .medium))
                                    .foregroundStyle(ink.opacity(0.85))
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.leading, w * 0.14)
                    .padding(.trailing, w * 0.09)
                    .padding(.top, w * 0.1)
                    .padding(.bottom, w * 0.26)
                    .frame(width: w, height: proxy.size.height, alignment: .topLeading)
                }
                // The band at the foot names the jurisdiction: gilt for a Central Act, dark for a State.
                Text(size == .small ? "" : (jurisdiction.isCentral ? "Central Act" : jurisdiction.short).uppercased())
                    .font(.system(size: max(6, w * 0.05), weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(jurisdiction.isCentral ? Color.black.opacity(0.75) : ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, max(2, w * 0.03))
                    .background(jurisdiction.isCentral ? gilt : Color.black.opacity(0.28))
                    .padding(.bottom, w * 0.1)
                LibraryCoverSpine()
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .frame(width: size.fixedWidth)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
    }
}

/// The court's monogram in its colour — the web's `CourtSeal`.
struct CourtSealView: View {
    @Environment(\.theme) private var theme
    let court: CaseLawVocabulary.CourtInfo
    var diameter: CGFloat = 36

    var body: some View {
        let ink = Color.libraryHex(theme.isDark ? court.inkDark : court.ink)
        Text(court.monogram)
            .font(.display(size: diameter * 0.4, relativeTo: .caption))
            .foregroundStyle(ink)
            .frame(width: diameter, height: diameter)
            .background(ink.opacity(0.1), in: Circle())
            .overlay(Circle().strokeBorder(ink.opacity(court.isOrders ? 0.35 : 0.6), style: StrokeStyle(lineWidth: 1, dash: court.isOrders ? [3, 2] : [])))
            .accessibilityHidden(true)
    }
}
