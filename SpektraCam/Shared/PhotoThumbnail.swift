import SwiftUI

/// One standard circular action size for toolbars, photo actions and Compare.
private struct PhotoActionLabelStyle: LabelStyle {
    var side: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon.frame(width: side, height: side)
    }
}
private struct PhotoActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.labelStyle(PhotoActionLabelStyle())
            .font(.system(size: 17, weight: .medium))
            .controlSize(.regular).buttonStyle(.glass).buttonBorderShape(.circle)
            .frame(width: 44, height: 44)
    }
}
extension View {
    func photoActionStyle() -> some View { modifier(PhotoActionStyle()) }
}

/// Reuse the root camera presentation from the library, photo and editor.
struct CameraButton: View {
    var prominent = false
    @Environment(\.openCamera) private var openCamera
    var body: some View {
        Group {
            if prominent {
                action.labelStyle(PhotoActionLabelStyle(side: 24))
                    .buttonStyle(.glassProminent).controlSize(.large).tint(Color.accentColor)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            } else {
                action.photoActionStyle()
            }
        }
        .disabled(openCamera == nil)
        .accessibilityIdentifier("camera.open")
    }
    private var action: some View {
        Button(
            String(localized: "photo_thumbnail.camera", defaultValue: "Camera"),
            systemImage: "camera"
        ) { openCamera?() }
        .buttonBorderShape(.circle)
        .accessibilityLabel(String(localized: "photo_thumbnail.camera", defaultValue: "Camera"))
    }
}

/// A small cached image. Status badges use one style in every gallery cell.
struct PhotoThumbnail: View {
    let photo: LibraryPhoto
    let images: LibraryImages
    var showsBadges = true
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipped().contentShape(.rect)
            .overlay(alignment: .topLeading) {
                if showsBadges && photo.isRAW { PhotoBadge(text: "RAW").padding(6) }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBadges && photo.hasEdits {
                    PhotoBadge(symbol: PhotoBadge.editedSymbol).padding(6)
                }
            }
            .task(id: "\(photo.id)-\(photo.renderKey)") {
                failed = false
                do {
                    let frame = try await images.image(photo, thumbnail: true)
                    try Task.checkCancellation()
                    image = UIImage(cgImage: frame)
                } catch { if !Task.isCancelled { failed = true } }
            }
            .onDisappear { image = nil }
            .accessibilityHidden(true)
    }
}

struct PhotoBadge: View {
    static let editedSymbol = "slider.horizontal.3"
    var text: String? = nil
    var symbol: String? = nil
    var compact = false
    var body: some View {
        Group {
            if let text {
                Text(text)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: compact ? 12 : 16, weight: .semibold))
            }
        }
        .accessibilityLabel(
            text ?? String(localized: "photo_thumbnail.edited", defaultValue: "Edited")
        )
        .accessibilityIdentifier(symbol == nil ? "photo.badge.raw" : "photo.badge.edited")
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(minHeight: compact ? 14 : 18)
        .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 2 : 4)
        .foregroundStyle(.white).background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

struct LibraryThumbnail: View {
    let photo: LibraryPhoto
    let images: LibraryImages
    let selecting: Bool
    let selected: Bool
    var body: some View {
        PhotoThumbnail(photo: photo, images: images).aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : .white)
                        .shadow(radius: 2).padding(7)
                }
            }
            .accessibilityHidden(true)
    }
}
