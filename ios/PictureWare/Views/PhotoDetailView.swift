import SwiftUI

/// Sheet shown when a pin is tapped: the full image, when it was taken, and delete.
struct PhotoDetailView: View {
    let photo: Photo
    let onDelete: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.exportModel) private var export
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteError: String?

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

                    if let export { SaveToPhotosButton(model: export, photo: photo) }

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
                ToolbarItem(placement: .topBarLeading) {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            .tint(.red)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Photo", role: .destructive) { Task { await delete() } }
            } message: {
                Text("It will be removed from your map and deleted from storage. This can't be undone.")
            }
            .alert("Couldn't delete photo", isPresented: .constant(deleteError != nil)) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDeleting)
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await onDelete()
            dismiss()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
