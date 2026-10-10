import SwiftUI
import PhotosUI
import UIKit

/// Settings → Edit profile: the web's profile card (`src/pages/Settings.jsx`) — photo, name,
/// title and organisation — with the email and mobile shown beside them, not edited.
///
/// Everything it decides is `ProfileEditor`'s, including the rule that matters most: every
/// field is sent on every save. Drawing the picked photo into the web's 256-pixel square is the
/// one thing done here, because it needs UIKit.
struct EditProfileView: View {
    @Environment(Session.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var model: ProfileEditor?
    @State private var photoItem: PhotosPickerItem?
    @State private var isReadingPhoto = false
    /// The field being typed in, so Return on a field that wraps can mean "done", as its key says.
    @FocusState private var focusedField: String?

    private typealias Copy = ProfileEditor.Copy

    var body: some View {
        Group {
            if let model {
                form(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.canvas)
        .navigationTitle(Copy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil, let user = session.currentUser else { return }
            let account = session
            model = ProfileEditor(user: user, service: account.profile) { saved in
                account.adoptProfile(saved)
            }
        }
    }

    private func form(_ model: ProfileEditor) -> some View {
        @Bindable var bindable = model
        return List {
            Section {
                photoRow(model)
            } footer: {
                if let error = model.photoError {
                    footnote(error, tone: theme.warning)
                } else {
                    footnote(Copy.photoFooter)
                }
            }
            .listRowBackground(theme.surface)

            Section {
                field("Full name", placeholder: Copy.namePlaceholder, text: $bindable.name,
                      id: "profile-name", contentType: .name)
                // These two wrap: a designation or a chambers' name can run long, and at a
                // large text size a one-line field scrolls the end of it out of sight.
                field("Title / designation", placeholder: Copy.titlePlaceholder,
                      text: $bindable.title, id: "profile-title", contentType: .jobTitle,
                      wraps: true)
                field("Organisation", placeholder: Copy.organizationPlaceholder,
                      text: $bindable.organization, id: "profile-organization",
                      contentType: .organizationName, wraps: true)
            } header: {
                SectionHeader(title: "Your details")
            } footer: {
                if let problem = model.nameProblem {
                    footnote(problem, tone: theme.warning)
                }
            }
            .listRowBackground(theme.surface)

            Section {
                LabeledContent("Email") {
                    Text(model.email ?? "—").foregroundStyle(theme.textSecondary)
                }
                if let phone = model.phone, !phone.isEmpty {
                    LabeledContent("Mobile") {
                        Text("+91 " + IndianMobile.local(phone)).foregroundStyle(theme.textSecondary)
                    }
                }
            } header: {
                SectionHeader(title: "Sign-in")
            } footer: {
                footnote(Copy.readOnlyFooter)
            }
            .listRowBackground(theme.surface)

            if let error = model.saveError {
                Section {
                    Label {
                        Text(error)
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(theme.warning)
                    }
                    .accessibilityIdentifier("profile-error")
                }
                .listRowBackground(theme.surface)
            }
        }
        .font(.brand(.body))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.groupedBackground)
        .accessibilityIdentifier("profile-form")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task {
                            if await model.save() { dismiss() }
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!model.canSave || isReadingPhoto)
                    .accessibilityIdentifier("profile-save")
                }
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await readPhoto(item, into: model) }
        }
        // A failed save, or a photo that could not be used, lands in the form below the control
        // VoiceOver was on — so it is said as well.
        .onChange(of: model.saveError) { _, error in
            if let error { VoiceOver.announce(error) }
        }
        .onChange(of: model.photoError) { _, error in
            if let error { VoiceOver.announce(error) }
        }
    }

    // MARK: - The photo

    private func photoRow(_ model: ProfileEditor) -> some View {
        HStack(spacing: Spacing.lg) {
            AccountAvatar(photo: model.photo, monogram: model.monogram, size: 72)
                .overlay {
                    if isReadingPhoto {
                        ProgressView()
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                // Borderless, so each answers only its own tap: a list row holding two plain
                // buttons fires both on one.
                // Each a line of text to the eye and a 44-point target to the thumb.
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text(model.hasPhoto ? "Change photo" : "Add a photo")
                        .font(.brand(.body, weight: .medium))
                        .foregroundStyle(theme.accentText)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("profile-photo-pick")
                if model.hasPhoto {
                    Button {
                        model.removePhoto()
                    } label: {
                        Text("Remove photo")
                            .font(.brand(.subheadline))
                            .foregroundStyle(theme.danger)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("profile-photo-remove")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
    }

    /// Reads the picked photo and draws it into the web's square, at the qualities
    /// `ProfilePhoto` tries in turn.
    private func readPhoto(_ item: PhotosPickerItem, into model: ProfileEditor) async {
        isReadingPhoto = true
        defer { isReadingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            model.photoCouldNotBeRead()
            return
        }
        model.setPhoto { quality in ProfilePhotoRenderer.jpeg(image, quality: quality) }
    }

    // MARK: - Pieces

    /// A labelled field: the label stays above the text, so a filled field still says what it
    /// is — a placeholder alone vanishes the moment there is something in it.
    private func field(
        _ label: String, placeholder: String, text: Binding<String>, id: String,
        contentType: UITextContentType, wraps: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label)
                .font(.brand(.caption, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .accessibilityHidden(true)
            // The example in the palette's tertiary: the system's placeholder grey is about 2.4:1
            // on a dark card.
            let prompt = Text(verbatim: placeholder).foregroundStyle(theme.textTertiary)
            Group {
                if wraps {
                    TextField(label, text: oneParagraph(text), prompt: prompt, axis: .vertical)
                        .lineLimit(1...4)
                } else {
                    TextField(label, text: text, prompt: prompt)
                }
            }
            .focused($focusedField, equals: id)
            .font(.brand(.body))
            .foregroundStyle(theme.textPrimary)
            .textContentType(contentType)
            .submitLabel(.done)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
        }
        .padding(.vertical, Spacing.xxs)
    }

    /// The text as one paragraph. Return in a field that wraps types a line break, which a title
    /// has no use for; here it is taken as "done", as the keyboard's key says, and the break is
    /// never kept.
    private func oneParagraph(_ text: Binding<String>) -> Binding<String> {
        Binding(
            get: { text.wrappedValue },
            set: { new in
                guard new.contains("\n") else {
                    text.wrappedValue = new
                    return
                }
                text.wrappedValue = new.replacingOccurrences(of: "\n", with: "")
                focusedField = nil
            })
    }

    private func footnote(_ text: String, tone: Color? = nil) -> some View {
        Text(text)
            .font(.brand(.caption))
            .foregroundStyle(tone ?? theme.textSecondary)
    }
}

/// Draws a picked photo the way the web does: centre-cropped into a 256-pixel square, as a JPEG.
enum ProfilePhotoRenderer {
    static func jpeg(_ image: UIImage, quality: Double) -> Data? {
        guard let rect = ProfilePhoto.drawRect(
            forImageWidth: Double(image.size.width), height: Double(image.size.height))
        else { return nil }
        let format = UIGraphicsImageRendererFormat()
        // Pixels, not points: the web's canvas is 256 pixels, and a 3× screen would otherwise
        // make it 768.
        format.scale = 1
        format.opaque = true
        let side = CGFloat(ProfilePhoto.side)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.jpegData(withCompressionQuality: CGFloat(quality)) { _ in
            image.draw(in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
        }
    }
}

/// The account's photo in a circle, or its initial on the accent colour when there is none — the
/// web's avatar.
struct AccountAvatar: View {
    @Environment(\.theme) private var theme

    let photo: ProfilePhoto.Source?
    let monogram: String
    var size: CGFloat = 44

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(theme.separator, lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch photo {
        case .embedded(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                initial
            }
        case .remote(let url):
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    initial
                }
            }
        case nil:
            initial
        }
    }

    private var initial: some View {
        Text(monogram)
            .font(.custom(BrandFont.name(for: .semibold), fixedSize: size * 0.42))
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.accent)
    }
}
