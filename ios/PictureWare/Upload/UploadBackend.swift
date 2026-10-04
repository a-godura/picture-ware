import Foundation

/// The API calls the upload queue needs. Kept separate from `APIClient` so the queue can be
/// tested with fakes and doesn't depend on how the rest of the app talks to the backend.
protocol UploadBackend: Sendable {
    /// Creates a pending photo record and returns its presigned upload.
    func createPhoto(_ request: CreatePhotoRequest) async throws -> CreatePhotoResponse
    /// Whether the photo already finished uploading (the API lists only ready photos). Used before
    /// replacing an expired presign, so a retry never creates a second copy of a photo that landed.
    func isPhotoListed(id: String) async throws -> Bool
}

/// Sends a multipart body file to a presigned storage URL.
///
/// Implementations key work by `itemID` so a relaunched app can re-attach to an upload the
/// system kept running (see `BackgroundUploadTransport`).
protocol UploadTransport: Sendable {
    /// If the system is still running an upload for `itemID` that we started before a relaunch
    /// (or finished it while nobody was waiting), waits for it and returns its HTTP status.
    /// Returns nil when there is nothing to re-attach to.
    func attach(itemID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int?

    /// Starts uploading `bodyFile` to `url` and returns the storage response's HTTP status.
    /// Throws for transport errors (no connection, cancelled, ...).
    func upload(itemID: String, bodyFile: URL, contentType: String, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Int

    /// Stops any upload for `itemID` (the user removed it).
    func cancel(itemID: String) async
}

/// `UploadBackend` over the app's API (the real `APIClient`, or `MockAPI` in mock mode).
struct APIUploadBackend: UploadBackend {
    let api: any PhotosAPI

    func createPhoto(_ request: CreatePhotoRequest) async throws -> CreatePhotoResponse {
        try await api.createPhoto(request)
    }

    func isPhotoListed(id: String) async throws -> Bool {
        try await api.listPhotos().contains { $0.id == id }
    }
}
