import SwiftUI

/// Everything that is not one of the three primary destinations.
///
/// The web app's mobile navigation is a bottom bar of **Home · Cases · Chat · More**, where
/// "More" opens the full sidebar (`src/shell/MobileNav.jsx`). This is that sidebar.
///
/// Labels are the web's, not the ones this app used to use. It said "Diary", "Digitise" and
/// "Auctions" where the platform says **Calendar**, **Translate** and **eAuctions** (which the
/// web called Liquidations until it renamed the page, `src/pages/Liquidations.jsx:126`); someone
/// who uses both should not have to learn two vocabularies for one product.
///
/// Order follows `src/shell/Sidebar.jsx`, minus what is already a tab and minus what this client
/// deliberately does not carry:
///
/// - **Upgrade / `/buy`** — a pricing surface would attach StoreKit obligations to an app that
///   takes no money. It must stay absent.
/// - **Filing Assembly** — a 293-page bundle where a wrong folio gets the matter rejected at the
///   registry should not be assembled on a phone.
///
/// **My Files** leads "Your practice" because it sits above Library in the web's rail
/// (`src/shell/Sidebar.jsx:259`). It is its own screen, `MyFilesView`, not the composer's
/// picker: the web split the two the same way, so the drawer could stay a picker.
///
/// - Important: every destination here **presents rather than pushes**. Every one owns a
///   `NavigationStack` — they were built as self-contained modals and every other call site
///   already presents them that way. Pushing one into this list's stack would nest two stacks
///   and give it two navigation bars and a back button that unwinds the wrong one.
///
/// - Important: presenting means iOS supplies no back button, so **each destination has to carry
///   its own "Done"** at `.cancellationAction`. Five of them did not: `CalendarView`,
///   `LibraryView`, `ProjectListView`, `ToolsListView` and `AuctionListView` were written as tabs,
///   where the tab bar is how you leave, and kept that shape when they moved in here. A sheet can
///   always be swiped away, which is why nothing looked broken — but a gesture with no visible
///   control is not something a first-time user can discover, and VoiceOver and Switch Control
///   cannot perform it at all. `testEveryMoreRowOpensAndClosesFromAControlOnScreen` taps the
///   button rather than swiping, so this cannot regress quietly.
struct MoreView: View {
    @Environment(\.theme) private var theme
    @State private var destination: Destination?

    /// The rows, in the platform's own order.
    private enum Destination: String, Identifiable {
        case myFiles, deck, calendar, library, projects, tools, fileTools, translate, eAuctions, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .myFiles: return "My Files"
            // Named for the role rather than fixed, because that is what it is.
            case .deck: return "Your workspace"
            case .calendar: return "Calendar"
            case .library: return "Library"
            case .projects: return "Projects"
            case .tools: return "All tools"
            case .fileTools: return "File tools"
            case .translate: return "Translate"
            case .eAuctions: return "eAuctions"
            case .settings: return "Settings"
            }
        }

        /// Chosen to read as the web's `lucide` icon for the same row.
        var symbol: String {
            switch self {
            // The web's row is `folder-open`.
            case .myFiles: return "folder"
            case .deck: return "square.grid.2x2"
            case .calendar: return "calendar"
            case .library: return "books.vertical"
            // The web's row is `folder-kanban`. A person, because that is the distinction that
            // matters against the Cases tab: a project is a matter one user keeps by hand, not
            // one the scrapers keep for a team.
            case .projects: return "folder.badge.person.crop"
            case .tools: return "wrench.and.screwdriver"
            case .fileTools: return "scissors"
            case .translate: return "character.bubble"
            case .eAuctions: return "hammer"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.myFiles)
                    row(.calendar)
                    row(.library)
                    // Read-only while the feature is trialled on the web — no matter can be
                    // created or edited from here. See `ProjectService`.
                    row(.projects)
                } header: {
                    SectionHeader(title: "Your practice")
                }

                Section {
                    row(.deck)
                    row(.tools)
                    row(.fileTools)
                    row(.translate)
                    row(.eAuctions)
                } header: {
                    // The platform groups these under "Tools" in its rail. "All tools" is not a
                    // row the web has — there, most of the registry is reachable only by typing
                    // `/w/<id>`. A phone has no address bar, so without it twenty-four of the
                    // twenty-nine would be unreachable rather than merely unadvertised.
                    SectionHeader(title: "Tools")
                }

                Section {
                    row(.settings)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("More")
            .sheet(item: $destination) { chosen in
                switch chosen {
                case .myFiles: MyFilesView()
                case .deck: RoleHomeView()
                case .calendar: CalendarView()
                case .library: LibraryView()
                case .projects: ProjectListView()
                case .tools: ToolsListView()
                case .fileTools: PDFToolsView()
                case .translate: OCRView()
                case .eAuctions: AuctionListView()
                case .settings: SettingsView()
                }
            }
        }
    }

    private func row(_ item: Destination) -> some View {
        Button {
            destination = item
        } label: {
            HStack {
                Label(item.title, systemImage: item.symbol)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
