import SwiftUI

/// Everything that is not one of the four tabs, as the **Tools** sections of You.
///
/// This was the More tab — the web's sidebar on a phone (`src/shell/MobileNav.jsx`). The Record
/// design has four tabs, and none of these is one, so they moved under You with every row kept:
/// the role's workspace, every tool, the file tools, OCR, Translate, the Corporate Calendar and
/// Library. My Files is a tab of its own now, and Settings is You itself.
///
/// Labels are the web's — **Translate**, **eAuctions** — not the names this app once used, so
/// someone who uses both learns one vocabulary.
///
/// - Important: every destination here **presents rather than pushes**. Every one owns a
///   `NavigationStack` — they were built as self-contained modals — and pushing one into You's
///   stack would nest two stacks, with two navigation bars and a back button that unwinds the
///   wrong one. So each carries its own "Done" at `.cancellationAction`, and You owns the one
///   sheet they are presented in.
enum ToolDestination: String, Identifiable {
    case deck, corporateCalendar, library, projects, tools, fileTools, ocr, translate, eAuctions

    var id: String { rawValue }

    var title: String {
        switch self {
        // Named for the role rather than fixed, because that is what it is.
        case .deck: return "Your workspace"
        case .corporateCalendar: return "Corporate Calendar"
        case .library: return "Library"
        case .projects: return "Projects"
        case .tools: return "All tools"
        case .fileTools: return "File tools"
        case .ocr: return "OCR"
        case .translate: return "Translate"
        case .eAuctions: return "eAuctions"
        }
    }

    /// Chosen to read as the web's `lucide` icon for the same row.
    func symbol(for role: PractitionerRole) -> String {
        switch self {
        case .deck: return role.systemImage
        case .corporateCalendar: return "calendar.badge.checkmark"
        case .library: return "books.vertical"
        case .projects: return "folder.badge.person.crop"
        case .tools: return "wrench.and.screwdriver"
        case .fileTools: return "scissors"
        case .ocr: return "doc.text.viewfinder"
        case .translate: return "character.bubble"
        case .eAuctions: return "hammer"
        }
    }

    /// The screen, at the size of a page on iPad.
    @MainActor @ViewBuilder
    var screen: some View {
        switch self {
        case .deck: RoleHomeView()
        case .corporateCalendar: ComplianceCalendarView()
        case .library: LibraryView()
        // Read-only while the feature is trialled on the web. See `ProjectService`.
        case .projects: ProjectListView()
        case .tools: ToolsListView()
        case .fileTools: PDFToolsView()
        // One screen with an OCR | Translate switch at its head; each row opens it in its own mode.
        case .ocr: OCRView(mode: .ocr)
        case .translate: OCRView(mode: .translate)
        case .eAuctions: AuctionListView()
        }
    }
}

/// The Tools rows of You: "Your practice" and "Tools", in the platform's own order.
///
/// Projects and eAuctions are hidden for now, at the product owner's request. Only the rows are
/// gone: their screens, view models, services and tests are all still here and still built. To
/// bring one back, add `row(.projects)` after `row(.library)`, or `row(.eAuctions)` after
/// `row(.translate)` — and add its row to the UI tests and the screenshot tour.
struct ToolsSections: View {
    @Environment(\.theme) private var theme
    @Environment(\.practice) private var practice
    @Binding var destination: ToolDestination?

    var body: some View {
        Section {
            row(.deck)
            row(.corporateCalendar)
            row(.library)
        } header: {
            SectionHeader(title: "Your practice")
        }
        .listRowBackground(theme.surface)

        Section {
            row(.tools)
            row(.fileTools)
            row(.ocr)
            row(.translate)
        } header: {
            // "All tools" is not a row the web has — there, most of the registry is reachable only
            // by typing `/w/<id>`. A phone has no address bar.
            SectionHeader(title: "Tools")
        }
        .listRowBackground(theme.surface)
    }

    /// A row: the tile, the label, and a chevron — drawn here because the row presents rather
    /// than pushes, so iOS supplies none. Named by its title alone, as the UI tests find it.
    private func row(_ item: ToolDestination) -> some View {
        Button {
            destination = item
        } label: {
            HStack(spacing: Spacing.sm) {
                IconRowLabel(title: item.title, systemImage: item.symbol(for: practice.role))
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(item.title))
    }
}
