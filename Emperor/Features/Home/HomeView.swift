import SwiftUI

/// The Home tab — the redesign's dashboard.
///
/// The design's own bar across the top: the mark, the plan and the role as pills, Updates and the
/// profile button — **You** opens from the avatar as a sheet, You having left the tab bar. Under
/// it the composer, whose Send carries the question, its files and its answer mode to the Ask tab
/// (`AppNavigator.ask`), which is where the conversation happens; the quick actions; the cause
/// list and the Precedents Vault as the two cards; and the recent conversations, each pushing its
/// thread here.
///
/// Everything the cards need is loaded once and kept — the cause list, the conversations, the
/// drafts — and pull-to-refresh checks them again. Offline, the composer still holds the words
/// and says so; it does not send.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.practice) private var practice
    @Environment(\.navigator) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var path: [ChatRoute] = []
    @State private var causeList: CauseListViewModel?
    @State private var chats: ChatListViewModel?
    @State private var drafts: DraftHistoryViewModel?
    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    /// The answer mode chosen with the question, or `nil` for the default.
    @State private var chosenMode: ChatModel?
    @State private var isPickingFiles = false
    @State private var isChoosingMode = false
    @State private var isShowingYou = false
    @State private var isShowingPlan = false
    @State private var isShowingUpdates = false
    @State private var isShowingDrafting = false
    @State private var isFindingCase = false
    /// The matter Home's vault chips open the drafting workspace on; `nil` for the last one used.
    @State private var vaultMatterID: String?
    @State private var openHearing: CauseListing?
    @State private var isOffline = AppConnectivity.current.isOffline
    @State private var unread = 0
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        composer
                        notices
                        quickActions
                        cards
                        recents
                    }
                    .padding(.horizontal, Spacing.gutter)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xxxl)
                    .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await reload() }
            }
            .frame(maxWidth: ReadableWidth.cap(for: sizeClass))
            .frame(maxWidth: .infinity)
            .background(theme.canvas)
            // The design's own bar replaces the system's: no title, no glass, the mark and the
            // pills the first thing under the status bar.
            .toolbar(.hidden, for: .navigationBar)
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
            .sheet(isPresented: $isShowingYou) {
                YouView()
                    // Page-sized on iPad: a form sheet held You to a small panel, and the
                    // Security section at its foot could not be scrolled to.
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingPlan) {
                HomePlanSheet()
            }
            .sheet(isPresented: $isShowingUpdates) {
                NotificationsView()
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingDrafting) {
                LitigatorWorkspaceView(initialMatterID: vaultMatterID)
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isFindingCase) {
                // A matter pinned from here: the docket lives on Cases and is kept across the
                // session, so it is asked to reload rather than left missing what was just added.
                CourtSearchView {
                    navigator.requestDocketRefresh()
                }
                .pageSizedSheet()
            }
            .sheet(item: $openHearing) { listing in
                HearingSheet(
                    listing: listing,
                    allListings: causeList?.listings ?? [],
                    onOpenMatter: { navigator.openCase($0) },
                    onAsk: { navigator.ask($0) })
            }
            .fullScreenCover(item: Binding(
                get: { drafts?.opened },
                set: { if $0 == nil { drafts?.close() } }
            )) { opened in
                DraftReaderView(draft: opened)
            }
            .alert("Couldn't open that", isPresented: Binding(
                get: { drafts?.errorMessage != nil },
                set: { if !$0 { drafts?.errorMessage = nil } }
            )) {
                Button("OK") { drafts?.errorMessage = nil }
            } message: {
                Text(drafts?.errorMessage ?? "")
            }
        }
        .task { await loadOnce() }
        .onReceive(NotificationCenter.default.publisher(for: .emperorConnectivityChanged)) { _ in
            isOffline = AppConnectivity.current.isOffline
        }
        // Read Updates and came back: the dot on the bell is the count the server last gave.
        .onChange(of: isShowingUpdates) { _, showing in
            guard !showing else { return }
            Task { unread = (try? await session.notifications.unreadCount()) ?? 0 }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Spacing.sm) {
            logoTile
            planPill
            rolePill
            Spacer(minLength: Spacing.sm)
            bellButton
            profileButton
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The mark, filled with the primary gradient — decorative; the pills and buttons beside it
    /// carry the words.
    private var logoTile: some View {
        Image(systemName: "scalemass")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(theme.onAccent)
            .frame(width: 36, height: 36)
            .background(
                theme.primaryGradient,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }

    private var planPill: some View {
        Button {
            isShowingPlan = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.success)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                pillText(planLabel)
                pillChevron
            }
        }
        .buttonStyle(.plain)
        .pillCapsule()
        .accessibilityLabel("Plan, \(planLabel)")
        .accessibilityHint("Shows your plan and allowances")
    }

    private var planLabel: String {
        session.currentUser?.planLabel ?? "PRO"
    }

    private var rolePill: some View {
        Menu {
            ForEach(PractitionerRole.allCases) { role in
                Button {
                    practice.select(role)
                } label: {
                    if role == practice.role {
                        Label(role.label, systemImage: "checkmark")
                    } else {
                        Text(role.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                pillText(practice.role.label)
                pillChevron
            }
        }
        .pillCapsule()
        .accessibilityLabel("Role, \(practice.role.label)")
        .accessibilityHint("Switches the role the app works in")
    }

    private func pillText(_ title: String) -> some View {
        Text(title)
            .font(.brand(.caption, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
    }

    private var pillChevron: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
    }

    private var bellButton: some View {
        Button {
            isShowingUpdates = true
        } label: {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unread > 0 ? "Updates, \(unread) unread" : "Updates")
        .accessibilityHint("New orders, hearing dates and status on your matters")
    }

    private var profileButton: some View {
        Button {
            isShowingYou = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-profile")
        .accessibilityLabel("Your account")
        .accessibilityHint("Your profile, plan and settings")
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if isOffline {
            OfflineStrip()
        }
        if let standing = session.standing {
            AccountStandingBanner(standing: standing)
        }
    }

    // MARK: - Composer

    private var mode: ChatModel {
        chosenMode ?? AnswerModeDefault.starting(feeTier: session.currentUser?.feeTier)
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

    /// The words go to Ask, with their files and the answer mode chosen here. Nothing is sent
    /// from this tab: Ask is where the question is read and answered.
    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, canSend else { return }
        composerFocused = false
        navigator.ask(question, about: attachments, model: mode)
        text = ""
        attachments = []
        chosenMode = nil
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                actionChip("Draft a petition", systemImage: "doc.text", hint: "Opens the drafting workspace") {
                    vaultMatterID = nil
                    isShowingDrafting = true
                }
                actionChip("New chat", systemImage: "square.and.pencil", hint: "A fresh question on Ask") {
                    navigator.startNewQuestion()
                }
                actionChip("Find a case", systemImage: "magnifyingglass", hint: "Looks a case up at its court and pins it") {
                    isFindingCase = true
                }
            }
            .padding(.horizontal, Spacing.gutter)
        }
        .padding(.horizontal, -Spacing.gutter)
    }

    private func actionChip(
        _ title: String, systemImage: String, hint: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ChipLabel(title: title, systemImage: systemImage, isSelected: false)
        }
        .buttonStyle(ChipButtonStyle(isSelected: false))
        .accessibilityHint(hint)
    }

    // MARK: - Cards

    private var cards: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            causeListCard
            vaultCard
        }
    }

    /// The next day anything of the user's is listed, and the count listed today when today has
    /// something. Picked the way the Cases tab windows the list — India's days, never the
    /// device's (`MattersOverview`).
    private var overview: MattersOverview? {
        causeList.map { MattersOverview(listings: $0.listings, todayKey: $0.todayKey) }
    }

    private var causeListBadge: (text: String, tone: StatusPill.Tone)? {
        guard let causeList, let overview else { return nil }
        let todayCount = causeList.listings.filter { $0.date == causeList.todayKey }.count
        if todayCount > 0 {
            return (text: "\(todayCount) today", tone: .success)
        }
        guard let day = overview.nextSitting else { return nil }
        return (text: "\(day.listings.count) \(overview.dayLabel(day.key))", tone: .accent)
    }

    private var causeListCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                IconTile(systemImage: "calendar")
                Text("Cause List")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.xs)
                if let badge = causeListBadge {
                    StatusPill(text: badge.text, tone: badge.tone)
                }
            }

            if let day = overview?.nextSitting {
                VStack(spacing: Spacing.sm) {
                    ForEach(Array(day.listings.prefix(2).enumerated()), id: \.element.id) { _, listing in
                        Button {
                            openHearing = listing
                        } label: {
                            HomeHearingRow(listing: listing)
                        }
                        .buttonStyle(.recordRow)
                    }
                }
            } else if causeList?.state.isLoading == true {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Text("Nothing of your matters is listed ahead. \(CauseListViewModel.Copy.confirmWithCourt)")
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Button {
                navigator.selectedTab = .cases
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text("View all hearings")
                    Spacer(minLength: Spacing.xs)
                    Image(systemName: "arrow.right")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .font(.brand(.caption, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(maxWidth: .infinity, minHeight: Layout.touchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens every hearing on Cases")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .top)
        .panel()
    }

    /// The drafting taxonomy, for every role — the platform's own matter chooser in miniature.
    /// Each chip opens the workspace on that matter; the arrow opens it on the last one worked
    /// on, which the workspace remembers.
    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                IconTile(systemImage: "building.columns")
                Text("Precedents Vault")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.xs)
                Button {
                    vaultMatterID = nil
                    isShowingDrafting = true
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.brand(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open drafting")
                .accessibilityHint("Opens the drafting workspace")
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.sm),
                    GridItem(.flexible()),
                ],
                spacing: Spacing.sm
            ) {
                ForEach(Self.vaultMatters) { matter in
                    Button {
                        vaultMatterID = matter.id
                        isShowingDrafting = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: matter.systemImage)
                                .imageScale(.small)
                                .foregroundStyle(theme.accentText)
                                .accessibilityHidden(true)
                            Text(matter.chipLabel)
                                .font(.brand(.caption, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Layout.touchTarget)
                    .contentShape(Rectangle())
                    .accessibilityLabel(matter.label)
                    .accessibilityHint("Opens drafting for \(matter.label)")
                }
            }

            if let draft = drafts?.items.first {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Recent work")
                        .recordText(RecordTokens.Typography.label)
                        .foregroundStyle(theme.textTertiary)
                    Button {
                        drafts?.open(draft)
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "doc.text")
                                .imageScale(.small)
                                .foregroundStyle(theme.accentText)
                                .accessibilityHidden(true)
                            Text(draft.displayTitle)
                                .font(.brand(.caption, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: Spacing.xs)
                            Image(systemName: "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: Layout.touchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the draft")
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .top)
        .panel()
    }

    /// The four matters the design's vault chips carry — Civil, Tax, Criminal, IPR — in the
    /// design's order, drawn from the platform's own taxonomy.
    private static let vaultMatters: [LitigatorMatter] = {
        let byID = Dictionary(uniqueKeysWithValues: LITIGATOR_MATTERS.map { ($0.id, $0) })
        return ["civil", "tax", "criminal", "ipr"].compactMap { byID[$0] }
    }()

    // MARK: - Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSectionLabel(
                title: "Recents",
                actionTitle: "View all",
                action: { navigator.selectedTab = .history })
            if let chats {
                if chats.chats.isEmpty {
                    Text(chats.isLoading
                         ? "Loading your conversations…"
                         : "No conversations yet. Ask anything above to start one.")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    RecordGroup {
                        ForEach(Array(chats.chats.prefix(5).enumerated()), id: \.element.id) { index, chat in
                            if index > 0 { RecordDivider(inset: 14) }
                            Button {
                                path.append(ChatRoute(id: chat.id))
                            } label: {
                                HStack(spacing: Spacing.sm) {
                                    Text(chat.displayTitle)
                                        .font(.brand(.body, weight: .medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .dynamicLineLimit(1)
                                    Spacer(minLength: Spacing.sm)
                                    if let when = chat.updatedAt {
                                        Text(DisplayText.relative(when))
                                            .font(.brand(.caption))
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, minHeight: Layout.listRow, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.recordRow)
                            .accessibilityIdentifier("chat-row-\(chat.id)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func loadOnce() async {
        if causeList == nil {
            causeList = CauseListViewModel(service: session.cases, cache: session.cache)
        }
        if chats == nil {
            chats = ChatListViewModel(service: session.chats, cache: session.cache)
        }
        if drafts == nil {
            drafts = DraftHistoryViewModel(service: session.drafts)
        }
        let causeList = self.causeList
        let chats = self.chats
        let drafts = self.drafts
        await causeList?.load()
        await chats?.load()
        await drafts?.load()
        unread = (try? await session.notifications.unreadCount()) ?? 0
    }

    private func reload() async {
        let causeList = self.causeList
        let chats = self.chats
        let drafts = self.drafts
        await causeList?.load()
        await chats?.load()
        await drafts?.load()
    }
}

/// A hearing in the Home cause-list card: the matter, where in the court it sits, and the time
/// it is called — or the mark that it is listed, when the list carries no time.
private struct HomeHearingRow: View {
    @Environment(\.theme) private var theme
    let listing: CauseListing

    var body: some View {
        let display = listing.display
        let place = [
            display.room ?? MattersOverview.courtShortName(listing.courtName),
            display.item.map { "Item #\($0)" },
        ].compactMap { $0 }.joined(separator: " · ")
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(listing.displayTitle)
                    .font(.brand(.caption, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(1)
                if !place.isEmpty {
                    Text(place)
                        .font(.brand(.caption2))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let time = display.time, !time.isEmpty {
                Text(time)
                    .font(.brand(.caption2, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            } else {
                Circle()
                    .fill(theme.success)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.sm + 2)
        .padding(.vertical, Spacing.sm - 2)
        .frame(minHeight: 44)
        .background(
            theme.surface2,
            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [listing.displayTitle, place.isEmpty ? nil : place, display.time]
                .compactMap { $0 }
                .joined(separator: ", "))
        .accessibilityHint("Shows the hearing")
    }
}

/// What the plan and role pills wear: a recessed capsule the size of a comfortable tap.
private struct HomePillCapsule: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.separator, lineWidth: 1))
            .frame(minHeight: Layout.touchTarget)
            .contentShape(Rectangle())
    }
}

private extension View {
    func pillCapsule() -> some View { modifier(HomePillCapsule()) }
}

/// What the plan pill opens: the account's plan, its standing and this month's allowances — the
/// same section Settings shows, as a page-sized sheet over Home.
private struct HomePlanSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                PlanUsageSection()
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            .navigationTitle("Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .pageSizedSheet()
        .presentationDragIndicator(.visible)
    }
}
