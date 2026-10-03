import SwiftUI

/// Swipe left/right through `photos` (capture order), each page being the photo detail sheet.
struct PhotoBrowser: View {
    let photos: [Photo]
    let onDelete: @MainActor (Photo) async throws -> Void
    @State private var selection: Photo.ID

    init(photos: [Photo], startID: Photo.ID, onDelete: @escaping @MainActor (Photo) async throws -> Void) {
        self.photos = photos
        self.onDelete = onDelete
        _selection = State(initialValue: startID)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(photos) { photo in
                PhotoDetailView(photo: photo) { try await onDelete(photo) }
                    .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            if photos.count > 1, let index = photos.firstIndex(where: { $0.id == selection }) {
                Text("\(index + 1) of \(photos.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .presentationDragIndicator(.visible)
    }
}
