import Foundation
#if canImport(Darwin)
import Observation
#endif

/// Settings → Notifications.
///
/// Two separate things live on this screen, and the copy keeps them apart:
///
/// - **This device's reminders** — the morning briefing, the evening-before reminder and feed
///   updates. Scheduled by the app itself from the cause list (`NotificationCoordinator`),
///   behind iOS's own permission.
/// - **The account's daily email** — the platform's briefing, the same one the web's settings
///   page switches (`/notif/*`). Account-level, so switching it here switches it there.
///
/// See `ChatViewModel` for why `@Observable` is Apple-only.
#if canImport(Darwin)
@Observable
#endif
@MainActor
final class NotificationSettingsViewModel {

    /// Where the account's daily email stands.
    enum EmailState: Equatable, Sendable {
        case loading
        case loaded(EmailBriefingStatus)
        case failed(String)
    }

    enum Copy {
        static let blocked = "Notifications for Emperor are turned off in iOS Settings."
        /// The honest line: these are scheduled here, not sent by a server.
        static let deviceFooter =
            "Reminders are scheduled on this device from your cause list and refreshed in the background, so one may be out of date if Emperor hasn't run for a while."
        /// Under the hearing reminders. A day with no reminder must not read as a free day.
        static let hearingsFooter =
            "Only on days your matters are listed. \(CauseListViewModel.Copy.confirmWithCourt)"
        static let updatesFooter =
            "New items in Updates — hearing dates, orders, status changes, team news — that arrive while you're away from the app."
        static let emailFailed = "Your email setting couldn't be loaded."
        static let paused = "The daily email is paused for everyone at the moment. Your choice is kept."
        static let testSent = "Sent — it appears at the top of the screen."
        static let testNotSent = "Turn on notifications first."
        static let testEmailFailed = "The test email couldn't be sent just now."
    }

    private(set) var preferences: NotificationPreferences
    private(set) var authorization: NotificationAuthorization = .notDetermined
    private(set) var email: EmailState = .loading
    /// While the email switch is waiting on the server.
    private(set) var isChangingEmail = false
    /// While the permission prompt or a test is in flight.
    private(set) var isBusy = false
    /// The switch the person just turned on, while iOS is asked. Without it the switch would
    /// spring back to off under the system prompt and on again once it is answered.
    private(set) var isTurningOn = false
    /// The email switch's new position, while the server is told.
    private(set) var pendingEmail: Bool?
    /// What the last action came to, for one line under it. Cleared by the next action.
    private(set) var notice: String?
    private(set) var emailNotice: String?

    private let coordinator: NotificationCoordinator
    private let emailService: (any EmailBriefingProviding)?
    private let account: NotificationAccount?
    /// The address the daily email goes to, from the signed-in account.
    let emailAddress: String?

    init(
        coordinator: NotificationCoordinator,
        emailService: (any EmailBriefingProviding)?,
        account: NotificationAccount?,
        emailAddress: String? = nil
    ) {
        self.coordinator = coordinator
        self.emailService = emailService
        self.account = account
        self.emailAddress = emailAddress.flatMap { CauseListText.trimmed($0) }
        self.preferences = coordinator.preferences
    }

    // MARK: - Presentation

    /// What the master switch shows: on here **and** allowed by iOS. Refused in iOS Settings, it
    /// reads off, whatever was chosen here, because nothing will arrive.
    var isOn: Bool { preferences.isEnabled && authorization == .allowed }

    /// What the master switch draws: `isOn`, or on while the person's "on" is being asked about.
    var switchIsOn: Bool { isTurningOn || isOn }

    /// iOS has refused, so the switch cannot work until the person changes it in iOS Settings.
    var isBlocked: Bool { authorization == .denied }

    /// The email switch's position, or `nil` while it is not known.
    var emailOptedIn: Bool? {
        if case .loaded(let status) = email { return status.isOptedIn }
        return nil
    }

    /// What the email switch draws: the position just chosen while the server is told, then
    /// whatever the account says.
    var emailSwitchIsOn: Bool { pendingEmail ?? emailOptedIn ?? false }

    /// The test email is offered only while the daily email is on: the route that sends it also
    /// switches the daily email on, and a test button must not do that.
    var offersTestEmail: Bool { emailOptedIn == true && emailService != nil }

    /// The line under the email switch.
    var emailFooter: String {
        let time: String
        if case .loaded(let status) = email {
            time = status.sendTime
        } else {
            time = NotificationPreferences.clock(8 * 60)
        }
        let recipient = emailAddress.map { " to \($0)" } ?? ""
        var lines = [
            "The same daily cause-list email the web sends, at about \(time) IST\(recipient). Turning it off also stops the web's browser alerts."
        ]
        if case .loaded(let status) = email, status.isPaused {
            lines.append(Copy.paused)
        }
        return lines.joined(separator: " ")
    }

    /// For a time picker showing IST: the briefing time, today.
    var briefingTime: Date { time(preferences.briefingMinutes) }
    var reminderTime: Date { time(preferences.reminderMinutes) }

    private func time(_ minutes: Int) -> Date {
        NotificationPreferences.instant(minutes: minutes, on: WireDate.dayKey(Date())) ?? Date()
    }

    // MARK: - Loading

    func load() async {
        authorization = await coordinator.authorization()
        await loadEmail()
    }

    /// Back from iOS Settings: the permission may have changed there.
    func refreshAuthorization() async {
        authorization = await coordinator.authorization()
        await replan()
    }

    func loadEmail() async {
        guard let emailService else { return }
        email = .loading
        do {
            email = .loaded(try await emailService.status())
        } catch {
            email = .failed(DisplayText.message(for: error))
        }
    }

    // MARK: - This device

    /// The master switch. Turning it on is the one moment the system prompt is shown.
    func setEnabled(_ on: Bool) async {
        notice = nil
        guard on else {
            coordinator.update { $0.isEnabled = false }
            preferences = coordinator.preferences
            await replan()
            return
        }
        isBusy = true
        isTurningOn = true
        defer {
            isBusy = false
            isTurningOn = false
        }
        authorization = await coordinator.requestAuthorization()
        // Refused — now or before: nothing is switched on, and `isBlocked` says why.
        guard authorization == .allowed else { return }
        coordinator.update { $0.isEnabled = true }
        preferences = coordinator.preferences
        // With nothing cached yet — notifications turned on before Home has ever loaded — the
        // cause list is fetched once, so the first briefing is booked now rather than at the
        // next refresh.
        await coordinator.refresh(
            account: account, fetching: account?.cachedCauseList == nil ? .causeList : [])
    }

    func setMorningBriefing(_ on: Bool) async {
        await change { $0.morningBriefing = on }
    }

    func setEveningReminder(_ on: Bool) async {
        await change { $0.eveningReminder = on }
    }

    func setUpdates(_ on: Bool) async {
        await change { $0.updates = on }
    }

    /// From a picker showing IST: only the time of day is read, in India.
    func setBriefingTime(_ date: Date) async {
        let minutes = NotificationPreferences.minutesInIndia(of: date)
        await change { $0.briefingMinutes = minutes }
    }

    func setReminderTime(_ date: Date) async {
        let minutes = NotificationPreferences.minutesInIndia(of: date)
        await change { $0.reminderMinutes = minutes }
    }

    func sendTest() async {
        isBusy = true
        defer { isBusy = false }
        notice = await coordinator.sendTest() ? Copy.testSent : Copy.testNotSent
    }

    private func change(_ edit: (inout NotificationPreferences) -> Void) async {
        notice = nil
        coordinator.update(edit)
        preferences = coordinator.preferences
        await replan()
    }

    private func replan() async {
        await coordinator.refresh(account: account)
    }

    // MARK: - The account's email

    /// Switches the account's daily email, then reads it back rather than assuming: the server's
    /// answer is what the web will show.
    func setEmailBriefing(_ on: Bool) async {
        guard let emailService, !isChangingEmail else { return }
        isChangingEmail = true
        pendingEmail = on
        emailNotice = nil
        defer {
            isChangingEmail = false
            pendingEmail = nil
        }
        do {
            if on {
                try await emailService.optIn()
            } else {
                try await emailService.optOut()
            }
        } catch {
            emailNotice = DisplayText.message(for: error)
        }
        if let status = try? await emailService.status() {
            email = .loaded(status)
        }
    }

    func sendTestEmail() async {
        guard let emailService, offersTestEmail, !isChangingEmail else { return }
        isChangingEmail = true
        emailNotice = nil
        defer { isChangingEmail = false }
        do {
            let result = try await emailService.sendTest()
            emailNotice = result.didEmail
                ? "A test email is on its way\(emailAddress.map { " to \($0)" } ?? "")."
                : Copy.testEmailFailed
        } catch {
            emailNotice = DisplayText.message(for: error)
        }
    }
}
