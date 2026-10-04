import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PictureWare

/// Collects progress callbacks from another isolation domain.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

@Suite("MockAPI")
@MainActor
struct MockAPITests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "MockAPITests-\(UUID().uuidString)")
    let contract: ContractDocument

    init() throws {
        contract = try Contract.load()
    }

    func makeMock(placeholderImages: Bool = false) throws -> MockAPI {
        try MockAPI.contractSeeded(contract, placeholderImages: placeholderImages, latency: .zero,
                                   uploadDuration: .milliseconds(20), imageDirectory: directory)
    }

    func exampleRequest(lat: Double = 37.8199, lng: Double = -122.4783) -> CreatePhotoRequest {
        CreatePhotoRequest(lat: lat, lng: lng, takenAt: Date(timeIntervalSince1970: 1_790_000_000), contentType: .jpeg)
    }

    @Test func seededWithTheContractListExample() async throws {
        let example = try #require(try contract.responseExamples("listPhotos", status: "200")
            .map { try APICoding.decoder().decode(PhotoList.self, from: $0.json).photos }
            .max { $0.count < $1.count })
        let photos = try await makeMock().listPhotos()
        #expect(photos == example)
        #expect(photos.count >= 2)
    }

    @Test func placeholderImagesAreLocalFiles() async throws {
        let photos = try await makeMock(placeholderImages: true).listPhotos()
        #expect(!photos.isEmpty)
        for photo in photos {
            #expect(photo.imageUrl.isFileURL)
            let data = try Data(contentsOf: photo.imageUrl)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        }
    }

    @Test func createdPhotoIsPendingUntilUploaded() async throws {
        let api = try makeMock()
        let before = try await api.listPhotos()
        let created = try await api.createPhoto(exampleRequest())

        #expect(created.upload.fields["key"]?.hasSuffix(created.id) == true)
        #expect(created.upload.fields["Content-Type"] == "image/jpeg")
        #expect(created.upload.fields["policy"] != nil)
        #expect(try await api.listPhotos() == before, "pending photos aren't listed")

        let progress = ProgressLog()
        let file = TestFixtures.image()
        try await api.upload(file, contentType: .jpeg, to: created.upload) { progress.append($0) }

        let after = try await api.listPhotos()
        let photo = try #require(after.first { $0.id == created.id })
        #expect(after.count == before.count + 1)
        #expect(photo.lat == 37.8199 && photo.lng == -122.4783)
        #expect(photo.takenAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try Data(contentsOf: photo.imageUrl) == file)
        #expect(progress.all.last == 1)
        #expect(progress.all == progress.all.sorted())
    }

    @Test func uploadIsRejectedLikeThePresignedPolicyWould() async throws {
        let api = try makeMock()
        let created = try await api.createPhoto(exampleRequest())
        let file = TestFixtures.image()

        await #expect(throws: APIError.uploadFailed(status: 403), "wrong content type") {
            try await api.upload(file, contentType: .heic, to: created.upload)
        }
        var otherKey = created.upload.fields
        otherKey["key"] = "photos/someone-else/x"
        await #expect(throws: APIError.uploadFailed(status: 403), "unknown key") {
            try await api.upload(file, contentType: .jpeg, to: UploadTarget(url: created.upload.url, fields: otherKey))
        }
        await #expect(throws: APIError.uploadFailed(status: 400), "empty file") {
            try await api.upload(Data(), contentType: .jpeg, to: created.upload)
        }
        await #expect(throws: APIError.uploadFailed(status: 400), "over 15 MiB") {
            try await api.upload(Data(count: APIClient.maxUploadBytes + 1), contentType: .jpeg, to: created.upload)
        }

        // A successful upload uses up the presigned target.
        try await api.upload(file, contentType: .jpeg, to: created.upload)
        await #expect(throws: APIError.uploadFailed(status: 403)) {
            try await api.upload(file, contentType: .jpeg, to: created.upload)
        }
    }

    @Test func createValidatesCoordinates() async throws {
        let api = try makeMock()
        await #expect(throws: APIError.http(status: 400, message: "validation failed: lat must be between -90 and 90")) {
            _ = try await api.createPhoto(exampleRequest(lat: 91))
        }
        await #expect(throws: APIError.http(status: 400, message: "validation failed: lng must be between -180 and 180")) {
            _ = try await api.createPhoto(exampleRequest(lng: -181))
        }
    }

    @Test func deleteRemovesAndIsIdempotent() async throws {
        let api = try makeMock()
        let first = try #require(try await api.listPhotos().first)
        try await api.deletePhoto(id: first.id)
        #expect(try await api.listPhotos().contains(first) == false)
        try await api.deletePhoto(id: first.id)
        try await api.deletePhoto(id: "never-existed")
    }

    // MARK: PhotosModel on the mock (what mock mode runs)

    @Test func photosModelLoadsAndDeletes() async throws {
        let api = try makeMock()
        let model = PhotosModel(api: api)
        await model.load()
        #expect(model.loadError == nil)
        #expect(model.photos.count == (try await api.listPhotos()).count)
        #expect(model.fitGeneration == 1)

        let photo = try #require(model.photos.first)
        try await model.delete(photo)
        #expect(!model.photos.contains(photo))
        await model.load()
        #expect(!model.photos.contains(photo))
    }

    // MARK: Trips

    static let lisbonID = "ce9f9b98-5813-4fa3-98ce-282743afbfa0"

    @Test func tripsSeededFromTheContract() async throws {
        let api = try makeMock()
        let example = try #require(try contract.responseExamples("listTrips", status: "200")
            .map { try APICoding.decoder().decode(TripList.self, from: $0.json).trips }
            .max { $0.count < $1.count })
        #expect(try await api.listTrips() == example, "the example is already newest-first")
        #expect(try await api.getTrip(id: Self.lisbonID).name == "Lisbon long weekend")

        // Lisbon: the complete three-uploader example (the paged example overlaps it, not duplicated).
        let lisbon = try await api.allTripPhotos(tripID: Self.lisbonID)
        #expect(lisbon.count == 5)
        #expect(Set(lisbon.map(\.uploaderId)).count == 3)
        #expect(lisbon.last?.takenAt == nil, "photos without takenAt come last")
        #expect(try await api.allTripPhotos(tripID: "dfb1c221-bcab-4bf8-b560-1ddd49767cf6").count == 2)
        #expect(try await api.allTripPhotos(tripID: "3dbba8e8-5e92-4a4a-9976-8d3afe8edba4").isEmpty)
        // The signed-in user is the one in the contract's upload key, who created Lisbon.
        #expect(api.userID == "511b25d0-40a1-705d-f49c-7e89f72c4924")
    }

    @Test func tripPhotosArePaged() async throws {
        let api = try makeMock()
        let first = try await api.listTripPhotos(tripID: Self.lisbonID, cursor: nil, limit: 2)
        #expect(first.photos.count == 2)
        let cursor = try #require(first.nextCursor)
        let paged = try await api.allTripPhotos(tripID: Self.lisbonID, pageSize: 2)
        #expect(paged == (try await api.allTripPhotos(tripID: Self.lisbonID)))
        #expect(paged.prefix(2) == first.photos[...])

        await #expect(throws: APIError.http(status: 400, message: "invalid cursor")) {
            _ = try await api.listTripPhotos(tripID: Self.lisbonID, cursor: "nonsense", limit: nil)
        }
        await #expect(throws: APIError.http(status: 400, message: "limit must be an integer from 1 to 500")) {
            _ = try await api.listTripPhotos(tripID: Self.lisbonID, cursor: cursor, limit: 501)
        }
        await #expect(throws: APIError.http(status: 404, message: "trip not found")) {
            _ = try await api.listTripPhotos(tripID: "nope", cursor: nil, limit: nil)
        }
    }

    @Test func createTripValidatesAndSorts() async throws {
        let api = try makeMock()
        let trip = try await api.createTrip(CreateTripRequest(name: "  Lake weekend ", startDate: CalendarDate("2027-01-10")!,
                                                              endDate: nil))
        #expect(trip.name == "Lake weekend")
        #expect(trip.createdBy == api.userID)
        #expect(try await api.listTrips().first == trip, "newest startDate first")
        #expect(try await api.allTripPhotos(tripID: trip.id).isEmpty)

        await #expect(throws: APIError.http(status: 400, message: "validation failed: name is required")) {
            _ = try await api.createTrip(CreateTripRequest(name: "   ", startDate: CalendarDate("2027-01-10")!, endDate: nil))
        }
        await #expect(throws: APIError.http(status: 400, message: "validation failed: endDate must not be before startDate")) {
            _ = try await api.createTrip(CreateTripRequest(name: "x", startDate: CalendarDate("2027-01-10")!,
                                                           endDate: CalendarDate("2027-01-09")!))
        }
    }

    @Test func tripPhotoUploadLandsInCaptureOrder() async throws {
        let api = try makeMock()
        let created = try await api.createTripPhoto(tripID: Self.lisbonID, CreatePhotoRequest(
            lat: 38.7, lng: -9.14, takenAt: try #require(APICoding.parseDate("2026-10-01T16:00:00Z")), contentType: .heic))
        #expect(created.upload.fields["key"] == "trips/\(Self.lisbonID)/\(created.id)")
        #expect(try await api.allTripPhotos(tripID: Self.lisbonID).count == 5, "pending until uploaded")

        try await api.upload(Data([1, 2, 3]), contentType: .heic, to: created.upload)
        let photos = try await api.allTripPhotos(tripID: Self.lisbonID)
        #expect(photos.count == 6)
        #expect(photos.firstIndex { $0.id == created.id } == 1, "between the 15:20 and 18:47 photos")
        #expect(photos.first { $0.id == created.id }?.uploaderId == api.userID)
        #expect(try await api.listPhotos().contains { $0.id == created.id } == false, "not in /photos")

        await #expect(throws: APIError.http(status: 404, message: "trip not found")) {
            _ = try await api.createTripPhoto(tripID: "nope", CreatePhotoRequest(lat: 0, lng: 0, takenAt: nil, contentType: .jpeg))
        }
    }

    @Test func onlyTheUploaderDeletesATripPhoto() async throws {
        let api = try makeMock()
        let photos = try await api.allTripPhotos(tripID: Self.lisbonID)
        let mine = try #require(photos.first { $0.uploaderId == api.userID })
        let theirs = try #require(photos.first { $0.uploaderId != api.userID })

        await #expect(throws: APIError.http(status: 403, message: "only the person who uploaded a photo can delete it")) {
            try await api.deleteTripPhoto(tripID: Self.lisbonID, photoID: theirs.id)
        }
        try await api.deleteTripPhoto(tripID: Self.lisbonID, photoID: mine.id)
        try await api.deleteTripPhoto(tripID: Self.lisbonID, photoID: mine.id)
        #expect(try await api.allTripPhotos(tripID: Self.lisbonID).count == photos.count - 1)
        await #expect(throws: APIError.http(status: 404, message: "trip not found")) {
            try await api.deleteTripPhoto(tripID: "nope", photoID: mine.id)
        }
    }

    // MARK: Mock-mode upload transport (the bulk upload queue's path)

    @Test func transportDeliversTheQueuesMultipartBodyToTheMock() async throws {
        let api = try makeMock()
        let created = try await api.createPhoto(exampleRequest())
        let file = TestFixtures.image()
        let form = MultipartFormBody.s3Upload(fields: created.upload.fields, file: file, filename: "photo.jpg",
                                              contentType: "image/jpeg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = directory.appending(path: "body")
        try form.finalized().write(to: body)

        let transport = MockUploadTransport(api: api)
        let progress = ProgressLog()
        let status = try await transport.upload(itemID: "i", bodyFile: body, contentType: form.contentType,
                                                to: created.upload.url) { progress.append($0) }
        #expect(status == 204)
        #expect(progress.all.last == 1)
        let photo = try #require(try await api.listPhotos().first { $0.id == created.id })
        #expect(try Data(contentsOf: photo.imageUrl) == file)

        // Same body again: the presign is used up, like S3 rejecting a replayed policy.
        #expect(try await transport.upload(itemID: "i", bodyFile: body, contentType: form.contentType,
                                           to: created.upload.url) { _ in } == 403)
    }

    @Test func multipartParsing() throws {
        let form = MultipartFormBody.s3Upload(fields: ["key": "k", "Content-Type": "image/heic", "policy": "p"],
                                              file: Data("\r\n--not-a-boundary\r\n".utf8), filename: "f.heic",
                                              contentType: "image/heic", boundary: "B0UND")
        #expect(MockUploadTransport.boundary(in: form.contentType) == "B0UND")
        let parsed = try #require(MockUploadTransport.parse(form.finalized(), boundary: "B0UND"))
        #expect(parsed.fields == ["key": "k", "Content-Type": "image/heic", "policy": "p"])
        #expect(parsed.file == Data("\r\n--not-a-boundary\r\n".utf8))
        #expect(MockUploadTransport.parse(Data("garbage".utf8), boundary: "B0UND") == nil)
    }

    @Test func bundledContractMatchesTheTestCopy() throws {
        // Mock mode reads the app bundle's copy; it must be the same contract.
        let appCopy = try ContractDocument.bundled(in: .main)
        #expect(NSDictionary(dictionary: appCopy.root).isEqual(to: contract.root))
    }
}
