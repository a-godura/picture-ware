import Observation
import PhotosUI
import SwiftUI

/// Signed-in state: the user's photos and the current upload.
@MainActor
@Observable
final class PhotosModel {
    enum UploadState: Equatable {
        case idle
        case preparing
        case uploading(Double)
        case processing
        case failed(String)
    }

    private(set) var photos: [Photo] = []
    private(set) var isLoading = false
    var loadError: String?
    var uploadState: UploadState = .idle
    /// Bumped whenever the map should re-fit to the pins.
    private(set) var fitGeneration = 0

    @ObservationIgnored private let api: APIClient

    init(api: APIClient) {
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

    func upload(_ item: PhotosPickerItem) async {
        uploadState = .preparing
        do {
            let prepared = try await PhotoImporter.prepare(item)
            uploadState = .uploading(0)
            let created = try await api.createPhoto(CreatePhotoRequest(
                lat: prepared.location.latitude,
                lng: prepared.location.longitude,
                takenAt: prepared.takenAt,
                contentType: prepared.contentType
            ))
            try await api.upload(prepared.data, contentType: prepared.contentType, to: created.upload) { [weak self] fraction in
                Task { @MainActor in
                    if case .uploading = self?.uploadState { self?.uploadState = .uploading(fraction) }
                }
            }
            uploadState = .processing
            await waitUntilListed(id: created.id)
            uploadState = .idle
        } catch {
            uploadState = .failed(error.localizedDescription)
        }
    }

    /// The backend marks a photo ready asynchronously after S3 receives it; poll briefly.
    private func waitUntilListed(id: String) async {
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            await load()
            if photos.contains(where: { $0.id == id }) { return }
        }
    }
}
