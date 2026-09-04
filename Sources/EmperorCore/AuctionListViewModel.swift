import Foundation
#if canImport(Darwin)
import Observation
#endif

/// The liquidation e-auction browser.
///
/// The screen behind the `auction` notification, whose link — `/auction-notices/<id>` — has
/// pointed at nothing since the producer was written (`NotificationModels.destination`).
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AuctionListViewModel {

    /// Framing copy. Kept in one place so the list, the detail screen and the empty state cannot
    /// drift apart about what this feed is and is not.
    enum Copy {
        static let title = "Liquidations"
        static let subtitle = "IBBI e-auction notices"
        /// The safety sentence, in the register of `CauseListViewModel.Copy.confirmWithCourt`.
        ///
        /// Every figure on this screen was parsed out of a PDF by a scraper. A reserve price
        /// read wrongly by one digit is a factor of ten, and the only authority is the notice
        /// itself — so nothing here is ever presented as final.
        static let confirmWithNotice =
            "Figures are read from the published notice. Confirm the reserve price, EMD and dates against the notice PDF before acting."
    }

    private(set) var notices: [AuctionNotice] = []
    /// How many notices match the current filter, server-side. Not the number on screen.
    private(set) var total = 0
    private(set) var state: LoadState = .idle
    private(set) var isLoadingMore = false
    private(set) var facets = AuctionFacets.empty
    private(set) var watchlists: [AuctionWatchlist] = []
    private(set) var isWorking = false

    var query = ""
    var selectedType: String?
    var selectedPlatform: String?
    var sort: AuctionSort = .auctionDateAscending
    /// Defaults on. Someone opening this screen is looking for something to bid at, and the feed
    /// is mostly history — the backfill goes back years.
    var upcomingOnly = true

    var actionError: String?
    var actionNotice: String?

    /// One surface for both outcomes.
    ///
    /// SwiftUI presents a single alert per view: attaching one modifier for errors and another
    /// for confirmations means whichever is applied second never appears at all, and the loss is
    /// invisible — the screen simply stays silent where it should have spoken.
    var isShowingAnnouncement: Bool { actionError != nil || actionNotice != nil }
    var announcementTitle: String { actionError != nil ? "Could not do that" : "Watchlist" }
    var announcementMessage: String { actionError ?? actionNotice ?? "" }

    func dismissAnnouncement() {
        actionError = nil
        actionNotice = nil
    }

    private let service: any AuctionProviding
    private let now: @Sendable () -> Date
    /// Rows consumed from the server, which is **not** `notices.count` once a duplicate has been
    /// dropped. See `loadMore`.
    private var offset = 0
    /// The filter the rows on screen answer.
    private var loadedFilter: AuctionFilter?

    init(
        service: any AuctionProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
    }

    // MARK: - Presentation

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: notices.isEmpty)
    }

    var filter: AuctionFilter {
        AuctionFilter(
            query: query,
            type: selectedType,
            platform: selectedPlatform,
            upcomingOnly: upcomingOnly,
            sort: sort)
    }

    var todayKey: String { WireDate.dayKey(now()) }

    func status(of notice: AuctionNotice) -> AuctionStatus { notice.status(today: todayKey) }

    /// Whether the server says there is more behind what has been loaded.
    ///
    /// Measured against `offset` rather than `notices.count`: those diverge as soon as one
    /// duplicate row is dropped, and using the shorter number would ask the server for a window
    /// it has already sent.
    var canLoadMore: Bool { offset < total }

    var resultSummary: String? {
        guard total > 0 else { return nil }
        if notices.count >= total {
            return "\(IndianMoney.digits(total)) notice\(total == 1 ? "" : "s")"
        }
        return "\(IndianMoney.digits(notices.count)) of \(IndianMoney.digits(total))"
    }

    var emptyTitle: String {
        filter.isNarrowed ? "No notices match" : "No auction notices"
    }

    /// The sentence under the empty state.
    ///
    /// The upcoming-only filter is called out by name because it is on by default: a search that
    /// finds nothing is very often a company whose auction has already happened, and a reader
    /// who is not told about the filter concludes there was never a notice.
    var emptyDetail: String {
        guard filter.isNarrowed else {
            return "No liquidation auction notices have been published to this feed yet."
        }
        if upcomingOnly {
            return """
                Nothing matching is still to come. Turn off "Upcoming only" to search auctions \
                that have already been held.
                """
        }
        return "Nothing matches these filters. Try a shorter search term."
    }

    // MARK: - Loading

    func load() async {
        let requested = filter
        // A plain refresh keeps what is on screen if it fails, so a dropped connection does not
        // blank a list someone is reading. A *filter change* does not get that treatment: those
        // rows answer a different question, and leaving them under a new search term is how
        // someone concludes a company has an auction it does not have.
        if let loadedFilter, loadedFilter != requested {
            notices = []
            total = 0
            offset = 0
        }

        state = .loading
        do {
            let page = try await service.notices(
                filter: requested, limit: AuctionService.pageSize, offset: 0)
            notices = Self.deduplicated(page.notices)
            // What the server sent, not what survived deduplication — see `loadMore`.
            offset = page.notices.count
            total = page.total
            loadedFilter = requested
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }

        await loadFacetsIfNeeded()
        // `loadWatchlistsIfNeeded()` deliberately not called — see the note on the watchlist
        // section below. Holding the UI back but still fetching on every load would leave the
        // route being hit for a feature the user cannot reach.
    }

    /// Appends the next page.
    ///
    /// - Important: paging here is offset-based against a live table with **no cursor**
    ///   (`sync-server.js:10330`). A notice ingested between two requests shifts every row after
    ///   it by one, so the same notice can arrive on two consecutive pages — and a duplicate id
    ///   in a `ForEach` is a SwiftUI trap, not a cosmetic problem.
    ///
    ///   The subtle half is the offset. Dropping a duplicate and then deriving the next offset
    ///   from `notices.count` would ask the server for the same window again, which returns the
    ///   same duplicates, which are dropped again — a loop that never advances and never errors.
    ///   So the offset counts what the server *sent*.
    func loadMore() async {
        guard canLoadMore, !isLoadingMore, state.hasLoaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await service.notices(
                filter: loadedFilter ?? filter,
                limit: AuctionService.pageSize,
                offset: offset)
            // An empty page against a `total` that promises more means the table shrank under
            // us. Believe the page: continuing would spin.
            guard !page.notices.isEmpty else {
                total = notices.count
                return
            }
            let known = Set(notices.map(\.id))
            notices += Self.deduplicated(page.notices).filter { !known.contains($0.id) }
            offset += page.notices.count
            total = page.total
        } catch {
            // A failed page does not invalidate the rows already on screen.
            actionError = DisplayText.message(for: error)
        }
    }

    /// Removes repeats *within* one page as well, keeping the first. The route can return the
    /// same row twice in a single window when `ORDER BY` has ties it cannot break.
    private static func deduplicated(_ notices: [AuctionNotice]) -> [AuctionNotice] {
        var seen = Set<String>()
        return notices.filter { seen.insert($0.id).inserted }
    }

    private func loadFacetsIfNeeded() async {
        guard facets.isEmpty else { return }
        // Best-effort: the filter menu having no options is a smaller failure than the list
        // reporting one, and this call cannot affect what is on screen.
        facets = (try? await service.facets()) ?? .empty
    }

    // MARK: - Watchlists (built, tested, and held back)
    //
    // Nothing below has a caller in the app. A watchlist names the companies a firm is tracking
    // — litigation strategy, not a preference — so it is withheld until the contract of that
    // endpoint is confirmed.
    //
    // Kept rather than deleted, and kept under test, because the client side is correct.
    // Re-adding the toolbar item and the sheet is the whole of the job when that is settled.
    //
    // **Do not wire these up without checking the endpoint first.** The Android client reached
    // the same conclusion independently.

    private var hasLoadedWatchlists = false

    private func loadWatchlistsIfNeeded() async {
        guard !hasLoadedWatchlists else { return }
        if let loaded = try? await service.watchlists() {
            watchlists = loaded
            hasLoadedWatchlists = true
        }
    }

    func reloadWatchlists() async {
        hasLoadedWatchlists = false
        await loadWatchlistsIfNeeded()
    }

    func isWatching(cin: String?) -> Bool {
        guard let cin = Self.text(cin) else { return false }
        return watchlists.contains {
            $0.trimmedCIN?.caseInsensitiveCompare(cin) == .orderedSame
        }
    }

    func isWatching(keyword: String?) -> Bool {
        guard let keyword = Self.text(keyword) else { return false }
        return watchlists.contains {
            $0.trimmedKeyword?.caseInsensitiveCompare(keyword) == .orderedSame
        }
    }

    /// Starts a watch, refusing one this user already has.
    ///
    /// The route has no uniqueness constraint and no dedup — a second identical POST inserts a
    /// second row and answers 200 (`sync-server.js:10386`). The watcher then receives two
    /// notifications for every future notice, and nothing on the server or in the UI explains
    /// why. Refusing locally is the only place this can be caught.
    func watch(cin: String? = nil, keyword: String? = nil) async {
        guard !isWorking else { return }
        let cin = Self.text(cin)
        let keyword = Self.text(keyword)

        // Mirrors the guard in `AuctionService.watch`. Both are needed: the service one stops a
        // 500 round trip, this one stops the confirmation from being composed out of nothing.
        guard cin != nil || keyword != nil else {
            actionError = "Enter a company CIN or a keyword to watch for."
            return
        }

        if isWatching(cin: cin) || isWatching(keyword: keyword) {
            actionNotice = "You are already watching that."
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.watch(cin: cin, keyword: keyword)
            actionNotice = "Watching \(DisplayText.list([cin, keyword].compactMap { $0 })). New notices will appear in your updates."
            await reloadWatchlists()
        } catch {
            actionError = DisplayText.message(for: error)
        }
    }

    /// Stops a watch.
    ///
    /// The list is re-read afterwards rather than edited in place, because a 403 means either
    /// "not yours" or "already gone" and the two are indistinguishable from here — so the local
    /// copy cannot be trusted either way once the call has failed.
    func unwatch(_ watch: AuctionWatchlist) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await service.unwatch(id: watch.id)
            watchlists.removeAll { $0.id == watch.id }
        } catch {
            actionError = DisplayText.message(for: error)
            await reloadWatchlists()
        }
    }

    private static func text(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One auction notice, with whatever amends it.
///
/// Lives beside the list model rather than in its own file because the two share the same
/// service and the same reading of what a notice means; splitting them would put
/// `Copy.confirmWithNotice` two files away from the screen that must show it.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class AuctionDetailViewModel {

    let noticeID: String
    private(set) var detail: AuctionNoticeDetail?
    private(set) var state: LoadState = .idle
    private(set) var isWorking = false
    var actionError: String?
    var actionNotice: String?

    /// See `AuctionListViewModel.isShowingAnnouncement` — one alert per view.
    var isShowingAnnouncement: Bool { actionError != nil || actionNotice != nil }
    var announcementTitle: String { actionError != nil ? "Could not do that" : "Watchlist" }
    var announcementMessage: String { actionError ?? actionNotice ?? "" }

    func dismissAnnouncement() {
        actionError = nil
        actionNotice = nil
    }

    private let service: any AuctionProviding
    private let now: @Sendable () -> Date

    init(
        noticeID: String,
        service: any AuctionProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.noticeID = noticeID
        self.service = service
        self.now = now
    }

    var notice: AuctionNotice? { detail?.notice }
    var amendments: [AuctionNotice] { detail?.amendments ?? [] }

    var presentation: ListPresentation {
        ListPresentation(state: state, isEmpty: detail == nil)
    }

    var status: AuctionStatus {
        notice?.status(today: WireDate.dayKey(now())) ?? .undated
    }

    var title: String { notice?.displayDebtor ?? "Auction notice" }

    /// The warning shown above everything else when a later notice changes this one.
    ///
    /// A corrigendum exists precisely to alter a figure — most often the reserve price or the
    /// auction date. Showing this notice's numbers without saying that would present superseded
    /// terms as current, which is the single most expensive mistake this screen could invite.
    var supersededWarning: String? {
        guard let latest = detail?.latestAmendment else { return nil }
        let count = amendments.count
        let lead = count == 1
            ? "A \(latest.type.label.lowercased()) was issued after this notice."
            : "\(count) later notices amend this one."
        return """
            \(lead) Read it before relying on any figure below — an amendment routinely changes \
            the reserve price or the auction date.
            """
    }

    /// The reference of the notice this one amends, when it is itself a corrigendum or addendum.
    ///
    /// Text, never a link: the earlier notice can only be addressed by its `unique_number`, and
    /// that lookup is unreachable through this API — see `AuctionService.notice(id:)`.
    var amendsReference: String? {
        guard let raw = notice?.supersedesUniqueNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.hasPrefix("fallback:")
        else { return nil }
        return raw
    }

    var amendsExplanation: String? {
        guard let reference = amendsReference else { return nil }
        return "This \(notice?.type.label.lowercased() ?? "notice") amends notice \(reference)."
    }

    /// Whether a company watch can be set from this notice.
    ///
    /// Watches match on `cin` by equality, and a fallback row has no CIN at all — the listing
    /// page does not carry one. Offering the button anyway would create a watch that can never
    /// fire.
    var watchableCIN: String? {
        let trimmed = notice?.cin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func load() async {
        state = .loading
        do {
            detail = try await service.notice(id: noticeID)
            state = .loaded
        } catch {
            state = .failed(LoadFailure(error))
        }
    }

    func watchCompany() async {
        guard let cin = watchableCIN, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.watch(cin: cin, keyword: nil)
            actionNotice = "Watching \(cin). New notices for this company will appear in your updates."
        } catch {
            actionError = DisplayText.message(for: error)
        }
    }
}
