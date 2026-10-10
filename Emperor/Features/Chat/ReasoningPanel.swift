import SwiftUI

/// The reading card: what Emperor is doing while it prepares an answer, and what it did once the
/// answer is in.
///
/// While the answer is being prepared it is open, its newest step lit with a ping and a page
/// being scanned at its head: "Reading 2 documents…", then "Reading AWARD.pdf", "Searching your
/// documents". When the first words of the answer arrive it folds to one line — "Read 2
/// documents · searched your files" — **unless the reader has opened or closed it**, in which case
/// their choice stands. Every step is said in plain words (`StepLabels`): never a page range, a
/// tool's name or a query.
///
/// The plan and the model's reasoning, where a run carried them, are one more tap away inside the
/// card: when an answer looks wrong the first question is "what did it actually do?", and that has
/// to stay answerable.
struct ReasoningPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshot: ReasoningSnapshot
    let isStreaming: Bool
    let liveStatus: String?
    /// Whether any of the answer has arrived — the moment the card folds.
    var answerHasStarted = false

    /// The reader's own choice, once they have made one. It outranks the automatic fold.
    @State private var readerChoice: Bool?
    @State private var showsWorking = false

    private var isOpen: Bool { readerChoice ?? (isStreaming && !answerHasStarted) }

    var body: some View {
        let steps = StepLabels.steps(snapshot)
        if steps.isEmpty && snapshot.isEmpty && liveStatus == nil && !isStreaming {
            EmptyView()
        } else {
            let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            VStack(alignment: .leading, spacing: 0) {
                header(steps)
                if isOpen {
                    detail(steps)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(isStreaming ? theme.accentLine : theme.separator, lineWidth: 1))
            .animation(
                Motion.adaptive(Motion.easeOut(Motion.Duration.readingCardFold), reduceMotion: reduceMotion),
                value: isOpen)
            .animation(
                Motion.adaptive(Motion.easeOut(0.3), reduceMotion: reduceMotion), value: steps.count)
            // Each new step is said as it starts — not every chunk of the stream, only a step.
            .onChange(of: steps.count) { _, _ in
                if isStreaming, let newest = steps.last { VoiceOver.announce(newest.text) }
            }
        }
    }

    // MARK: - Header

    private func header(_ steps: [StepLabels.Step]) -> some View {
        Button {
            readerChoice = !isOpen
        } label: {
            HStack(spacing: 10) {
                PagesGlyph(isScanning: isStreaming && !reduceMotion)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.brand(size: 14, weight: .semibold, relativeTo: .subheadline))
                        .foregroundStyle(theme.textSecondary)
                        .dynamicLineLimit(2)
                    if let live = liveLine(steps) {
                        Text(live)
                            .font(.brand(size: 12.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows what was read")
    }

    private var title: String {
        isStreaming ? StepLabels.runningTitle(snapshot) : StepLabels.summary(snapshot)
    }

    /// The step under way, under the title, while the answer is being prepared.
    private func liveLine(_ steps: [StepLabels.Step]) -> String? {
        guard isStreaming else { return nil }
        if let current = steps.last { return current.text + "…" }
        if let liveStatus, !liveStatus.isEmpty { return StepLabels.friendly(liveStatus) + "…" }
        return "Starting…"
    }

    // MARK: - Detail

    private func detail(_ steps: [StepLabels.Step]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    StepLine(
                        text: step.text,
                        isLive: isStreaming && index == steps.count - 1,
                        isDone: !(isStreaming && index == steps.count - 1),
                        reduceMotion: reduceMotion)
                        .transition(Motion.rise(reduceMotion: reduceMotion))
                }
            }
            // The thread the dots hang on.
            .background(alignment: .leading) {
                Rectangle()
                    .fill(theme.borderStrong)
                    .frame(width: 1)
                    .padding(.vertical, 12)
                    .padding(.leading, 4.5)
                    .opacity(steps.count > 1 ? 1 : 0)
            }

            if !snapshot.plan.isEmpty || !snapshot.reasoning.isEmpty {
                Button {
                    showsWorking.toggle()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text(showsWorking ? "Hide the working" : "Show the working")
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showsWorking ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .frame(minHeight: Layout.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsWorking {
                    working
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, Spacing.md)
        .padding(.bottom, Spacing.md)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if !snapshot.plan.isEmpty {
                section("Plan") {
                    ForEach(snapshot.plan) { task in
                        planRow(task, isSubtask: false)
                        ForEach(task.subtasks) { subtask in
                            planRow(subtask, isSubtask: true)
                        }
                    }
                }
            }
            if !snapshot.reasoning.isEmpty {
                section("Reasoning") {
                    ForEach(Array(snapshot.reasoning.enumerated()), id: \.offset) { _, sentence in
                        Text(sentence)
                            .font(.brand(.caption))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .recordText(RecordTokens.Typography.label)
                .foregroundStyle(theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planRow(_ row: PlanRow, isSubtask: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: row.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.brand(.caption2))
                .foregroundStyle(row.status == .completed ? theme.accentText : theme.textTertiary)
                .accessibilityLabel(row.status == .completed ? "Done" : "Not done")
            Text(row.title)
                // Spelled out on both sides: `font(_:)` takes an `Optional`.
                .font(isSubtask ? Font.brand(.caption) : Font.brand(.caption, weight: .medium))
                .foregroundStyle(row.status == .pending ? theme.textTertiary : theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, isSubtask ? 16 : 0)
    }
}

/// One step on the card's thread: a dot, filled once done, ringed and pinging while it runs.
private struct StepLine: View {
    @Environment(\.theme) private var theme

    let text: String
    let isLive: Bool
    let isDone: Bool
    let reduceMotion: Bool

    @State private var pinging = false

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(isDone ? theme.accent : theme.surface)
                Circle()
                    .strokeBorder(isDone || isLive ? theme.accentText : theme.borderStrong, lineWidth: 1.5)
                if isLive && !reduceMotion {
                    Circle()
                        .strokeBorder(theme.accentText, lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                        .scaleEffect(pinging ? 1.3 : 0.5)
                        .opacity(pinging ? 0 : 0.8)
                        .onAppear {
                            withAnimation(Motion.easeOut(1.3).repeatForever(autoreverses: false)) {
                                pinging = true
                            }
                        }
                }
            }
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)

            Text(text)
                .font(.brand(size: 13.5, weight: isLive ? .medium : .regular, relativeTo: .footnote))
                .foregroundStyle(isLive ? theme.textPrimary : theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 30, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isLive ? "In progress" : "Done")
    }
}

/// Three pages fanned at the head of the card; while reading, a highlight runs down the top one.
private struct PagesGlyph: View {
    @Environment(\.theme) private var theme
    let isScanning: Bool

    @State private var scanned = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            page.rotationEffect(.degrees(-8)).offset(x: 2, y: 3)
            page.rotationEffect(.degrees(3)).offset(x: 6, y: 3)
            page
                .overlay(alignment: .top) {
                    VStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Rectangle().fill(theme.borderStrong).frame(height: 1.5)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.top, 5)
                }
                .overlay(alignment: .top) {
                    if isScanning {
                        Rectangle()
                            .fill(theme.mark)
                            .frame(height: 3)
                            .offset(y: scanned ? 16 : 2)
                            .onAppear {
                                withAnimation(Motion.easeInOut(0.7).repeatForever(autoreverses: true)) {
                                    scanned = true
                                }
                            }
                    }
                }
                .clipped()
                .offset(x: 10, y: 4)
        }
        .frame(width: 30, height: 30, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var page: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(theme.borderStrong, lineWidth: 1))
            .frame(width: 18, height: 23)
    }
}
