import SwiftUI

/// Sheet shown when a pin is tapped: the full image and when it was taken.
struct PhotoDetailView: View {
    let photo: Photo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AsyncImage(url: photo.imageUrl) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else if phase.error != nil {
                            ContentUnavailableView("Couldn't load image", systemImage: "photo")
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    LabeledContent("Taken") {
                        Text(photo.takenAt?.formatted(date: .long, time: .shortened) ?? "Unknown")
                    }
                    LabeledContent("Location") {
                        Text("\(photo.lat.formatted(.number.precision(.fractionLength(5)))), \(photo.lng.formatted(.number.precision(.fractionLength(5))))")
                            .monospacedDigit()
                    }
                    LabeledContent("Uploaded") {
                        Text(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding()
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
