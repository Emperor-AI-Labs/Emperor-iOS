import SwiftUI

// The Record kit (section 02 of the design's prototype), drawn with the tokens and nothing else.
// Buttons, badges, tiles, meters and empty states live in `Theme.swift`, where every screen
// already reached for them; this file holds the pieces the Record screens added: the mark, the
// grouped list, rows, the item number, the citation chip, the segmented control, the search
// field, the composer, the reading card, sheet heads and toasts.

// MARK: - The mark

/// The two-stroke Record mark, read from its SVG path data (`RecordMark`) and scaled to fit.
struct RecordMarkShape: Shape {
    /// Read once: the strings are constant, and a path is asked for on every layout pass.
    private static let strokes: [[PathCommand]] = RecordMark.strokes.compactMap { SVGPathReader.read($0) }

    func path(in rect: CGRect) -> Path {
        let box = RecordMark.viewBox
        let scale = min(rect.width / CGFloat(box.width), rect.height / CGFloat(box.height))
        let dx = rect.minX + (rect.width - CGFloat(box.width) * scale) / 2 - CGFloat(box.x) * scale
        let dy = rect.minY + (rect.height - CGFloat(box.height) * scale) / 2 - CGFloat(box.y) * scale
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: CGFloat(x) * scale + dx, y: CGFloat(y) * scale + dy)
        }

        var path = Path()
        for stroke in Self.strokes {
            for command in stroke {
                switch command {
                case .move(let x, let y):
                    path.move(to: point(x, y))
                case .line(let x, let y):
                    path.addLine(to: point(x, y))
                case .quad(let x, let y, let cx, let cy):
                    path.addQuadCurve(to: point(x, y), control: point(cx, cy))
                case .cubic(let x, let y, let c1x, let c1y, let c2x, let c2y):
                    path.addCurve(to: point(x, y), control1: point(c1x, c1y), control2: point(c2x, c2y))
                case .close:
                    path.closeSubpath()
                }
            }
        }
        return path
    }
}

/// The mark, filled with the logo gradient, at a height.
struct RecordMarkView: View {
    @Environment(\.theme) private var theme
    var height: CGFloat = 22

    var body: some View {
        RecordMarkShape()
            .fill(theme.logoGradient)
            .frame(
                width: height * CGFloat(RecordMark.viewBox.width / RecordMark.viewBox.height),
                height: height)
            .accessibilityHidden(true)
    }
}

// MARK: - Headings

/// A section heading with an optional action at its trailing edge — "Next sitting · Mon 12 Oct"
/// with "See all".
struct RecordSectionLabel: View {
    @Environment(\.theme) private var theme

    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .recordText(RecordTokens.Typography.label)
                .foregroundStyle(theme.textTertiary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.brand(.footnote, weight: .semibold))
                    .foregroundStyle(theme.accentText)
                    .frame(minHeight: Layout.touchTarget)
                    .contentShape(Rectangle())
            }
        }
        .padding(.top, Spacing.xxl)
        .padding(.bottom, Spacing.xs)
    }
}

/// The eyebrow, serif title and subtitle at the head of a screen's content — Home's date and
/// greeting, Matters' "3 listed on Monday", a sheet's file name.
struct SerifHeader: View {
    @Environment(\.theme) private var theme

    var eyebrow: String?
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let eyebrow {
                Text(eyebrow)
                    .recordText(RecordTokens.Typography.label)
                    .foregroundStyle(theme.textTertiary)
            }
            Text(title)
                .recordText(RecordTokens.Typography.largeTitle)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.brand(.subheadline))
                    .foregroundStyle(theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grouped lists

/// A group of rows: the card's surface, a hairline, a radius of 10. Rows separate themselves with
/// `RecordDivider`.
struct RecordGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.separator, lineWidth: 1))
    }
}

/// The hairline between two rows of a group, inset to where the row's words begin.
struct RecordDivider: View {
    @Environment(\.theme) private var theme
    /// 56 under a row with a tile; 14 under a row of words alone.
    var inset: CGFloat = 56

    var body: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(height: 1)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A row: something at the leading edge, a title and a line under it, something at the end.
struct RecordRow<Leading: View, Trailing: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    var subtitle: String?
    var subtitleColor: Color?
    var titleLines = 1
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Spacing.md) {
            leading()
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.brand(.body, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(titleLines)
                if let subtitle {
                    Text(subtitle)
                        .font(.brand(.footnote))
                        .foregroundStyle(subtitleColor ?? theme.textTertiary)
                        .dynamicLineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: Layout.listRow)
        .contentShape(Rectangle())
    }
}

extension RecordRow where Trailing == RowChevron {
    /// A row that leads somewhere: a chevron at its end.
    init(
        title: String, subtitle: String? = nil, titleLines: Int = 1,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.init(
            title: title, subtitle: subtitle, subtitleColor: nil, titleLines: titleLines,
            leading: leading, trailing: { RowChevron() })
    }
}

/// A row under the thumb: the hover wash while pressed, nothing else.
struct RecordRowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? theme.hover : Color.clear)
    }
}

extension ButtonStyle where Self == RecordRowButtonStyle {
    static var recordRow: RecordRowButtonStyle { RecordRowButtonStyle() }
}

// MARK: - Item numbers and citations

/// The item number at the head of a hearing row: the serif numeral people scan a cause list for,
/// in a recessed box, "ITEM" above it.
struct ItemNumberBadge: View {
    @Environment(\.theme) private var theme
    let item: String?

    @ScaledMetric(relativeTo: .title2) private var width: CGFloat = 52

    var body: some View {
        VStack(spacing: 3) {
            Text("Item")
                .font(.brand(size: 9.5, weight: .bold, relativeTo: .caption2))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.textTertiary)
            if let item {
                Text(item)
                    .font(.display(size: 24, relativeTo: .title2))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Image(systemName: "scalemass")
                    .font(.brand(.title3))
                    .foregroundStyle(theme.accentText)
            }
        }
        .padding(.vertical, Spacing.sm)
        .frame(width: min(width, 84))
        .frame(maxHeight: .infinity)
        .background(theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.map { "Item \($0)" } ?? "No item number")
    }
}

/// A citation number as a chip: drawn 20 by 18, answering a touch across 44. Tapped, it fills with
/// the accent for half a second — then the cited page rises.
struct CitationChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let number: Int
    /// "Citation 2, AWARD.pdf, page 3".
    let accessibilityText: String
    let action: () -> Void

    @State private var isLit = false

    var body: some View {
        Button {
            Haptics.selection()
            withAnimation(Motion.easeOut(Motion.Duration.fade)) { isLit = true }
            let delay = reduceMotion ? 0 : 180
            let open = action
            let lit = $isLit
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                open()
                try? await Task.sleep(for: .milliseconds(320))
                withAnimation(Motion.easeOut(Motion.Duration.fade)) { lit.wrappedValue = false }
            }
        } label: {
            Text(verbatim: "\(number)")
                .recordText(RecordTokens.Typography.citation)
                .monospacedDigit()
                .foregroundStyle(isLit ? theme.onAccent : theme.accentText)
                .padding(.horizontal, 5)
                .frame(minWidth: 20, minHeight: 18)
                .background(
                    isLit ? theme.accent : theme.accentWash,
                    in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }
}

/// "p. 3" at the end of a source — the way to the page.
struct PageChip: View {
    @Environment(\.theme) private var theme
    let text: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "book")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text)
                .monospacedDigit()
        }
        .font(.brand(size: 12.5, weight: .semibold, relativeTo: .caption))
        .foregroundStyle(theme.accentText)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(theme.accentWash, in: Capsule())
    }
}

// MARK: - Segmented control and search

/// Record's segmented control: a tinted track, the chosen segment raised on the elevated surface.
///
/// Drawn rather than `Picker(.segmented)`, whose segment text cannot take the brand face's
/// weight per state and whose radius is the platform's. Each segment is a button marked selected
/// for VoiceOver; the whole is one group.
struct RecordSegmentedControl<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var space

    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                segment(options[index].value, title: options[index].title)
            }
        }
        .padding(2)
        .background(
            theme.textTertiary.opacity(0.13),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ value: Value, title: String) -> some View {
        let isSelected = value == selection
        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            withAnimation(Motion.adaptive(Motion.easeOut(Motion.Duration.fade), reduceMotion: reduceMotion)) {
                selection = value
            }
        } label: {
            Text(title)
                .font(.brand(size: 13.5, weight: .semibold, relativeTo: .footnote))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.elevated)
                            .shadow(color: Color.black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                            .matchedGeometryEffect(id: "segment", in: space)
                    }
                }
                .frame(minHeight: Layout.touchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -7)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The search field iOS draws, in Record's colours: names and contents.
struct RecordSearchField: View {
    @Environment(\.theme) private var theme

    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(theme.textTertiary))
                .font(.brand(.body))
                .foregroundStyle(theme.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textTertiary)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -Spacing.sm)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 37)
        .background(
            theme.textTertiary.opacity(0.12),
            in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
    }
}

// MARK: - The composer

/// "Fast" or "Deep thinking", at the foot of the composer. Opens the answer-mode choice.
struct ModeChip: View {
    @Environment(\.theme) private var theme
    let model: ChatModel
    let action: () -> Void

    var body: some View {
        let isDeep = model == .thinking
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: isDeep ? "brain" : "bolt.fill")
                    .imageScale(.small)
                Text(model.modeName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(.brand(.footnote, weight: .semibold))
            .foregroundStyle(isDeep ? theme.accentText : theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(isDeep ? theme.accentSoft : theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(isDeep ? theme.accentLine : theme.separator, lineWidth: 1))
            .frame(minHeight: Layout.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -6)
        .accessibilityLabel("Answer mode, \(model.modeName)")
        .accessibilityHint("Changes how the next answer is prepared")
    }
}

/// The answer mode, chosen from a sheet: each mode with what it is for.
struct AnswerModeSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let selection: ChatModel
    let onSelect: (ChatModel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordSheetHeader(title: "Answer mode", onClose: { dismiss() })
            VStack(spacing: 0) {
                ForEach(Array(ChatModel.allCases.enumerated()), id: \.element) { index, mode in
                    if index > 0 { RecordDivider(inset: 0) }
                    Button {
                        Haptics.selection()
                        onSelect(mode)
                        dismiss()
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            RadioMark(isOn: mode == selection)
                            IconTile(systemImage: mode == .thinking ? "brain" : "bolt.fill")
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(mode.modeName)
                                    .font(.brand(.body, weight: .medium))
                                    .foregroundStyle(theme.textPrimary)
                                Text(mode.modeDescription)
                                    .font(.brand(.footnote))
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, Spacing.md)
                        .padding(.horizontal, Spacing.xs)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.recordRow)
                    .accessibilityAddTraits(mode == selection ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.lg)
            Spacer(minLength: 0)
        }
        .background(theme.elevated.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(Radius.sheet)
    }
}

/// A radio button's mark: a ring, filled at its centre when chosen.
struct RadioMark: View {
    @Environment(\.theme) private var theme
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? theme.accentText : theme.textTertiary, lineWidth: 2)
            .frame(width: 22, height: 22)
            .overlay {
                if isOn {
                    Circle().fill(theme.accentText).frame(width: 10, height: 10)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Send, or — while an answer is being written — a dark square Stop. The swap pops in.
struct SendStopButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isStreaming: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        Group {
            if isStreaming {
                Button {
                    Haptics.stopped()
                    onStop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.onInverse)
                        .frame(width: 40, height: 40)
                        .background(theme.inverse, in: shape)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Stop this answer")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button {
                    Haptics.send()
                    onSend()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 40, height: 40)
                        .background(theme.primaryGradient, in: shape)
                        .opacity(canSend ? 1 : 0.35)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .buttonStyle(.plain)
        .padding(-2)
        .animation(
            Motion.adaptive(Motion.easePop(0.32), reduceMotion: reduceMotion), value: isStreaming)
    }
}

/// A file going with a question: its name in a small recessed chip, with a way to take it off.
struct AttachmentChip: View {
    @Environment(\.theme) private var theme
    let name: String
    var isFolder = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isFolder ? "folder" : "doc.text")
                .imageScale(.small)
                .foregroundStyle(theme.accentText)
                .accessibilityHidden(true)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -10)
                .padding(.horizontal, -10)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .font(.brand(.footnote, weight: .medium))
        .foregroundStyle(theme.textSecondary)
        .padding(.leading, Spacing.sm)
        .padding(.trailing, onRemove == nil ? Spacing.sm : Spacing.xs)
        .frame(minHeight: 30)
        .background(theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(theme.separator, lineWidth: 1))
    }
}

/// The composer: the files going with the question, the field, and a row of attach, the answer
/// mode, anything the screen adds, and Send ↔ Stop.
///
/// The field grows to six lines, then scrolls. Return sends from a hardware keyboard; Shift-Return
/// adds a line. Nothing here clears the text: the screen does, once the question has really gone —
/// so a question refused, offline or busy stays where it was written.
struct RecordComposer<Accessories: View>: View {
    @Environment(\.theme) private var theme

    @Binding var text: String
    let placeholder: String
    var attachments: [String] = []
    var onRemoveAttachment: ((Int) -> Void)?
    let model: ChatModel
    let onChooseMode: () -> Void
    var isStreaming = false
    var canSend = true
    var isDisabled = false
    let onAttach: () -> Void
    let onSend: () -> Void
    var onStop: () -> Void = {}
    var focus: FocusState<Bool>.Binding
    @ViewBuilder var accessories: () -> Accessories

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, name in
                            AttachmentChip(name: name, onRemove: removal(at: index))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                }
            }

            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(theme.textTertiary), axis: .vertical)
                .lineLimit(1...Layout.composerMaxLines)
                .textFieldStyle(.plain)
                .font(.brand(.body))
                .foregroundStyle(theme.textPrimary)
                .focused(focus)
                .disabled(isDisabled)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .onKeyPress(keys: [.return]) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    guard canSend, !isStreaming else { return .handled }
                    Haptics.send()
                    onSend()
                    return .handled
                }

            HStack(spacing: Spacing.xs) {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.textFaint)
                        .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach documents")
                .disabled(isStreaming)

                ModeChip(model: model, action: onChooseMode)
                    .disabled(isStreaming)

                accessories()

                Spacer(minLength: 0)

                SendStopButton(
                    isStreaming: isStreaming, canSend: canSend, onSend: onSend, onStop: onStop)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(theme.surface, in: shape)
        .overlay(
            shape.strokeBorder(focus.wrappedValue ? theme.accentLine : theme.borderStrong, lineWidth: 1))
        .shadow(color: theme.cardShadow, radius: 2, x: 0, y: 1)
        .animation(Motion.easeOut(Motion.Duration.fade), value: focus.wrappedValue)
    }
}

extension RecordComposer {
    /// Taking the file at `index` off the question, where the screen allows it.
    fileprivate func removal(at index: Int) -> (() -> Void)? {
        guard let onRemoveAttachment else { return nil }
        return { onRemoveAttachment(index) }
    }
}

extension RecordComposer where Accessories == EmptyView {
    init(
        text: Binding<String>, placeholder: String, attachments: [String] = [],
        onRemoveAttachment: ((Int) -> Void)? = nil, model: ChatModel,
        onChooseMode: @escaping () -> Void, isStreaming: Bool = false, canSend: Bool = true,
        isDisabled: Bool = false, onAttach: @escaping () -> Void, onSend: @escaping () -> Void,
        onStop: @escaping () -> Void = {}, focus: FocusState<Bool>.Binding
    ) {
        self.init(
            text: text, placeholder: placeholder, attachments: attachments,
            onRemoveAttachment: onRemoveAttachment, model: model, onChooseMode: onChooseMode,
            isStreaming: isStreaming, canSend: canSend, isDisabled: isDisabled,
            onAttach: onAttach, onSend: onSend, onStop: onStop, focus: focus,
            accessories: { EmptyView() })
    }
}

// MARK: - Sheets

/// A sheet's head: its title (and a line under it), and a round × to close it. The grab handle is
/// the system's (`presentationDragIndicator`).
struct RecordSheetHeader: View {
    @Environment(\.theme) private var theme

    let title: String
    var subtitle: String?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.brand(.headline))
                    .foregroundStyle(theme.textPrimary)
                    .dynamicLineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.brand(size: 12.5, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(theme.textTertiary)
                        .dynamicLineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.textFaint)
                    .frame(width: 32, height: 32)
                    .background(theme.surface2, in: Circle())
                    .frame(minWidth: Layout.touchTarget, minHeight: Layout.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.leading, Spacing.xl)
        .padding(.trailing, Spacing.md)
        .padding(.top, Spacing.xxl)
        .padding(.bottom, Spacing.sm)
    }
}

// MARK: - Toasts

/// A short confirmation from the top of the screen — "Copied with its sources" — popping in,
/// staying 2.6 seconds, and leaving. Said to VoiceOver as it appears.
private struct RecordToast: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.success)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(.brand(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, Spacing.md)
                    .padding(.trailing, Spacing.lg)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .background(theme.chrome, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.borderStrong, lineWidth: 0.5))
                    .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 8)
                    .padding(.top, Spacing.sm)
                    .padding(.horizontal, Spacing.gutter)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear { VoiceOver.announce(message) }
                    .task(id: message) {
                        try? await Task.sleep(for: .milliseconds(2600))
                        withAnimation(Motion.easeOut(Motion.Duration.fade)) { self.message = nil }
                    }
                }
            }
            .animation(
                Motion.adaptive(Motion.easePop(0.35), reduceMotion: reduceMotion), value: message)
    }
}

extension View {
    /// Shows `message` as a toast while it is set, and clears it after 2.6 seconds.
    func recordToast(_ message: Binding<String?>) -> some View {
        modifier(RecordToast(message: message))
    }
}

// MARK: - Offline

/// "You're offline" above a screen whose questions are kept until the connection is back.
struct OfflineStrip: View {
    @Environment(\.theme) private var theme
    var message = "You're offline. What you ask now is kept until you're back."

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Image(systemName: "wifi.slash")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.brand(.footnote, weight: .medium))
        .foregroundStyle(theme.warning)
        .padding(Spacing.md)
        .background(theme.warnBg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
