import Observation
import SwiftUI

/// Signed-in state: the user's photos. Uploads are handled by `UploadCenter`.
@MainActor
@Observable
final class PhotosModel {
    private(set) var photos: [Photo] = []
    private(set) var isLoading = false
    var loadError: String?
    /// Bumped whenever the map should re-fit to the pins.
    private(set) var fitGeneration = 0

    @ObservationIgnored private let api: any PhotosAPI

    init(api: any PhotosAPI) {
        self.api = api
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let previous = Set(photos.map(\.id))
            photos = try await api.listPhotos()
            loadError = nil
            if Set(photos.map(\.id)) != previous { fitGeneration += 1 }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    func delete(_ photo: Photo) async throws {
        try await api.deletePhoto(id: photo.id)
        photos.removeAll { $0.id == photo.id }
    }
}
