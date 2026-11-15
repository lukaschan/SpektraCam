import SwiftUI

/// Native horizontal scrolling keeps album navigation within reach of the photo.
struct PhotoFilmstrip: View {
    let photos: [LibraryPhoto]
    let images: LibraryImages
    @Binding var selection: UUID
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(photos) { photo in
                        Button {
                            selection = photo.id
                        } label: {
                            PhotoThumbnail(photo: photo, images: images, showsBadges: false)
                                .frame(width: 44, height: 56)
                                .clipShape(.rect(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            photo.id == selection ? Color.accentColor : .clear,
                                            lineWidth: 3)
                                }
                        }
                        .buttonStyle(.plain).id(photo.id)
                        .accessibilityLabel(photo.filename)
                        .accessibilityValue(
                            photo.hasEdits
                                ? String(
                                    localized: "photo.edited", defaultValue: "Edited")
                                : String(
                                    localized: "photo.original", defaultValue: "Original")
                        )
                        .accessibilityAddTraits(photo.id == selection ? .isSelected : [])
                        .accessibilityIdentifier("photo.filmstrip.\(photo.id)")
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
            .frame(height: 72)
            .frame(maxWidth: CGFloat(photos.count * 50 + 10))
            .glassEffect(in: .rect(cornerRadius: 16))
            .accessibilityIdentifier("photo.filmstrip")
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, id in
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
