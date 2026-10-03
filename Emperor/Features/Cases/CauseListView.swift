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
    /// The day steps, a fingertip wide and growing with the text beside them.
    @ScaledMetric(relativeTo: .subheadline) private var stepSide: CGFloat = 36

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

            ListStateView(presentation: model.presentation, retry: { await model.load() }) {
                // Each listing on its own card row, as the Calendar's day draws the same rows —
                // one look for a listing wherever it appears.
                List {
                    Section {
                        ForEach(model.listingsForSelectedDay) { listing in
                            NavigationLink(value: listing.caseID) {
                                CauseListingRow(listing: listing)
                            }
                        }
                    }
                    .listRowBackground(theme.surface)
                }
                .listStyle(.insetGrouped)
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
    ///
    /// The day leads, left-aligned under the large title the way a diary page is headed, with
    /// the two steps beside it as round buttons a thumb finds without looking. "Today" appears
    /// only once there is somewhere to come back from — the heading itself does the same on a
    /// tap, but a control nobody can see is not one anybody uses.
    private func header(_ model: CauseListViewModel) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Button {
                model.goToToday()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DisplayText.longDay(model.selectedDay))
                        .font(.brand(.headline, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    // On every state, including the empty one.
                    Text(CauseListViewModel.Copy.subtitle)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `allowsHitTesting` rather than `.disabled`: the latter dims the screen's
            // primary heading on every cold open, because today is the default day.
            .allowsHitTesting(!model.isShowingToday)
            .accessibilityElement(children: .combine)
            .accessibilityHint(model.isShowingToday ? "" : "Return to today")

            if !model.isShowingToday {
                Button("Today") { model.goToToday() }
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 6)
                    .background(theme.accentWash, in: Capsule())
                    .buttonStyle(.plain)
                    .transition(.opacity)
            }

            HStack(spacing: Spacing.sm) {
                stepButton("chevron.left", label: "Previous day") { model.step(days: -1) }
                stepButton("chevron.right", label: "Next day") { model.step(days: 1) }
            }
        }
        // The system's own margin, so the day lines up under the large title above it.
        .padding(.horizontal)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .animation(.easeOut(duration: 0.15), value: model.isShowingToday)
    }

    /// A round step button, the size of a fingertip.
    private func stepButton(
        _ systemImage: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: min(stepSide, 52), height: min(stepSide, 52))
                .background(theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(theme.separator, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// An empty day is a real answer, so it is never skipped — but it should not be a dead end
    /// either. The signpost says where the next listing actually is.
    private func emptyState(_ model: CauseListViewModel) -> some View {
        EmptyStateView(
            model.emptyTitle, systemImage: "calendar.badge.checkmark", message: model.emptyDetail
        ) {
            if let next = model.nextListedDay {
                Button("Next listing — \(DisplayText.longDay(next))") {
                    model.select(day: next)
                }
                .buttonStyle(.primaryAction)
            }
            if let previous = model.previousListedDay {
                Button("Previous listing") { model.select(day: previous) }
                    .buttonStyle(.secondaryAction)
            }
        }
    }
}
