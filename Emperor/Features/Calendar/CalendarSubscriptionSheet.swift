import SwiftUI
import UniformTypeIdentifiers

/// Subscribing to the user's hearings and diary from the iOS Calendar app.
///
/// Three actions, in the order they are wanted: **Subscribe in Calendar** hands the link to the
/// Calendar app as `webcal://`, which opens its own "Subscribe" sheet; **Copy link** gives the
/// `https` form for Google or Outlook, which take a calendar "from URL"; **Reset link** issues a
/// new secret and kills the old one, for when the link has gone somewhere it should not.
///
/// The link is a credential — anyone holding it can read the feed — so it is never printed on
/// screen, never offered through a share sheet (which invites it into an email), and copied
/// with an expiry. What the screen shows is where it points and what holding it means.
struct CalendarSubscriptionSheet: View {
    @Environment(\.theme) private var theme
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var model: CalendarSubscriptionViewModel?
    @State private var isConfirmingReset = false
    @State private var didCopy = false

    /// Long enough to switch to a laptop and paste it into Google Calendar; short enough that a
    /// copied credential does not sit on the clipboard, and on Universal Clipboard, all day.
    private static let clipboardLifetime: TimeInterval = 10 * 60

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Subscribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard model == nil else { return }
                let created = CalendarSubscriptionViewModel(service: session.calendarFeed)
                model = created
                await created.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: CalendarSubscriptionViewModel) -> some View {
        ListStateView(presentation: model.presentation, retry: { await model.load() }) {
            List {
                Section {
                    intro
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 4, trailing: 4))
                }

                Section {
                    Button {
                        subscribe(model)
                    } label: {
                        Label("Subscribe in Calendar", systemImage: "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.primaryAction)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .disabled(!model.canUseLink)

                    Button {
                        copy(model)
                    } label: {
                        Label(
                            didCopy ? "Copied" : "Copy link",
                            systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .font(.brand(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.accentText)
                            // The whole row takes the tap, not only the glyph and the words.
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(theme.surface)
                    .disabled(!model.canUseLink)
                    .accessibilityHint("For Google Calendar or Outlook, which add a calendar from a URL")
                    // "Copied" long enough to be read, then back to the action.
                    .task(id: didCopy) {
                        guard didCopy else { return }
                        try? await Task.sleep(for: .seconds(2))
                        didCopy = false
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(CalendarSubscriptionViewModel.Copy.privacy, systemImage: "lock")
                        if let host = model.link?.host, !host.isEmpty {
                            Text("Served from \(host).")
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    .font(.brand(.caption))
                    .foregroundStyle(theme.textSecondary)
                }

                if model.didReset {
                    Section {
                        Label(CalendarSubscriptionViewModel.Copy.resetDone,
                              systemImage: "checkmark.circle")
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.success)
                    }
                    .listRowBackground(theme.surface)
                }

                Section {
                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        HStack {
                            Label("Reset link…", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(theme.danger)
                            Spacer(minLength: Spacing.sm)
                            if model.isResetting {
                                ProgressView()
                            }
                        }
                        .font(.brand(.subheadline, weight: .medium))
                    }
                    .disabled(!model.canUseLink)
                } footer: {
                    Text("Use this if the link has reached anyone it should not have. Every calendar using it stops updating.")
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.groupedBackground)
            // The confirmation lands in a section of its own, away from the dialog's button.
            .onChange(of: model.didReset) { _, didReset in
                if didReset { VoiceOver.announce(CalendarSubscriptionViewModel.Copy.resetDone) }
            }
        } empty: {
            // Unreachable in practice: a load that returns carries a link or throws. Legible
            // rather than blank if that ever stops being true.
            EmptyStateView(
                "No link yet", systemImage: "link",
                message: "Emperor did not return a calendar link. Try again shortly.",
                tone: .neutral)
        }
        .confirmationDialog(
            CalendarSubscriptionViewModel.Copy.resetTitle,
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset link", role: .destructive) {
                Task { await model.reset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CalendarSubscriptionViewModel.Copy.resetMessage)
        }
        .alert("Could not reset the link", isPresented: Binding(
            get: { model.resetError != nil },
            set: { if !$0 { model.resetError = nil } }
        )) {
            Button("OK") { model.resetError = nil }
        } message: {
            Text(model.resetError ?? "")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            IconTile(systemImage: "calendar.badge.plus", hue: .indigo, size: .large)
                .padding(.bottom, Spacing.xs)
            Text("Your diary in Calendar")
                .font(.brand(.title3, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(CalendarSubscriptionViewModel.Copy.explanation)
                .font(.brand(.subheadline))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// `webcal://` is the scheme iOS routes to the Calendar app's own subscribe sheet, which
    /// asks the user to confirm — nothing is added without that. Copy link sits beside it for
    /// any other calendar app.
    private func subscribe(_ model: CalendarSubscriptionViewModel) {
        guard let link = model.link, model.canUseLink else { return }
        openURL(link.subscribeURL)
    }

    private func copy(_ model: CalendarSubscriptionViewModel) {
        guard let link = model.link, model.canUseLink else { return }
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: link.feedURL.absoluteString]],
            options: [.expirationDate: Date().addingTimeInterval(Self.clipboardLifetime)])
        didCopy = true
        // "Copied" replaces the words on the button VoiceOver is on, which it does not re-read.
        VoiceOver.announce("Link copied")
    }
}
