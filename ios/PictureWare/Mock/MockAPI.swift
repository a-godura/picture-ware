#if DEBUG
import Foundation
import UIKit

/// In-memory stand-in for the backend, seeded from the contract's examples.
///
/// Debug only: used by mock mode (`-MockAPI YES`, the "PictureWare (Mock)" scheme)
/// and by tests. Behaves like the documented API: created photos stay pending (not
/// listed) until their upload lands; trip photos come back in capture order, a page
/// at a time; deletes are idempotent; validation errors use the contract's messages.
///
/// To add an operation: add it to `PhotosAPI`/`TripsAPI`, keep its records in
/// `State`, and seed them from the operation's examples in `contractSeeded`.
actor MockAPI: BackendAPI {
    struct State: Sendable {
        /// `/photos` (the personal, pre-trips collection).
        var photos: [Photo] = []
        /// Newest first, as `GET /trips` returns them.
        var trips: [Trip] = []
        /// Trip id -> its ready photos, in capture order.
        var tripPhotos: [String: [TripPhoto]] = [:]
        /// Created but not yet uploaded, keyed by the upload's `key` field.
        var pending: [String: PendingPhoto] = [:]
    }

    struct PendingPhoto: Sendable {
        let id: String
        /// `nil` for `/photos`.
        let tripID: String?
        let request: CreatePhotoRequest
    }

    static let defaultPageSize = 200
    static let maxPageSize = 500

    /// The signed-in user: creator of new trips and uploader of new trip photos.
    nonisolated let userID: String
    private(set) var state: State
    private let uploadTemplate: UploadTarget
    private let latency: Duration
    private let uploadDuration: Duration
    private let imageDirectory: URL
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - uploadTemplate: the presigned POST every create hands out, with `key` and
    ///     `Content-Type` filled in per photo.
    ///   - latency: simulated round trip for API calls.
    ///   - uploadDuration: simulated upload time, reported as progress in steps.
    ///   - imageDirectory: where uploaded files are kept; listed photos point at them.
    init(state: State = State(), userID: String = "mock-user", uploadTemplate: UploadTarget,
         latency: Duration = .milliseconds(250), uploadDuration: Duration = .seconds(1),
         imageDirectory: URL = MockAPI.defaultImageDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        var state = state
        state.trips.sort(by: Self.newestFirst)
        state.tripPhotos = state.tripPhotos.mapValues { $0.sorted(by: Self.captureOrder) }
        self.state = state
        self.userID = userID
        self.uploadTemplate = uploadTemplate
        self.latency = latency
        self.uploadDuration = uploadDuration
        self.imageDirectory = imageDirectory
        self.now = now
    }

    static let defaultImageDirectory = FileManager.default.temporaryDirectory.appending(path: "MockAPI", directoryHint: .isDirectory)

    // MARK: - PhotosAPI

    func listPhotos() async throws -> [Photo] {
        try await simulateLatency()
        return state.photos
    }

    func createPhoto(_ body: CreatePhotoRequest) async throws -> CreatePhotoResponse {
        try await simulateLatency()
        try Self.validate(body)
        return makePending(body, tripID: nil, keyPrefix: "photos/\(userID)")
    }

    func deletePhoto(id: String) async throws {
        try await simulateLatency()
        state.photos.removeAll { $0.id == id }
    }

    /// Checks what the real presigned policy pins (target, key, Content-Type, 1 byte to 15 MiB),
    /// reports progress over `uploadDuration`, then lists the photo, as the backend does once S3 has the file.
    func upload(_ file: Data, contentType: PhotoContentType, to target: UploadTarget,
                progress: (@Sendable (Double) -> Void)?) async throws {
        guard target.url == uploadTemplate.url, let key = target.fields["key"], let pending = state.pending[key],
              target.fields["Content-Type"] == contentType.rawValue
        else { throw APIError.uploadFailed(status: 403) }
        guard (1...APIClient.maxUploadBytes).contains(file.count) else { throw APIError.uploadFailed(status: 400) }

        let steps = 10
        for step in 1...steps {
            try await Task.sleep(for: uploadDuration / steps)
            progress?(Double(step) / Double(steps))
        }

        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let fileURL = imageDirectory.appending(path: "\(pending.id).\(contentType.fileExtension)")
        try file.write(to: fileURL)
        state.pending[key] = nil
        let request = pending.request
        if let tripID = pending.tripID {
            // The trip may have been deleted meanwhile (not possible yet); then the photo just vanishes.
            guard state.tripPhotos[tripID] != nil else { return }
            state.tripPhotos[tripID]!.append(TripPhoto(id: pending.id, lat: request.lat, lng: request.lng,
                                                       takenAt: request.takenAt, createdAt: now(),
                                                       uploaderId: userID, imageUrl: fileURL))
            state.tripPhotos[tripID]!.sort(by: Self.captureOrder)
        } else {
            state.photos.append(Photo(id: pending.id, lat: request.lat, lng: request.lng,
                                      takenAt: request.takenAt, createdAt: now(), imageUrl: fileURL))
        }
    }

    // MARK: - TripsAPI

    func listTrips() async throws -> [Trip] {
        try await simulateLatency()
        return state.trips
    }

    func createTrip(_ body: CreateTripRequest) async throws -> Trip {
        try await simulateLatency()
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Self.validation("name is required") }
        guard name.count <= 100 else { throw Self.validation("name must be at most 100 characters") }
        if let end = body.endDate, end < body.startDate {
            throw Self.validation("endDate must not be before startDate")
        }
        let trip = Trip(id: UUID().uuidString.lowercased(), name: name, startDate: body.startDate,
                        endDate: body.endDate, createdBy: userID, createdAt: now())
        state.trips.append(trip)
        state.trips.sort(by: Self.newestFirst)
        state.tripPhotos[trip.id] = []
        return trip
    }

    func getTrip(id: String) async throws -> Trip {
        try await simulateLatency()
        guard let trip = state.trips.first(where: { $0.id == id }) else { throw Self.tripNotFound }
        return trip
    }

    /// Cursors are opaque to clients; here they're just the offset of the next page.
    func listTripPhotos(tripID: String, cursor: String?, limit: Int?) async throws -> TripPhotoPage {
        try await simulateLatency()
        let limit = limit ?? Self.defaultPageSize
        guard (1...Self.maxPageSize).contains(limit) else {
            throw APIError.http(status: 400, message: "limit must be an integer from 1 to \(Self.maxPageSize)")
        }
        guard let photos = state.tripPhotos[tripID] else { throw Self.tripNotFound }
        var offset = 0
        if let cursor {
            guard let decoded = Self.offset(fromCursor: cursor), decoded <= photos.count else {
                throw APIError.http(status: 400, message: "invalid cursor")
            }
            offset = decoded
        }
        let end = min(offset + limit, photos.count)
        return TripPhotoPage(photos: Array(photos[offset..<end]),
                             nextCursor: end < photos.count ? Self.cursor(forOffset: end) : nil)
    }

    func createTripPhoto(tripID: String, _ body: CreatePhotoRequest) async throws -> CreatePhotoResponse {
        try await simulateLatency()
        guard state.tripPhotos[tripID] != nil else { throw Self.tripNotFound }
        try Self.validate(body)
        return makePending(body, tripID: tripID, keyPrefix: "trips/\(tripID)")
    }

    func deleteTripPhoto(tripID: String, photoID: String) async throws {
        try await simulateLatency()
        guard let photos = state.tripPhotos[tripID] else { throw Self.tripNotFound }
        guard let photo = photos.first(where: { $0.id == photoID }) else { return }
        guard photo.uploaderId == userID else {
            throw APIError.http(status: 403, message: "only the person who uploaded a photo can delete it")
        }
        state.tripPhotos[tripID]!.removeAll { $0.id == photoID }
    }

    // MARK: - Private

    private func makePending(_ body: CreatePhotoRequest, tripID: String?, keyPrefix: String) -> CreatePhotoResponse {
        let id = UUID().uuidString.lowercased()
        let key = "\(keyPrefix)/\(id)"
        var fields = uploadTemplate.fields
        fields["key"] = key
        fields["Content-Type"] = body.contentType.rawValue
        state.pending[key] = PendingPhoto(id: id, tripID: tripID, request: body)
        return CreatePhotoResponse(id: id, upload: UploadTarget(url: uploadTemplate.url, fields: fields))
    }

    private func simulateLatency() async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
    }

    private static func validate(_ body: CreatePhotoRequest) throws {
        guard (-90...90).contains(body.lat) else { throw validation("lat must be between -90 and 90") }
        guard (-180...180).contains(body.lng) else { throw validation("lng must be between -180 and 180") }
    }

    private static func validation(_ message: String) -> APIError {
        .http(status: 400, message: "validation failed: \(message)")
    }

    private static let tripNotFound = APIError.http(status: 404, message: "trip not found")

    private static func cursor(forOffset offset: Int) -> String {
        Data("mock-offset:\(offset)".utf8).base64EncodedString()
    }

    private static func offset(fromCursor cursor: String) -> Int? {
        guard let data = Data(base64Encoded: cursor),
              let text = String(data: data, encoding: .utf8), text.hasPrefix("mock-offset:") else { return nil }
        return Int(text.dropFirst("mock-offset:".count)).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// `GET /trips` order: by `startDate`, then `createdAt`, newest first.
    static func newestFirst(_ a: Trip, _ b: Trip) -> Bool {
        a.startDate != b.startDate ? a.startDate > b.startDate : a.createdAt > b.createdAt
    }

    /// `GET /trips/{id}/photos` order: by `takenAt`; photos without one last, by `createdAt`.
    static func captureOrder(_ a: TripPhoto, _ b: TripPhoto) -> Bool {
        switch (a.takenAt, b.takenAt) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
    }
}

// MARK: - Seeding from the contract

extension MockAPI {
    /// A mock seeded with the contract's examples:
    /// - `/photos`: the largest `listPhotos` 200 example;
    /// - trips: the largest `listTrips` 200 example, each trip's photos from the complete
    ///   (`nextCursor: null`) `listTripPhotos` examples, matched to trips by the trip id in
    ///   their storage key (`trips/{tripId}/{photoId}`);
    /// - uploads: the `createPhoto` 201 example as the presigned-POST template, and the user
    ///   id from its key (`photos/{userId}/{photoId}`).
    ///
    /// The examples' image URLs point at a bucket that doesn't exist, so with
    /// `placeholderImages` each seeded photo gets a generated local image instead.
    @MainActor
    static func contractSeeded(_ contract: ContractDocument, placeholderImages: Bool = true,
                               latency: Duration = .milliseconds(250), uploadDuration: Duration = .seconds(1),
                               imageDirectory: URL = MockAPI.defaultImageDirectory) throws -> MockAPI {
        let decoder = APICoding.decoder()
        func largest<T: Decodable>(_ operation: String, _ type: T.Type, count: (T) -> Int) throws -> T {
            let decoded = try contract.responseExamples(operation, status: "200").map { try decoder.decode(T.self, from: $0.json) }
            guard let best = decoded.max(by: { count($0) < count($1) }) else {
                throw ContractDocument.Failure.malformed("no \(operation) 200 example")
            }
            return best
        }

        var state = State()
        state.photos = try largest("listPhotos", PhotoList.self) { $0.photos.count }.photos
        state.trips = try largest("listTrips", TripList.self) { $0.trips.count }.trips
        for trip in state.trips { state.tripPhotos[trip.id] = [] }
        let pages = try contract.responseExamples("listTripPhotos", status: "200")
            .map { try decoder.decode(TripPhotoPage.self, from: $0.json) }
            .filter { $0.nextCursor == nil }
        for photo in pages.flatMap(\.photos) {
            let components = photo.imageUrl.pathComponents
            guard let index = components.firstIndex(of: "trips"), index + 1 < components.count,
                  state.tripPhotos[components[index + 1]]?.contains(where: { $0.id == photo.id }) == false
            else { continue }
            state.tripPhotos[components[index + 1]]!.append(photo)
        }

        guard let created = try contract.responseExamples("createPhoto", status: "201").first else {
            throw ContractDocument.Failure.malformed("no createPhoto 201 example")
        }
        let template = try decoder.decode(CreatePhotoResponse.self, from: created.json).upload
        let keyParts = template.fields["key"]?.split(separator: "/") ?? []
        let userID = keyParts.count == 3 && keyParts[0] == "photos" ? String(keyParts[1]) : "mock-user"

        if placeholderImages {
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
            var index = 0
            func placeholder(id: String, lat: Double, lng: Double) throws -> URL {
                let url = imageDirectory.appending(path: "seed-\(id).jpg")
                try MockPlaceholder.jpeg(index: index, caption: MockPlaceholder.caption(lat: lat, lng: lng)).write(to: url)
                index += 1
                return url
            }
            state.photos = try state.photos.map {
                Photo(id: $0.id, lat: $0.lat, lng: $0.lng, takenAt: $0.takenAt, createdAt: $0.createdAt,
                      imageUrl: try placeholder(id: $0.id, lat: $0.lat, lng: $0.lng))
            }
            for (tripID, photos) in state.tripPhotos {
                state.tripPhotos[tripID] = try photos.map {
                    TripPhoto(id: $0.id, lat: $0.lat, lng: $0.lng, takenAt: $0.takenAt, createdAt: $0.createdAt,
                              uploaderId: $0.uploaderId, imageUrl: try placeholder(id: $0.id, lat: $0.lat, lng: $0.lng))
                }
            }
        }
        return MockAPI(state: state, userID: userID, uploadTemplate: template, latency: latency,
                       uploadDuration: uploadDuration, imageDirectory: imageDirectory)
    }
}

/// Simple generated pictures for the seeded photos.
@MainActor
enum MockPlaceholder {
    private static let palette: [(UIColor, UIColor)] = [
        (.systemTeal, .systemBlue), (.systemOrange, .systemPink), (.systemGreen, .systemMint),
        (.systemPurple, .systemIndigo), (.systemYellow, .systemOrange),
    ]

    static func caption(lat: Double, lng: Double) -> String {
        "\(lat.formatted(.number.precision(.fractionLength(3)))), \(lng.formatted(.number.precision(.fractionLength(3))))"
    }

    static func jpeg(index: Int, caption: String) -> Data {
        let size = CGSize(width: 480, height: 360)
        let (top, bottom) = palette[index % palette.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                                 options: [])
            let symbol = UIImage(systemName: "mountain.2.fill",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 120, weight: .regular))?
                .withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal)
            if let symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2 - 20))
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = caption as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: size.height - textSize.height - 28),
                      withAttributes: attributes)
        }
    }
}
#endif
