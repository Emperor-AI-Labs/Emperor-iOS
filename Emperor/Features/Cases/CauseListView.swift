import SwiftUI

/// What is listed today.
///
/// The subtitle is not decoration. This is **not** the court's published cause list — the
/// server derives every row from hearing dates on cases the user has added. A screen a
/// litigator reads as the court's list, which then shows nothing, has told them their day is
/// clear when it may not be. So `Copy.subtitle` is present on every state, and the empty state
/// ends with "Always confirm against the court's official cause list."
struct CauseListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: CauseListViewModel?
    @State private var isShowingSettings = false
    @State private var isDigitising = false
    @State private var isShowingUpdates = false
    @State private var unread = 0
    /// The badge's width, scaled with Dynamic Type so a three-digit item still fits at the
    /// largest sizes rather than truncating to "1…".
    @ScaledMetric(relativeTo: .title3) private var badgeWidth: CGFloat = 58

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: String.self) { caseID in
                CaseDetailView(caseID: caseID)
            }
            .task {
                guard model == nil else { return }
                let created = CauseListViewModel(
                    service: session.cases, cache: session.cache)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: CauseListViewModel) -> some View {
        VStack(spacing: 0) {
            // First thing on the first screen: if new work will be refused, say so before it is
            // tried rather than one failed question at a time.
            if let standing = session.standing {
                AccountStandingBanner(standing: standing)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            header(model)
            Divider()

            ListStateView(presentation: model.presentation, retry: { await model.load() }) {
                List(model.listingsForSelectedDay) { listing in
                    NavigationLink(value: listing.caseID) {
                        row(listing)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(theme.canvas)
                .refreshable { await model.load() }
            } empty: {
                emptyState(model)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $isDigitising) {
            OCRView()
        }
        .sheet(isPresented: $isShowingUpdates) {
            NotificationsView()
        }
        .task {
            // The badge only. The feed itself is fetched when the sheet opens — this is one row.
            unread = (try? await session.notifications.unreadCount()) ?? 0
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingUpdates = true
                } label: {
                    Label("Updates", systemImage: unread > 0 ? "bell.badge" : "bell")
                }
                .accessibilityLabel(
                    unread > 0 ? "Updates, \(unread) unread" : "Updates")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // The most phone-native thing the product does — photograph a paper order
                    // and get something searchable.
                    Button {
                        isDigitising = true
                    } label: {
                        Label("Digitise a document", systemImage: "doc.viewfinder")
                    }
                    ShareLink(item: model.shareText()) {
                        Label("Share this day", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "person.crop.circle")
                }
            }
        }
    }

    /// The date bar, plus the framing line that says whose cases these are.
    private func header(_ model: CauseListViewModel) -> some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    model.step(days: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous day")

                Spacer()

                Button {
                    model.goToToday()
                } label: {
                    VStack(spacing: 1) {
                        Text(DisplayText.longDay(model.selectedDay))
                            .font(.brand(.subheadline, weight: .semibold))
                        // On every state, including the empty one.
                        Text(CauseListViewModel.Copy.subtitle)
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                // `allowsHitTesting` rather than `.disabled`: the latter dims the screen's
                // primary heading on every cold open, because today is the default day.
                .allowsHitTesting(!model.isShowingToday)
                .accessibilityElement(children: .combine)
                .accessibilityHint(model.isShowingToday ? "" : "Return to today")

                Spacer()

                Button {
                    model.step(days: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next day")
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
    }

    /// An empty day is a real answer, so it is never skipped — but it should not be a dead end
    /// either. The signpost says where the next listing actually is.
    private func emptyState(_ model: CauseListViewModel) -> some View {
        ContentUnavailableView {
            Label(model.emptyTitle, systemImage: "calendar.badge.checkmark")
        } description: {
            Text(model.emptyDetail)
        } actions: {
            if let next = model.nextListedDay {
                Button("Next listing — \(DisplayText.longDay(next))") {
                    model.select(day: next)
                }
                .buttonStyle(.borderedProminent)
            }
            if let previous = model.previousListedDay {
                Button("Previous listing") { model.select(day: previous) }
            }
        }
    }

    /// One listing, read the way a litigator reads a list in a corridor: where first — item and
    /// courtroom in the badge — then which matter, then the bench, then the rest.
    ///
    /// The web's Home card puts the courtroom in the same left-hand gutter
    /// (`TodayCauseList.jsx`, `Row`); this adds the item number above it, which is the number
    /// that decides when to be in the room. Neither is ever made up: an unnumbered listing
    /// shows the scales instead, because a plausible "3" is read as where the matter is listed.
    /// See `CauseListingDisplay` for the rules.
    private func row(_ listing: CauseListing) -> some View {
        let display = listing.display
        return HStack(alignment: .center, spacing: 12) {
            locationBadge(display)

            VStack(alignment: .leading, spacing: 3) {
                if let forum = display.forum(courtName: listing.courtName) {
                    Text(forum)
                        .font(.brand(.caption2, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .lineLimit(2)
                }

                Text(listing.displayTitle)
                    .font(.brand(.headline))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)

                // Number, sitting time and counsel. The time appears only where the published
                // list printed one; nothing here is ever inferred, because a plausible "10:30"
                // for a hearing a lawyer has to attend is exactly the helpful guess that gets a
                // matter dismissed.
                if let detail = display.detailLine {
                    Text(detail)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }

                if let note = display.note {
                    Text(note)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(2)
                }

                if let remarks = listing.remarks {
                    StatusPill(text: remarks, tone: .warning)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spoken(listing))
    }

    /// Item over courtroom, or whichever of the two the list gave.
    private func locationBadge(_ display: CauseListingDisplay) -> some View {
        VStack(spacing: 1) {
            if let item = display.item {
                badgeCaption("Item")
                badgeValue(item)
                if let room = display.roomNumber {
                    Text("Court \(room)")
                        .font(.brand(.caption2, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.accentText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else if let room = display.roomNumber {
                badgeCaption("Court")
                badgeValue(room)
            } else {
                Image(systemName: "scalemass")
                    .font(.brand(.title3))
                    .foregroundStyle(theme.accentText)
                    .padding(.vertical, 6)
            }
        }
        .frame(width: badgeWidth)
        .padding(.vertical, 6)
        .background(
            theme.surfaceElevated,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func badgeCaption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.brand(.caption2, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
    }

    private func badgeValue(_ text: String) -> some View {
        Text(text)
            .font(.brand(.title3, weight: .bold).monospacedDigit())
            .foregroundStyle(theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}
