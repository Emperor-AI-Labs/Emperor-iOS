import SwiftUI

/// Where tapping an update goes.
///
/// A typed route rather than a bare id: matters and auction notices both identify themselves
/// with a `String`, so a `[String]` path cannot tell them apart — and routing an auction id to
/// `CaseDetailView` would ask the server for a matter that does not exist.
enum NotificationRoute: Hashable {
    case matter(String)
    case auction(String)
}

/// What has happened on your matters.
struct NotificationsView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session

    @State private var model: NotificationsViewModel?
    @State private var path: [NotificationRoute] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Updates")
            .navigationDestination(for: NotificationRoute.self) { route in
                switch route {
                case .matter(let caseID):
                    CaseDetailView(caseID: caseID)
                case .auction(let noticeID):
                    AuctionDetailView(noticeID: noticeID)
                }
            }
            .task {
                guard model == nil else { return }
                let created = NotificationsViewModel(
                    service: session.notifications, cache: session.cache)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: NotificationsViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                Section {
                    ForEach(model.notifications) { notification in
                        row(notification, model)
                    }
                } header: {
                    SectionHeader(
                        title: "Recent",
                        detail: model.unreadCount > 0 ? "\(model.unreadCount) new" : nil)
                }

                // No cursor exists on this API and it clamps at 200 with no truncation signal,
                // so older rows are genuinely unreachable. Saying so beats implying the list
                // is complete.
                if model.mayHaveOlderUnreachable {
                    Text("Showing the most recent \(NotificationService.maximumLimit). Older updates are not available here.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .refreshable { await model.load() }
        } empty: {
            ContentUnavailableView(
                "Nothing new",
                systemImage: "bell",
                description: Text("Changes on your matters — new orders, hearing dates, status — appear here."))
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Mark all read") {
                    Task { await model.markAllRead() }
                }
                .disabled(model.unreadCount == 0)
            }
        }
    }

    @ViewBuilder
    private func row(_ notification: AppNotification, _ model: NotificationsViewModel) -> some View {
        Button {
            Task { await model.markRead(notification) }
            switch notification.destination {
            case .caseDetail(let id):
                path.append(.matter(id))
            case .auction(let id):
                // The link the server sends is an API path — `/auction-notices/<id>` — which
                // has no route on the web either. It is parsed into an id and routed here.
                path.append(.auction(id))
            case .caseList, .none:
                // "Your matters changed", with nothing to single out. The docket is a tab away
                // and this is a sheet over it, so marking it read is the honest whole action.
                break
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notification.kind.systemImage)
                    .foregroundStyle(notification.isRead ? theme.textSecondary : theme.accentText)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(notification.title ?? notification.kind.label)
                        .font(.subheadline.weight(notification.isRead ? .regular : .semibold))
                        .lineLimit(2)
                    if let body = notification.body, !body.isEmpty {
                        Text(body)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(3)
                    }
                    if let created = notification.createdAt {
                        Text(DisplayText.relative(created))
                            .font(.brand(.caption2))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                if !notification.isRead {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                        .accessibilityLabel("Unread")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
