import SwiftUI
import UniformTypeIdentifiers

/// Split and merge, on the device.
///
/// The platform has these at `/tools/split-pdf` and `/tools/merge-pdf`, and they are client-side
/// there too — no route is involved on either product. That matters more here than it looks:
/// these documents are privileged, and uploading a client's brief to cut three pages out of it
/// would be the wrong trade regardless of convenience.
///
/// Every output is shared rather than saved: the app has no file browser of its own, and the
/// share sheet already reaches Files, Mail and every other place a bundle part needs to go.
struct PDFToolsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .split
    @State private var chosen: [PickedPDF] = []
    @State private var selection = ""
    @State private var splitStyle: SplitStyle = .ranges
    @State private var targetMB = 10
    @State private var isPicking = false
    @State private var outputs: [PDFTools.Output] = []
    @State private var failure: String?

    private enum Mode: String, CaseIterable, Identifiable {
        case split = "Split", merge = "Merge"
        var id: String { rawValue }
    }

    /// The four ways Android offers, kept the same so someone who uses both is not relearning.
    private enum SplitStyle: String, CaseIterable, Identifiable {
        case ranges = "Extract pages"
        case groups = "Split into parts"
        case every = "Every page"
        case size = "By size"
        var id: String { rawValue }
    }

    /// A chosen file and what is known about it. `pageCount` is `nil` while unreadable.
    private struct PickedPDF: Identifiable {
        let url: URL
        let pageCount: Int?
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private var firstCount: Int { chosen.first?.pageCount ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                filesSection

                if mode == .split, !chosen.isEmpty {
                    splitOptions
                }

                if !outputs.isEmpty {
                    resultsSection
                }

                Section {
                    Button(action: run) {
                        Text(actionLabel)
                            .font(.brand(.headline))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    // Said out loud, because "on this phone" is the reason to use it rather than
                    // the web, and nothing else on screen would tell you.
                    Text("Everything happens on this phone. No document is uploaded.")
                        .font(.brand(.caption2))
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas)
            .navigationTitle("File tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $isPicking,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: mode == .merge
            ) { outcome in
                guard case .success(let urls) = outcome else { return }
                let picked = urls.map { PickedPDF(url: $0, pageCount: PDFTools.pageCount(of: $0)) }
                chosen = mode == .merge ? chosen + picked : Array(picked.prefix(1))
                outputs = []
            }
            .alert("Could not do that", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var filesSection: some View {
        Section {
            ForEach(chosen) { file in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.brand(.subheadline)).lineLimit(1)
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
                        outputs = []
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
            .onMove { source, destination in
                // Merge order is the registry's order, not alphabetical — an annexure bundle
                // assembled in the wrong sequence is a bundle that gets returned.
                chosen.move(fromOffsets: source, toOffset: destination)
                outputs = []
            }

            Button {
                isPicking = true
            } label: {
                Label(chosen.isEmpty ? "Choose a PDF" : "Add another", systemImage: "doc.badge.plus")
            }
        } header: {
            SectionHeader(
                title: mode == .merge ? "Documents, in order" : "Document",
                detail: mode == .merge && chosen.count > 1 ? "Drag to reorder" : nil)
        }
    }

    @ViewBuilder
    private var splitOptions: some View {
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
            // A live description of what the current selection would actually produce, because
            // "1-3, 2" is three pages and reads like four.
            Text(splitFooter)
                .font(.brand(.caption2))
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(outputs) { output in
                if let url = ShareableFile.url(for: output.data, named: output.name) {
                    ShareLink(item: url) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(output.name).font(.brand(.subheadline)).lineLimit(1)
                                Text(byteCount(output.data.count))
                                    .font(.brand(.caption))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        } header: {
            SectionHeader(
                title: "Result",
                detail: outputs.count > 1 ? "\(outputs.count) files" : nil)
        }
    }

    // MARK: - Wording

    private var actionLabel: String {
        switch mode {
        case .merge:
            return chosen.count >= 2 ? "Merge \(chosen.count) documents" : "Merge"
        case .split:
            switch splitStyle {
            case .ranges: return "Extract \(PageRanges.describe(selection, pageCount: firstCount))"
            case .groups: return "Split into parts"
            case .every: return firstCount > 0 ? "Split into \(firstCount) files" : "Split"
            case .size: return "Split at about \(targetMB) MB"
            }
        }
    }

    private var splitFooter: String {
        switch splitStyle {
        case .ranges:
            return "\(PageRanges.describe(selection, pageCount: firstCount)) into one document."
        case .groups:
            let count = PageRanges.parseGroups(selection, pageCount: firstCount).count
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
        guard chosen.allSatisfy({ $0.pageCount != nil }) else { return false }
        switch mode {
        case .merge: return chosen.count >= 2
        case .split:
            guard let first = chosen.first, (first.pageCount ?? 0) > 0 else { return false }
            switch splitStyle {
            case .ranges, .groups:
                return !PageRanges.parse(selection, pageCount: firstCount).isEmpty
            case .every, .size:
                return true
            }
        }
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Running

    private func run() {
        outputs = []
        do {
            switch mode {
            case .merge:
                outputs = [try PDFTools.merge(chosen.map(\.url), name: "Merged")]
            case .split:
                guard let file = chosen.first else { return }
                switch splitStyle {
                case .ranges:
                    outputs = [try PDFTools.extract(
                        from: file.url, selection: selection, baseName: file.name)]
                case .groups:
                    outputs = try PDFTools.split(
                        file.url, selection: selection, baseName: file.name)
                case .every:
                    outputs = try PDFTools.splitEveryPage(file.url, baseName: file.name)
                case .size:
                    outputs = try PDFTools.splitBySize(
                        file.url, targetBytes: targetMB * 1_000_000, baseName: file.name)
                }
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
