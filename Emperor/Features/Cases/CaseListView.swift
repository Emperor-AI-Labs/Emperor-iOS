import SwiftUI

/// The docket, grouped by when each matter is next in court.
struct CaseListView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: CaseListViewModel?
    @State private var isSearchingCourts = false

    var body: some View {
        NavigationStack {
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
            .navigationDestination(for: String.self) { caseID in
                CaseDetailView(caseID: caseID)
            }
            .task {
                guard model == nil else { return }
                let created = CaseListViewModel(service: session.cases, cache: session.cache)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: CaseListViewModel) -> some View {
        @Bindable var bindable = model

        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                ForEach(model.groups) { group in
                    Section(group.title) {
                        ForEach(group.cases) { legalCase in
                            NavigationLink(value: legalCase.id) {
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
