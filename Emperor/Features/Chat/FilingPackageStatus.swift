import SwiftUI

/// What the screen shows while a filing-ready package is made: a progress strip at the foot,
/// then the share sheet with the file — or why it was not made.
struct FilingPackageStatus: ViewModifier {
    @Environment(\.theme) private var theme
    let export: FilingPackageExport?
    let title: String

    @State private var shared: SharedPackage?

    private struct SharedPackage: Identifiable {
        let id = UUID()
        let url: URL
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if let export, let fraction = export.fraction {
                    progress(fraction)
                }
            }
            .onChange(of: export?.phase) { _, phase in
                guard case .ready(let data, let format)? = phase else { return }
                let name = FilingPackage.fileName(title: title, format: format)
                if let url = ShareableFile.url(for: data, named: name) {
                    shared = SharedPackage(url: url)
                }
            }
            .sheet(item: $shared) { package in
                ActivityView(url: package.url) {
                    shared = nil
                    export?.reset()
                }
                .presentationDetents([.medium, .large])
            }
            .alert("The package wasn't made", isPresented: failureBinding) {
                Button("OK") { export?.reset() }
            } message: {
                Text(failureMessage ?? "")
            }
            .sheet(isPresented: refusalBinding) {
                if case .refused(let refusal)? = export?.phase {
                    RefusalCard(refusal: refusal)
                        .padding(Spacing.lg)
                        .presentationDetents([.medium])
                }
            }
    }

    private func progress(_ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Preparing the filing-ready package…")
                .font(.brand(.footnote, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            ProgressView(value: fraction)
                .tint(theme.accent)
        }
        .padding(Spacing.md)
        .background(theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    private var failureMessage: String? {
        if case .failed(let message)? = export?.phase { return message }
        return nil
    }

    private var failureBinding: Binding<Bool> {
        Binding(get: { failureMessage != nil }, set: { if !$0 { export?.reset() } })
    }

    private var refusalBinding: Binding<Bool> {
        Binding(
            get: { if case .refused? = export?.phase { return true } else { return false } },
            set: { if !$0 { export?.reset() } })
    }
}

extension View {
    /// Progress, share sheet and failure for a filing-ready package made from this screen.
    func filingPackageStatus(_ export: FilingPackageExport?, title: String) -> some View {
        modifier(FilingPackageStatus(export: export, title: title))
    }
}
