import Foundation

/// The backend operations the app uses (see `api/openapi.yaml`).
///
/// `APIClient` talks to the real backend; in Debug builds `MockAPI` serves the same
/// operations from memory, seeded with the contract's examples (`-MockAPI YES`).
/// A new contract operation gets a method here (or in `TripsAPI`) and in both implementations.
protocol PhotosAPI: Sendable {
    /// `GET /photos`: the caller's ready photos.
    func listPhotos() async throws -> [Photo]
    /// `POST /photos`: a pending record plus where to upload the file.
    func createPhoto(_ body: CreatePhotoRequest) async throws -> CreatePhotoResponse
    /// `DELETE /photos/{id}`. Deleting a photo that's already gone succeeds.
    func deletePhoto(id: String) async throws
    /// Uploads the file to the target from `createPhoto`/`createTripPhoto`; the photo is listed once it lands.
    func upload(_ file: Data, contentType: PhotoContentType, to target: UploadTarget,
                progress: (@Sendable (Double) -> Void)?) async throws
}

/// Shared trips (`/trips...`).
protocol TripsAPI: Sendable {
    /// `GET /trips`: the caller's trips, newest first.
    func listTrips() async throws -> [Trip]
    /// `POST /trips`: the caller becomes the first member.
    func createTrip(_ body: CreateTripRequest) async throws -> Trip
    /// `GET /trips/{tripId}`.
    func getTrip(id: String) async throws -> Trip
    /// `GET /trips/{tripId}/photos`: one page, in capture order. See `allTripPhotos`.
    func listTripPhotos(tripID: String, cursor: String?, limit: Int?) async throws -> TripPhotoPage
    /// `POST /trips/{tripId}/photos`: upload the file with `upload(_:contentType:to:)` afterwards.
    func createTripPhoto(tripID: String, _ body: CreatePhotoRequest) async throws -> CreatePhotoResponse
    /// `DELETE /trips/{tripId}/photos/{photoId}`: only the uploader may. Already gone succeeds.
    func deleteTripPhoto(tripID: String, photoID: String) async throws
}

/// Everything the app calls.
typealias BackendAPI = PhotosAPI & TripsAPI

extension PhotosAPI {
    func upload(_ file: Data, contentType: PhotoContentType, to target: UploadTarget) async throws {
        try await upload(file, contentType: contentType, to: target, progress: nil)
    }
}

extension TripsAPI {
    /// Every photo in a trip: follows `nextCursor` until it's null.
    func allTripPhotos(tripID: String, pageSize: Int? = nil) async throws -> [TripPhoto] {
        var photos: [TripPhoto] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await listTripPhotos(tripID: tripID, cursor: cursor, limit: pageSize)
            photos += page.photos
            cursor = page.nextCursor
            // A server handing back a cursor it already gave would otherwise loop forever.
            if let cursor, !seen.insert(cursor).inserted { throw APIError.invalidResponse }
        } while cursor != nil
        return photos
    }
}

extension APIClient: BackendAPI {}
