import SwiftUI

/// The docket, grouped by when each matter is next in court.
///
/// Also where another tab sends a matter to be opened — the Calendar does, for a listed case. The
/// stack is bound to `path` so it can be replaced from outside: `AppNavigator` holds the request,
/// and this takes it when it appears or when the request arrives while it is already on screen.
/// Taking clears it, so it is applied once. The case opens on a fresh `CaseDetailView`, whose
/// overview leads the screen.
struct CaseListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator

    @State private var model: CaseListViewModel?
    @State private var isSearchingCourts = false
    @State private var path: [CaseRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Cases")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSearchingCourts = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(CourtSearchViewModel.Copy.title)
                }
            }
            .sheet(isPresented: $isSearchingCourts) {
                CourtSearchView { Task { await model?.load() } }
            }
            .navigationDestination(for: CaseRoute.self) { route in
                CaseDetailView(caseID: route.caseID)
            }
            .task {
                guard model == nil else { return }
                let created = CaseListViewModel(service: session.cases, cache: session.cache)
                model = created
                await created.load()
            }
        }
        // Both, because either can be first: a tab never shown before is created by the switch
        // the request causes, and one already alive sees the request change instead.
        .onAppear { openRequestedCase() }
        .onChange(of: navigator.pendingCase) { _, _ in openRequestedCase() }
    }

    private func openRequestedCase() {
        guard let stack = navigator.takePendingCaseStack() else { return }
        path = stack
    }

    @ViewBuilder
    private func content(_ model: CaseListViewModel) -> some View {
        @Bindable var bindable = model

        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                ForEach(model.groups) { group in
                    Section(group.title) {
                        ForEach(group.cases) { legalCase in
                            NavigationLink(value: CaseRoute(caseID: legalCase.id)) {
                                row(legalCase)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
        } empty: {
            // `presentation.isEmpty` comes from the *filtered* list, so a search matching
            // nothing already routes here — branching on it in the content closure above
            // would never be reached.
            if model.showsNoSearchResults {
                ContentUnavailableView.search(text: model.query)
            } else {
                ContentUnavailableView(
                    "No matters yet",
                    systemImage: "folder",
                    description: Text("Cases added on the web appear here, with their hearing dates."))
            }
        }
        .searchable(text: $bindable.query, prompt: "Filter your matters")
        .refreshable { await model.load() }
    }

    private func row(_ legalCase: LegalCase) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(legalCase.displayTitle)
                .font(.brand(.headline))
                .lineLimit(2)

            HStack(spacing: 6) {
                if let reference = legalCase.caseReference {
                    Text(reference)
                }
                if let court = legalCase.courtName {
                    Text("·")
                    Text(court).lineLimit(1)
                }
            }
            .font(.brand(.subheadline))
            .foregroundStyle(theme.textSecondary)

            HStack(spacing: 8) {
                if let hearing = legalCase.nextHearingDate {
                    Label(
                        DisplayText.longDay(WireDate.dayKey(hearing)),
                        systemImage: "calendar")
                }
                // Says where the row came from. A matter the court maintains and one typed in
                // by hand carry very different confidence, and the badge is the only signal.
                if legalCase.isCourtSynced {
                    StatusPill(
                        text: "From court", tone: .accent, systemImage: "building.columns")
                }
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textTertiary)

            if let stage = legalCase.stage ?? legalCase.status {
                Text(stage).font(.brand(.caption2)).foregroundStyle(theme.textTertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
