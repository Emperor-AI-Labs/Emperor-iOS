import SwiftUI
import UniformTypeIdentifiers

/// Split and merge, on the device — the platform's `/tools/split-pdf` and `/tools/merge-pdf`.
///
/// These were one screen with a Split/Merge switch before the hub existed. The behaviour is
/// unchanged: the same four split styles, the same merge order rules, the same `PDFTools` calls.
/// Only the switch went, because the hub is now where a tool is chosen.
///
/// Every output is shared rather than saved: the app has no file browser of its own, and the
/// share sheet already reaches Files, Mail and every other place a bundle part needs to go.

/// A chosen file and what is known about it. `pageCount` is `nil` while unreadable.
private struct PickedPDF: Identifiable {
    let url: URL
    let pageCount: Int?
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

// MARK: - Split

struct SplitPDFView: View {
    @Environment(\.theme) private var theme

    @State private var chosen: PickedPDF?
    @State private var selection = ""
    @State private var splitStyle: SplitStyle = .ranges
    @State private var targetMB = 10
    @State private var isPicking = false
    @State private var outputs: [PDFTools.Output] = []
    @State private var failure: String?

    /// The four ways Android offers, kept the same so someone who uses both is not relearning.
    private enum SplitStyle: String, CaseIterable, Identifiable {
        case ranges = "Extract pages"
        case groups = "Split into parts"
        case every = "Every page"
        case size = "By size"
        var id: String { rawValue }
    }

    private var pageCount: Int { chosen?.pageCount ?? 0 }

    var body: some View {
        Form {
            Section {
                if let chosen {
                    ToolSourceRow(
                        name: chosen.name,
                        detail: chosen.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" }
                            ?? "Could not be opened",
                        change: { isPicking = true })
                } else {
                    Button {
                        isPicking = true
                    } label: {
                        Label("Choose a PDF", systemImage: "doc.badge.plus")
                    }
                }
            } header: {
                SectionHeader(title: "Document")
            }
            .listRowBackground(theme.surface)

            if chosen != nil {
                Section {
                    Picker("How", selection: $splitStyle) {
                        ForEach(SplitStyle.allCases) { Text($0.rawValue).tag($0) }
                    }

                    switch splitStyle {
                    case .ranges, .groups:
                        TextField("1-3, 5, 8-10", text: $selection)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    case .every:
                        EmptyView()
                    case .size:
                        Stepper("About \(targetMB) MB per part", value: $targetMB, in: 1...100)
                    }
                } header: {
                    SectionHeader(title: "Pages")
                } footer: {
                    // A live description of what the current selection would actually produce,
                    // because "1-3, 2" is three pages and reads like four.
                    Text(splitFooter)
                        .font(.brand(.caption))
                        .foregroundStyle(theme.textSecondary)
                }
                .listRowBackground(theme.surface)
            }

            Section {
                ToolRunButton(
                    title: actionLabel, runningTitle: actionLabel,
                    isRunning: false, isEnabled: canRun, action: run)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                OnDeviceNote()
            }

            if let failure {
                Section {
                    ToolFailureRow(message: failure)
                }
                .listRowBackground(theme.surface)
            }

            if !outputs.isEmpty {
                Section {
                    ForEach(outputs) { output in
                        ToolResultRow(file: ToolFile(name: output.name, data: output.data))
                    }
                } header: {
                    SectionHeader(
                        title: "Result",
                        detail: outputs.count > 1 ? "\(outputs.count) files" : nil)
                }
                .listRowBackground(theme.surface)
            }
        }
        .font(.brand(.body))
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle("Split PDF")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            chosen = PickedPDF(url: url, pageCount: PDFTools.pageCount(of: url))
            outputs = []
            failure = nil
        }
    }

    private var actionLabel: String {
        switch splitStyle {
        case .ranges: return "Extract \(PageRanges.describe(selection, pageCount: pageCount))"
        case .groups: return "Split into parts"
        case .every: return pageCount > 0 ? "Split into \(pageCount) files" : "Split"
        case .size: return "Split at about \(targetMB) MB"
        }
    }

    private var splitFooter: String {
        switch splitStyle {
        case .ranges:
            return "\(PageRanges.describe(selection, pageCount: pageCount)) into one document."
        case .groups:
            let count = PageRanges.parseGroups(selection, pageCount: pageCount).count
            return count == 0
                ? "Each part you name becomes its own file."
                : "\(count) file\(count == 1 ? "" : "s"), one per part you named."
        case .every:
            return "One file per page. Names are zero-padded so they sort correctly."
        case .size:
            return "Consecutive pages, packed into parts. A page larger than the target becomes its own part rather than being dropped."
        }
    }

    private var canRun: Bool {
        guard let chosen, (chosen.pageCount ?? 0) > 0 else { return false }
        switch splitStyle {
        case .ranges, .groups:
            return !PageRanges.parse(selection, pageCount: pageCount).isEmpty
        case .every, .size:
            return true
        }
    }

    private func run() {
        outputs = []
        failure = nil
        guard let file = chosen else { return }
        do {
            switch splitStyle {
            case .ranges:
                outputs = [try PDFTools.extract(
                    from: file.url, selection: selection, baseName: file.name)]
            case .groups:
                outputs = try PDFTools.split(file.url, selection: selection, baseName: file.name)
            case .every:
                outputs = try PDFTools.splitEveryPage(file.url, baseName: file.name)
            case .size:
                outputs = try PDFTools.splitBySize(
                    file.url, targetBytes: targetMB * 1_000_000, baseName: file.name)
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Merge

struct MergePDFView: View {
    @Environment(\.theme) private var theme

    @State private var chosen: [PickedPDF] = []
    @State private var isPicking = false
    @State private var output: PDFTools.Output?
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                ForEach(chosen) { file in
                    HStack(spacing: Spacing.md) {
                        IconTile(systemImage: "doc.richtext", hue: .rose, size: .small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name).font(.brand(.subheadline, weight: .medium)).dynamicLineLimit(1)
                            Text(file.pageCount.map { "\($0) page\($0 == 1 ? "" : "s")" }
                                 ?? "could not be opened")
                                .font(.brand(.caption))
                                .foregroundStyle(file.pageCount == nil ? theme.danger : theme.textSecondary)
                        }
                        Spacer()
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            chosen.removeAll { $0.id == file.id }
                            output = nil
                        } label: {
                            Label("Remove", systemImage: "minus.circle")
                        }
                    }
                }
                .onMove { source, destination in
                    // Merge order is the registry's order, not alphabetical — an annexure bundle
                    // assembled in the wrong sequence is a bundle that gets returned.
                    chosen.move(fromOffsets: source, toOffset: destination)
                    output = nil
                }

                Button {
                    isPicking = true
                } label: {
                    Label(chosen.isEmpty ? "Choose PDFs" : "Add another", systemImage: "doc.badge.plus")
                }
            } header: {
                SectionHeader(
                    title: "Documents, in order",
                    detail: chosen.count > 1 ? "Drag to reorder" : nil)
            }
            .listRowBackground(theme.surface)

            Section {
                ToolRunButton(
                    title: chosen.count >= 2 ? "Merge \(chosen.count) documents" : "Merge",
                    runningTitle: "Merging…", isRunning: false, isEnabled: canRun, action: run)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                OnDeviceNote()
            }

            if let failure {
                Section {
                    ToolFailureRow(message: failure)
                }
                .listRowBackground(theme.surface)
            }

            if let output {
                Section {
                    ToolResultRow(file: ToolFile(name: output.name, data: output.data))
                } header: {
                    SectionHeader(title: "Result")
                }
                .listRowBackground(theme.surface)
            }
        }
        .font(.brand(.body))
        .scrollContentBackground(.hidden)
        .background(theme.canvas)
        .navigationTitle("Merge PDF")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { outcome in
            guard case .success(let urls) = outcome else { return }
            chosen += urls.map { PickedPDF(url: $0, pageCount: PDFTools.pageCount(of: $0)) }
            output = nil
            failure = nil
        }
    }

    private var canRun: Bool {
        chosen.count >= 2 && chosen.allSatisfy { $0.pageCount != nil }
    }

    private func run() {
        output = nil
        failure = nil
        do {
            output = try PDFTools.merge(chosen.map(\.url), name: "Merged")
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
