import SwiftUI

/// The Home tab — the design's dashboard.
///
/// The design's own bar across the top: the mark, the plan as a pill, Updates and the profile
/// button — **Account & Profile** opens from the avatar as a sheet. Under it the composer, whose Send carries
/// the question, its files and its answer mode to the Ask tab (`AppNavigator.ask`), which is
/// where the conversation happens; the quick actions; the cause list and the Precedents Vault as
/// the two cards; and the recent conversations, each pushing its thread here.
///
/// Everything the cards need is loaded once and kept — the cause list and the conversations —
/// and pull-to-refresh checks them again. Offline, the composer still holds the words
/// and says so; it does not send.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.navigator) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var path: [ChatRoute] = []
    @State private var causeList: CauseListViewModel?
    @State private var chats: ChatListViewModel?
    @State private var text = ""
    @State private var attachments: [ChatAttachment] = []
    /// The answer mode chosen with the question, or `nil` for the default.
    @State private var chosenMode: ChatModel?
    @State private var isPickingFiles = false
    @State private var isChoosingMode = false
    @State private var isShowingYou = false
    @State private var isShowingPlan = false
    @State private var isShowingUpdates = false
    @State private var isShowingHistory = false
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
                    // The design breathes between the bar and the composer — a touch more than
                    // the mock, so the box reads as its own card and not as a bar extension.
                    .padding(.top, Spacing.xl)
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
            .sheet(isPresented: $isShowingHistory) {
                ChatListView(onDone: { isShowingHistory = false })
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isShowingDrafting) {
                LitigatorWorkspaceView(initialMatterID: vaultMatterID)
                    .pageSizedSheet()
            }
            .sheet(isPresented: $isFindingCase) {
                // A matter pinned from here: the docket lives on Matters and is kept across the
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
            logoMark
            planPill
            Spacer(minLength: Spacing.sm)
            bellButton
            profileButton
        }
        .padding(.horizontal, Spacing.gutter)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The mark — the logo, at the head of the bar, with no tile behind it, as the design draws
    /// it. Decorative; the pill and buttons beside it carry the words.
    private var logoMark: some View {
        RecordMarkView(height: 22)
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
            placeholder: "Ask",
            attachments: attachments.map { DisplayText.fileName($0.name) },
            onRemoveAttachment: { index in
                guard attachments.indices.contains(index) else { return }
                attachments.remove(at: index)
            },
            model: mode,
            onChooseMode: { isChoosingMode = true },
            canSend: canSend,
            showsMark: true,
            onAttach: { isPickingFiles = true },
            onSend: send,
            focus: $composerFocused) {
                // The design's own row: rewrite and dictation. The buttons are drawn; the
                // wiring — the enhancer and Speech — is a later step, so both are no-ops yet.
                composerAccessory("wand.and.stars", label: "Rewrite", tint: theme.warning) {}
                composerAccessory("mic", label: "Dictate", tint: theme.textSecondary) {}
            }
    }

    /// One of the composer's trailing stub buttons — gold for the wand, plain for the mic.
    private func composerAccessory(
        _ systemImage: String, label: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(theme.surface2, in: Circle())
                .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    /// The design's chips: drafting, limitation, the court lookup — the third scrolls in.
    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                actionChip("Draft a petition", systemImage: "doc.text", hint: "Opens the drafting workspace") {
                    vaultMatterID = nil
                    isShowingDrafting = true
                }
                actionChip("Check limitation", systemImage: "hourglass", hint: "Puts a limitation question in the box above") {
                    text = Self.limitationPrompt
                    composerFocused = true
                }
                actionChip("Find a case", systemImage: "magnifyingglass", hint: "Looks a case up at its court and pins it") {
                    isFindingCase = true
                }
            }
            .padding(.horizontal, Spacing.gutter)
        }
        .padding(.horizontal, -Spacing.gutter)
    }

    /// The limitation chip's question — the platform's own wording (`AskHome`).
    private static let limitationPrompt =
        "Is the challenge still within limitation? Work it out from the dates in the attached documents."

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
    /// something. Picked the way Matters windows the list — India's days, never the
    /// device's (`MattersOverview`).
    private var overview: MattersOverview? {
        causeList.map { MattersOverview(listings: $0.listings, todayKey: $0.todayKey) }
    }

    private var causeListBadge: (count: String, caption: String, tone: StatusPill.Tone)? {
        guard let causeList, let overview else { return nil }
        let todayCount = causeList.listings.filter { $0.date == causeList.todayKey }.count
        if todayCount > 0 {
            return (count: "\(todayCount)", caption: "TODAY", tone: .success)
        }
        guard let day = overview.nextSitting else { return nil }
        return (
            count: "\(day.listings.count)",
            caption: overview.dayLabel(day.key).uppercased(),
            tone: .accent)
    }

    private var causeListCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                IconTile(systemImage: "calendar")
                Text("Cause List")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    // Two lines and a small scale step rather than a mid-word break: the badge
                    // beside it used to squeeze the title until "Cause List" split as "Caus e".
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.xs)
                if let badge = causeListBadge {
                    StackedCountBadge(count: badge.count, caption: badge.caption, tone: badge.tone)
                        .layoutPriority(1)
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
                navigator.selectedTab = .matters
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
            .accessibilityHint("Opens every hearing on Matters")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .top)
        .panel()
    }

    /// The drafting taxonomy, for every role — the platform's own matter chooser in miniature.
    /// The chips scroll within the card; each chip opens the workspace on that matter, and the
    /// footer opens it on the last one worked on, which the workspace remembers.
    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                IconTile(systemImage: "building.columns")
                Text("Precedents Vault")
                    .font(.brand(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.xs)
            }

            // Three chips' worth of height, as the design draws it; the rest scroll under.
            ScrollView {
                VStack(spacing: Spacing.sm) {
                    ForEach(Self.vaultMatters) { matter in
                        Button {
                            vaultMatterID = matter.id
                            isShowingDrafting = true
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: matter.systemImage)
                                    .imageScale(.small)
                                    .foregroundStyle(theme.accentText)
                                    .accessibilityHidden(true)
                                Text(matter.label)
                                    .font(.brand(.caption, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .strokeBorder(theme.separator, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel(matter.label)
                        .accessibilityHint("Opens drafting for \(matter.label)")
                    }
                }
            }
            .frame(height: 116)

            Button {
                vaultMatterID = nil
                isShowingDrafting = true
            } label: {
                HStack(spacing: Spacing.xs) {
                    Text("View all precedents")
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
            .accessibilityHint("Opens the drafting workspace")
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .top)
        .panel()
    }

    /// Every matter the platform's taxonomy carries — Civil, Criminal, then the practice areas —
    /// in the platform's own order, so all of them are a flick away in the card's scroll.
    private static let vaultMatters: [LitigatorMatter] = LITIGATOR_MATTERS

    // MARK: - Recents

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSectionLabel(
                title: "Recents",
                actionTitle: "View all",
                action: { isShowingHistory = true })
            if let chats {
                if chats.chats.isEmpty {
                    Text(chats.isLoading
                         ? "Loading your conversations…"
                         : "No conversations yet. Ask anything above to start one.")
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Each conversation its own panel row, as the design draws them — no
                    // shared group with dividers between.
                    VStack(spacing: Spacing.sm) {
                        ForEach(chats.chats.prefix(5), id: \.id) { chat in
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
                            .panel()
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

/// The cause-list card's badge — the count over its caption, as the design stacks them: "3"
/// over "TODAY", green when today has hearings, the accent for a future day's label.
private struct StackedCountBadge: View {
    @Environment(\.theme) private var theme

    let count: String
    let caption: String
    let tone: StatusPill.Tone

    var body: some View {
        VStack(spacing: 0) {
            Text(count)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(caption)
                .font(.system(size: 7.5, weight: .heavy))
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: 38)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(caption.lowercased())")
        .accessibilityIdentifier("status-pill-\(count)-\(caption)")
    }

    private var foreground: Color {
        switch tone {
        case .success: return theme.success
        case .accent, .info: return theme.accentText
        case .warning: return theme.warning
        case .danger: return theme.danger
        case .neutral: return theme.textFaint
        }
    }

    private var fill: Color {
        switch tone {
        case .success: return theme.successBg
        case .accent, .info: return Color(theme.palette.pillWash(theme.palette.accentText))
        case .warning: return theme.warnBg
        case .danger: return theme.dangerBg
        case .neutral: return theme.surface2
        }
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

/// What the plan pill wears: a recessed capsule the size of a comfortable tap.
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
