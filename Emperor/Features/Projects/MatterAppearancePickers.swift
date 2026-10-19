import SwiftUI

/// The banner preset and folder colour pickers, shared by New matter and Edit details so both
/// offer the same choices in the same order — the web's `BannerPresetPicker` and `ColourSwatches`.
/// Each swatch carries its name as its accessible label: a colour alone is information a
/// colour-blind reader cannot use.
struct BannerPresetPicker: View {
    @Environment(\.theme) private var theme
    @Binding var selection: BannerPreset

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(MatterListing.bannerOrder) { preset in
                    Button {
                        selection = preset
                    } label: {
                        BannerGradient(preset: preset)
                            .frame(width: 44, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay {
                                if selection == preset {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .shadow(radius: 1)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(selection == preset ? theme.accent : theme.border,
                                                  lineWidth: selection == preset ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.rawValue.capitalized) banner")
                    .accessibilityAddTraits(selection == preset ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// A preset's diagonal gradient.
struct BannerGradient: View {
    let preset: BannerPreset

    var body: some View {
        let colors = preset.hexColors
        LinearGradient(
            colors: [Color(hexString: colors.from), Color(hexString: colors.to)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .accessibilityHidden(true)
    }
}

/// The eight folder colours and None.
struct FolderColourPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    swatch(nil, label: "No colour")
                    ForEach(MatterFolderColor.options, id: \.key) { option in
                        swatch(option.key, label: option.label)
                    }
                }
                .padding(.vertical, 2)
            }
            Text(MatterFolderColor.label(selection))
                .font(.brand(.caption))
                .foregroundStyle(theme.textSecondary)
        }
    }

    private func swatch(_ key: String?, label: String) -> some View {
        let isOn = MatterFolderColor.normalized(selection) == key
        let ink = key.flatMap { MatterFolderColor.ink($0, dark: scheme == .dark) }.map(Color.init(hexString:))
        return Button {
            selection = key
        } label: {
            ZStack {
                Circle().fill(theme.surface2)
                if let ink {
                    Circle().fill(ink).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "nosign")
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(width: 30, height: 30)
            .overlay(Circle().strokeBorder(isOn ? (ink ?? theme.textSecondary) : theme.border, lineWidth: isOn ? 2.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension Color {
    /// `#RRGGBB`, grey if it does not parse.
    init(hexString: String) {
        guard let c = BannerPreset.components(hexString) else {
            self = .gray
            return
        }
        self = Color(red: c.red, green: c.green, blue: c.blue)
    }
}
