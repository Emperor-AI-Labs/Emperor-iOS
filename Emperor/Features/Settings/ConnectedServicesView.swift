import SwiftUI
import SafariServices

/// You → Connected services: Google Drive and OneDrive, as the web's Settings card has them.
///
/// Every decision is `CloudConnectionsViewModel`'s. The one thing this file adds is the browser:
/// a drive's sign-in page is shown in an in-app Safari view, and the connections are read again
/// once it closes — see the view model for why that, and not a callback, is how the outcome is
/// learned.
struct ConnectedServicesView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: CloudConnectionsViewModel?
    @State private var confirmingDisconnect: CloudDriveConnection?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.canvas)
            }
        }
        .navigationTitle("Connected services")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = CloudConnectionsViewModel(service: session.cloudDrives)
            }
            await model?.load()
        }
        // Back from Safari proper (the page's own "Open in Safari"), or from the web, where a
        // drive may have been connected meanwhile.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let model, model.consentPage == nil else { return }
            Task { await model.load() }
        }
    }

    private func content(_ model: CloudConnectionsViewModel) -> some View {
        List {
            drivesSection(model)
        }
        .font(.brand(.body))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
        .refreshable { await model.load() }
        .onChange(of: model.notice) { _, notice in
            if let notice { VoiceOver.announce(notice) }
        }
        .sheet(
            item: Binding(
                get: { model.consentPage },
                set: { if $0 == nil { model.consentPage = nil } }),
            onDismiss: { Task { await model.browserDidClose() } }
        ) { page in
            CloudSignInPage(url: page.url) { model.consentPage = nil }
                .ignoresSafeArea()
        }
        .confirmationDialog(
            confirmingDisconnect.map { "Disconnect \($0.label)?" } ?? "Disconnect?",
            isPresented: Binding(
                get: { confirmingDisconnect != nil },
                set: { if !$0 { confirmingDisconnect = nil } }),
            titleVisibility: .visible
        ) {
            // Captured now: the dialog clears its binding before the task would read it.
            let chosen = confirmingDisconnect
            Button("Disconnect", role: .destructive) {
                if let chosen {
                    Task { await model.disconnect(chosen.drive) }
                }
            }
            Button("Cancel", role: .cancel) { confirmingDisconnect = nil }
        } message: {
            Text("Emperor stops reaching this drive, here and on the web. Files already saved to it stay there.")
        }
    }

    @ViewBuilder
    private func drivesSection(_ model: CloudConnectionsViewModel) -> some View {
        Section {
            if model.connections.isEmpty {
                if case .failed(let failure) = model.state {
                    failureRow(failure, model: model)
                } else {
                    HStack(spacing: Spacing.sm) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            } else {
                ForEach(model.connections) { connection in
                    CloudDriveRow(
                        connection: connection,
                        status: model.status(of: connection),
                        isBusy: model.isBusy(connection.drive),
                        isLocked: model.busy != nil,
                        connect: { Task { await model.connect(connection.drive) } },
                        disconnect: { confirmingDisconnect = connection })
                }
            }
        } header: {
            SectionHeader(title: "Drives")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let notice = model.notice {
                    Text(notice)
                        .foregroundStyle(theme.textPrimary)
                        .accessibilityIdentifier("cloud-notice")
                }
                if !model.connections.isEmpty, case .failed(let failure) = model.state {
                    Text(failure.message)
                        .foregroundStyle(theme.textPrimary)
                }
                Text(CloudConnectionsViewModel.Copy.howToConnect)
                Text(CloudConnectionsViewModel.Copy.footer)
            }
            .font(.brand(.caption))
            .foregroundStyle(theme.textSecondary)
        }
        .listRowBackground(theme.surface)
    }

    private func failureRow(_ failure: LoadFailure, model: CloudConnectionsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(CloudConnectionsViewModel.Copy.loadFailed)
                .font(.brand(.subheadline, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text(failure.message)
                .font(.brand(.footnote))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if failure.isRetryable {
                Button("Try again") {
                    Task { await model.load() }
                }
                .font(.brand(.subheadline, weight: .semibold))
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// The You tab's row for this screen. A section of its own, like `AppLockSettingsSection`, so the
/// You list's body stays small enough for the type checker.
struct ConnectedServicesSection: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            NavigationLink {
                ConnectedServicesView()
            } label: {
                IconRowLabel(title: "Connected services", systemImage: "externaldrive.badge.icloud")
            }
            .accessibilityIdentifier("connected-services")
        } header: {
            SectionHeader(title: "Connected services")
        } footer: {
            Text("Google Drive and OneDrive: save documents to your drive, and import from it into My Files.")
                .font(.brand(.caption))
                .foregroundStyle(theme.textTertiary)
        }
        .listRowBackground(theme.surface)
    }
}

/// One drive: its name, how it stands, and the one thing to do about it.
private struct CloudDriveRow: View {
    @Environment(\.theme) private var theme

    let connection: CloudDriveConnection
    let status: String
    let isBusy: Bool
    /// Another drive's action is running.
    let isLocked: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        AdaptiveStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                IconTile(systemImage: "externaldrive.badge.icloud", hue: .teal)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(connection.label)
                        .font(.brand(.body, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(status)
                        .font(.brand(.footnote))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            action
        }
        .padding(.vertical, Spacing.xxs)
    }

    @ViewBuilder
    private var action: some View {
        if isBusy {
            ProgressView()
                .accessibilityLabel(Text("Working on \(connection.label)"))
        } else if !connection.configured {
            EmptyView()
        } else if connection.connected {
            Button("Disconnect", action: disconnect)
                .buttonStyle(.bordered)
                .disabled(isLocked)
                .accessibilityLabel(Text("Disconnect \(connection.label)"))
                .accessibilityIdentifier("cloud-disconnect-\(connection.drive.rawValue)")
        } else {
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(isLocked)
                .accessibilityLabel(Text("Connect \(connection.label)"))
                .accessibilityIdentifier("cloud-connect-\(connection.drive.rawValue)")
        }
    }
}

/// The drive's sign-in page, in an in-app Safari view.
///
/// Safari rather than a web view: Google refuses its sign-in inside an embedded web view, and the
/// person can see the address they are signing in at. `onFinish` runs when they tap Done.
struct CloudSignInPage: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
