import PhotosUI
import SwiftUI
import UIKit

/// A matter's banner at the head of its Overview: the uploaded picture when there is one and it
/// has loaded, otherwise the preset gradient (`BannerPreset.preset(for:)`) — which is also drawn
/// under the picture while it loads. The name sits on a dark plate of its own, so it reads on all
/// eight gradients and over any photo.
///
/// "Edit banner" chooses a photo — shrunk here to at most 1,600 pixels wide, as a JPEG under
/// 2 MB, because that needs UIKit — or removes the one there is. Uploading, the size check and
/// the reload are `ProjectDetailViewModel`'s.
struct MatterBannerView: View {
    let model: ProjectDetailViewModel

    @State private var isPicking = false
    @State private var picked: PhotosPickerItem?
    @State private var isPreparing = false

    @ScaledMetric(relativeTo: .title) private var height: CGFloat = 112

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            gradient
            if let data = model.bannerImage, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
            }
            plate
                .padding(Spacing.md)
        }
        .frame(height: min(height, 180))
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .topTrailing) { editMenu.padding(Spacing.sm) }
        .photosPicker(isPresented: $isPicking, selection: $picked, matching: .images)
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            Task { await upload(item) }
        }
        .task(id: model.project?.updatedAtRaw) { await model.loadBanner() }
    }

    private var gradient: some View {
        let colors = model.bannerPreset.hexColors
        return LinearGradient(
            colors: [Self.color(colors.from), Self.color(colors.to)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .accessibilityHidden(true)
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title)
                .font(.brand(.headline, weight: .semibold))
                .dynamicLineLimit(2)
            if let line = [model.project?.client, model.project?.caseReference]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }).first {
                Text(line)
                    .font(.brand(.caption))
                    .dynamicLineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        // The web's plate: near-black glass, which carries its own contrast over any picture.
        .background(Color(red: 12 / 255, green: 14 / 255, blue: 28 / 255).opacity(0.62),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var editMenu: some View {
        Menu {
            Button {
                isPicking = true
            } label: {
                Label(model.project?.hasBannerImage == true ? "Choose another photo" : "Choose a photo",
                      systemImage: "photo")
            }
            if model.project?.hasBannerImage == true {
                Button(role: .destructive) {
                    Task { await model.removeBanner() }
                } label: {
                    Label("Remove photo", systemImage: "trash")
                }
            }
        } label: {
            Group {
                if isPreparing || model.isChangingBanner {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color(red: 12 / 255, green: 14 / 255, blue: 28 / 255).opacity(0.62),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Edit banner")
        .disabled(isPreparing || model.isChangingBanner)
    }

    private func upload(_ item: PhotosPickerItem) async {
        isPreparing = true
        let jpeg = await Self.prepare(item)
        isPreparing = false
        guard let jpeg else {
            model.writeError = "That photo could not be read."
            return
        }
        await model.uploadBanner(data: jpeg, mime: "image/jpeg")
    }

    /// The photo as a JPEG at most 1,600 pixels wide, at the first quality that fits in 2 MB.
    /// If none does, the smallest is returned and the core refuses it with the size.
    private static func prepare(_ item: PhotosPickerItem) async -> Data? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let size = BannerImage.targetSize(width: Double(image.size.width), height: Double(image.size.height))
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format)
        var smallest: Data?
        for quality in BannerImage.jpegQualities {
            let jpeg = renderer.jpegData(withCompressionQuality: CGFloat(quality)) { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
            if jpeg.count <= BannerImage.maxBytes { return jpeg }
            smallest = jpeg
        }
        return smallest
    }

    private static func color(_ hex: String) -> Color {
        guard let c = BannerPreset.components(hex) else { return .gray }
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}
