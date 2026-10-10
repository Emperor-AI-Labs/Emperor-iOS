import SwiftUI

/// The Ask tab: where a question starts.
///
/// The date and a serif greeting by the time of day; the composer — files, the answer mode, Send;
/// suggestions for the reader's role, which fill the composer and never send; the next sitting
/// from the cause list, each hearing opening its sheet; and the recent conversations, each
/// pushing its thread. Every conversation is under History, and drafts and updates are a tap
/// away in the bar.
///
/// A question sent from here opens a new conversation and goes as soon as its history is ready —
/// the same path a tool's prompt takes (`ChatThreadView.seed`). Offline, nothing is sent and the
/// words stay in the composer.
struct AskHomeView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.practice) private var practice
    @Environment(\.navigator) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var path: [ChatRoute] = []
    @State private var causeList: CauseListViewModel?
    @State private var chats: ChatListViewModel?
    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    /// The answer mode chosen for this question, or `nil` for the default.
    @State private var chosenMode: ChatModel?
    @State private var isPickingFiles = false
    @State private var isChoosingMode = false
    @State private var isShowingHistory = false
    @State private var isShowingDrafts = false
    @State private var isShowingUpdates = false
    @State private var openHearing: CauseListing?
    @State private var isOffline = AppConnectivity.current.isOffline
    @State private var unread = 0
    @FocusState private var composerFocused: Bool

    private let preferences = Preferences()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    composer
                        .padding(.top, 18)
                    notices
                    suggestions
                    nextSitting
                    recent
                }
                .padding(.horizontal, Spacing.gutter)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxxl)
                .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await reload() }
            .background(theme.canvas)
            .navigationTitle("Ask")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .navigationDestination(for: ChatRoute.self) { route in
                ChatThreadView(
                    chatID: route.id,
                    seed: route.seed,
                    initialAttachments: route.attachments,
                    initialModel: route.model,
                    onStartNewChat: { path = [ChatRoute(id: ChatListViewModel.newChatID())] },
                    onTurnFinished: { Task { await chats?.load() } })
            }
            .sheet(isPresented: $isPickingFiles) {
                FileLibraryView(alreadyAttached: attachments) { chosen in
                    attachments = chosen
                }
            }
            .sheet(isPresented: $isChoosingMode) {
                AnswerModeSheet(selection: mode) { chosenMode = $0 }
            }
            .sheet(isPresented: $isShowingHistory) {
                ChatListView(onDone: { isShowingHistory = false })
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingDrafts) {
                DraftHistoryView()
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingUpdates) {
                NotificationsView()
                    .pageSizedSheet()
            }
            .sheet(item: $openHearing) { listing in
                HearingSheet(
                    listing: listing,
                    allListings: causeList?.listings ?? [],
                    onOpenMatter: { navigator.openCase($0) },
                    onAsk: { fill($0, attachments: []) })
            }
        }
        .task { await loadOnce() }
        .onReceive(NotificationCenter.default.publisher(for: .emperorConnectivityChanged)) { _ in
            isOffline = AppConnectivity.current.isOffline
        }
        // "Ask about it" from Matters, "Ask about this folder" from Files.
        .onAppear { takeQuestion() }
        .onChange(of: navigator.pendingQuestion) { _, _ in takeQuestion() }
    }

    // MARK: - Header

    private var header: some View {
        TimelineView(.everyMinute) { context in
            SerifHeader(
                eyebrow: AskHome.dateLine(context.date),
                title: AskHome.greetingLine(
                    hour: Calendar.current.component(.hour, from: context.date),
                    name: session.currentUser?.name))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // No mark in the leading slot: on iOS 26 a toolbar item is drawn in a round glass button,
        // which clipped the wordmark beside the mark. The design's iPhone Ask has no logo here.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isShowingUpdates = true
            } label: {
                Image(systemName: unread > 0 ? "bell.badge" : "bell")
            }
            .accessibilityLabel(unread > 0 ? "Updates, \(unread) unread" : "Updates")

            Menu {
                Button {
                    isShowingHistory = true
                } label: {
                    Label("All conversations", systemImage: "clock")
                }
                Button {
                    isShowingDrafts = true
                } label: {
                    Label("Your drafts", systemImage: "doc.text")
                }
            } label: {
                Image(systemName: "clock")
            }
            .accessibilityLabel("History")
        }
    }

    // MARK: - Composer

    private var mode: ChatModel {
        chosenMode ?? AnswerModeDefault.starting(plan: session.currentUser?.plan)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isOffline
            && session.standing == nil
    }

    private var composer: some View {
        RecordComposer(
            text: $text,
            placeholder: "Ask about a matter, a judgment or a draft…",
            attachments: attachments.map { DisplayText.fileName($0.name) },
            onRemoveAttachment: { index in
                guard attachments.indices.contains(index) else { return }
                attachments.remove(at: index)
            },
            model: mode,
            onChooseMode: { isChoosingMode = true },
            canSend: canSend,
            onAttach: { isPickingFiles = true },
            onSend: send,
            focus: $composerFocused)
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Offline or refused, the words stay where they were written.
        guard !question.isEmpty, canSend else { return }
        composerFocused = false
        path.append(ChatRoute(
            id: ChatListViewModel.newChatID(), seed: question, attachments: attachments, model: mode))
        text = ""
        attachments = []
        chosenMode = nil
    }

    /// Puts a question in the composer — a suggestion, or one asked for from another tab.
    private func fill(_ prompt: String, attachments chosen: [ChatAttachment]) {
        text = prompt
        if !chosen.isEmpty { attachments = chosen }
        path = []
        composerFocused = true
    }

    private func takeQuestion() {
        guard let question = navigator.takePendingQuestion() else { return }
        fill(question.prompt, attachments: question.attachments)
    }

    @ViewBuilder
    private var notices: some View {
        if isOffline {
            OfflineStrip()
                .padding(.top, Spacing.md)
        }
        if let standing = session.standing {
            AccountStandingBanner(standing: standing)
                .padding(.top, Spacing.md)
        }
    }

    // MARK: - Suggestions

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSectionLabel(title: "Try")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(AskHome.suggestions(for: practice.role)) { suggestion in
                        Button {
                            fill(suggestion.prompt, attachments: [])
                        } label: {
                            ChipLabel(
                                title: suggestion.title, systemImage: suggestion.systemImage,
                                isSelected: false)
                        }
                        .buttonStyle(ChipButtonStyle(isSelected: false))
                        .accessibilityHint("Puts this question in the box above")
                    }
                }
                .padding(.horizontal, Spacing.gutter)
            }
            .padding(.horizontal, -Spacing.gutter)
        }
    }

    // MARK: - Next sitting

    @ViewBuilder
    private var nextSitting: some View {
        if let causeList {
            let overview = MattersOverview(listings: causeList.listings, todayKey: causeList.todayKey)
            if let day = overview.nextSitting {
                RecordSectionLabel(
                    title: "Next sitting · \(overview.dayLabel(day.key))",
                    actionTitle: "See all",
                    action: { navigator.selectedTab = .matters })
                VStack(spacing: 0) {
                    ForEach(Array(day.listings.prefix(4).enumerated()), id: \.element.id) { index, listing in
                        if index > 0 { RecordDivider(inset: 0) }
                        Button {
                            openHearing = listing
                        } label: {
                            NextSittingRow(listing: listing)
                        }
                        .buttonStyle(.recordRow)
                    }
                }
                .panel()
            } else if causeList.state.isLoading && causeList.listings.isEmpty {
                RecordSectionLabel(title: "Next sitting")
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                RecordSectionLabel(title: "Next sitting")
                Text(causeList.hasAnyListings
                     ? "Nothing of yours is listed ahead. \(CauseListViewModel.Copy.confirmWithCourt)"
                     : "No hearing dates have come through for your matters yet. Add a matter on Matters and its listings appear here.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()
            }
        }
    }

    // MARK: - Recent

    @ViewBuilder
    private var recent: some View {
        if let chats {
            RecordSectionLabel(
                title: "Recent",
                actionTitle: chats.chats.count > 4 ? "All" : nil,
                action: { isShowingHistory = true })
            if chats.chats.isEmpty {
                Text(chats.isLoading ? "Loading your conversations…" : "No conversations yet. Ask anything above to start one.")
                    .font(.brand(.footnote))
                    .foregroundStyle(theme.textFaint)
                    .padding(.vertical, Spacing.sm)
            } else {
                RecordGroup {
                    ForEach(Array(chats.chats.prefix(4).enumerated()), id: \.element.id) { index, chat in
                        if index > 0 { RecordDivider() }
                        Button {
                            path.append(ChatRoute(id: chat.id))
                        } label: {
                            RecordRow(title: chat.displayTitle, subtitle: recentSubtitle(chat)) {
                                IconTile(systemImage: "text.bubble")
                            }
                        }
                        .buttonStyle(.recordRow)
                        .accessibilityIdentifier("chat-row-\(chat.id)")
                    }
                }
            }
        }
    }

    private func recentSubtitle(_ chat: ChatSummary) -> String? {
        let when = chat.updatedAt.map { DisplayText.relative($0) }
        let preview = chat.lastPreview.flatMap { $0.isEmpty ? nil : $0 }
        let parts = [when, preview].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Loading

    private func loadOnce() async {
        if causeList == nil {
            causeList = CauseListViewModel(service: session.cases, cache: session.cache)
        }
        if chats == nil {
            chats = ChatListViewModel(service: session.chats, cache: session.cache)
        }
        let causeList = self.causeList
        let chats = self.chats
        await causeList?.load()
        await chats?.load()
        unread = (try? await session.notifications.unreadCount()) ?? 0
    }

    private func reload() async {
        let causeList = self.causeList
        let chats = self.chats
        await causeList?.load()
        await chats?.load()
    }
}

/// A conversation pushed on the Ask tab: an existing one by its id, or a new one with the question
/// that starts it.
struct ChatRoute: Hashable {
    let id: String
    var seed: String?
    var attachments: [ChatAttachment] = []
    var model: ChatModel?
}

/// A hearing in the "Next sitting" card: the court's short name, the matter, room and time, and the
/// item number in the serif.
private struct NextSittingRow: View {
    @Environment(\.theme) private var theme
    let listing: CauseListing

    @ScaledMetric(relativeTo: .caption) private var courtWidth: CGFloat = 44

    var body: some View {
        let display = listing.display
        let detail = [
            display.room, display.time,
            MattersOverview.isSupplementary(listing) ? "Suppl." : nil,
        ].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: Spacing.md) {
            Text(MattersOverview.courtShortName(listing.courtName) ?? "—")
                .font(.brand(.caption2, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.accentText)
                .frame(width: min(courtWidth, 72), alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.displayTitle)
                    .font(.brand(size: 14.5, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.brand(size: 12.5, relativeTo: .caption))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only when the record has one — a dash over "item" reads as a broken value.
            if let item = display.item {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(item)
                        .font(.display(size: 20, relativeTo: .title3))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                    Text("item")
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Item \(item)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: Layout.listRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.spoken(listing))
        .accessibilityHint("Shows the hearing")
    }
}
