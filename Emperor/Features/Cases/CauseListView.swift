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

    private func row(_ listing: CauseListing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let itemNo = listing.itemNo {
                    Text(itemNo)
                        .font(.brand(.caption, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 22, alignment: .trailing)
                }
                Text(listing.displayTitle)
                    .font(.brand(.headline))
                    .lineLimit(2)
            }

            if let court = listing.courtName {
                Text(court).font(.brand(.subheadline)).foregroundStyle(theme.textSecondary)
            }

            HStack(spacing: 6) {
                if let purpose = listing.purpose {
                    Text(purpose).lineLimit(1)
                }
                if let bench = listing.bench {
                    Text("·")
                    Text(bench).lineLimit(1)
                }
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textTertiary)

            // No hearing time is shown because the feed has none. The marketing dashboard
            // shows times; the API has no time field on a listing, and inventing one would be
            // worse than the gap it fills.
            if let remarks = listing.remarks {
                StatusPill(text: remarks, tone: .warning)
            }
        }
        .padding(.vertical, 4)
    }
}
