import Foundation
import Testing
@testable import PictureWare

/// The app against `api/openapi.json` (generated from `api/openapi.yaml`): every example the
/// app consumes must decode with its models, and every request body it sends must match the
/// schema. A contract change that would break this app build fails here.
@Suite("Contract")
struct ContractTests {
    /// What the app calls (see `APIClient`), and the model each success body decodes into.
    struct Consumed: Sendable, CustomTestStringConvertible {
        let operationID: String
        let method: String
        let path: String
        let successStatus: String
        let decode: (@Sendable (Data) throws -> Void)?

        var testDescription: String { "\(method) \(path) (\(operationID))" }
    }

    static func decoding<T: Decodable>(_ type: T.Type) -> @Sendable (Data) throws -> Void {
        { _ = try APICoding.decoder().decode(T.self, from: $0) }
    }

    static let consumed: [Consumed] = [
        Consumed(operationID: "listPhotos", method: "GET", path: "/photos", successStatus: "200", decode: decoding(PhotoList.self)),
        Consumed(operationID: "createPhoto", method: "POST", path: "/photos", successStatus: "201",
                 decode: decoding(CreatePhotoResponse.self)),
        Consumed(operationID: "deletePhoto", method: "DELETE", path: "/photos/{id}", successStatus: "204", decode: nil),
        Consumed(operationID: "listTrips", method: "GET", path: "/trips", successStatus: "200", decode: decoding(TripList.self)),
        Consumed(operationID: "createTrip", method: "POST", path: "/trips", successStatus: "201", decode: decoding(Trip.self)),
        Consumed(operationID: "getTrip", method: "GET", path: "/trips/{tripId}", successStatus: "200", decode: decoding(Trip.self)),
        Consumed(operationID: "listTripPhotos", method: "GET", path: "/trips/{tripId}/photos", successStatus: "200",
                 decode: decoding(TripPhotoPage.self)),
        Consumed(operationID: "createTripPhoto", method: "POST", path: "/trips/{tripId}/photos", successStatus: "201",
                 decode: decoding(CreatePhotoResponse.self)),
        Consumed(operationID: "deleteTripPhoto", method: "DELETE", path: "/trips/{tripId}/photos/{photoId}",
                 successStatus: "204", decode: nil),
    ]

    let contract: ContractDocument
    let validator: SchemaValidator

    init() throws {
        contract = try Contract.load()
        validator = SchemaValidator(contract: contract)
    }

    @Test(arguments: consumed)
    func operationExistsWhereTheAppCallsIt(_ consumed: Consumed) throws {
        let operation = try contract.operation(consumed.operationID)
        #expect(operation.method == consumed.method)
        #expect(operation.path == consumed.path)
        #expect(!operation.isPlanned, "the app calls \(consumed.operationID), so it must be live, not x-planned")
        #expect(contract.responses(of: operation)[consumed.successStatus] != nil,
                "the app expects \(consumed.successStatus) from \(consumed.operationID)")
    }

    @Test(arguments: consumed)
    func successExamplesDecode(_ consumed: Consumed) throws {
        let operation = try contract.operation(consumed.operationID)
        let response = try #require(contract.responses(of: operation)[consumed.successStatus])
        guard let decode = consumed.decode else {
            // The app ignores the body (e.g. 204), so the contract must not promise one.
            #expect(contract.jsonContent(response) == nil)
            return
        }
        let content = try #require(contract.jsonContent(response))
        let schema = try #require(content["schema"] as? [String: Any])
        let examples = contract.examples(in: content)
        #expect(!examples.isEmpty, "\(consumed.operationID) \(consumed.successStatus) needs an example for tests and mock mode")

        for example in examples {
            #expect(validator.errors(example.value, against: schema).isEmpty, "example \(example.name) doesn't match its own schema")
            #expect(throws: Never.self, "example \(example.name)") { try decode(example.json) }

            // Only what the schema requires, nullable fields null: the app must still decode it.
            let minimal = validator.minimal(example.value, schema: schema)
            let data = try JSONSerialization.data(withJSONObject: minimal, options: .fragmentsAllowed)
            #expect(throws: Never.self, "minimal form of example \(example.name)") { try decode(data) }
        }
    }

    @Test(arguments: consumed)
    func errorExamplesCarryAMessage(_ consumed: Consumed) throws {
        let operation = try contract.operation(consumed.operationID)
        for (status, response) in contract.responses(of: operation) where Int(status).map({ $0 >= 400 }) == true {
            guard let content = contract.jsonContent(response) else { continue }
            for example in contract.examples(in: content) {
                let message = APIClient.errorMessage(from: try example.json)
                #expect(message?.isEmpty == false, "\(consumed.operationID) \(status) example \(example.name)")
            }
        }
    }

    /// The client treats exactly these 404 bodies as "already deleted".
    @Test func alreadyDeletedMessagesMatchTheContract() throws {
        for operationID in ["deletePhoto", "deleteTripPhoto"] {
            let notFound = try #require(contract.responses(of: try contract.operation(operationID))["404"])
            let messages = try contract.examples(in: try #require(contract.jsonContent(notFound)))
                .compactMap { APIClient.errorMessage(from: try $0.json) }
            #expect(messages.contains("photo not found"), "\(operationID)")
        }
    }

    @Test func listExamplesCoverPhotosWithAndWithoutTakenAt() throws {
        let lists = try contract.responseExamples("listPhotos", status: "200")
            .map { try APICoding.decoder().decode(PhotoList.self, from: $0.json).photos }
        let photos = lists.flatMap { $0 }
        #expect(photos.contains { $0.takenAt != nil })
        #expect(photos.contains { $0.takenAt == nil })
        #expect(lists.contains { $0.isEmpty })
    }

    @Test func tripExamplesCoverOpenEndedAndPaging() throws {
        let trips = try contract.responseExamples("listTrips", status: "200")
            .flatMap { try APICoding.decoder().decode(TripList.self, from: $0.json).trips }
        #expect(trips.contains { $0.endDate == nil })
        #expect(trips.contains { $0.endDate != nil })

        let pages = try contract.responseExamples("listTripPhotos", status: "200")
            .map { try APICoding.decoder().decode(TripPhotoPage.self, from: $0.json) }
        #expect(pages.contains { $0.nextCursor != nil })
        #expect(pages.contains { $0.nextCursor == nil })
        #expect(Set(pages.flatMap(\.photos).map(\.uploaderId)).count > 1)
    }

    @Test func createResponseExampleHasWhatTheUploadNeeds() throws {
        for operationID in ["createPhoto", "createTripPhoto"] {
            let example = try #require(try contract.responseExamples(operationID, status: "201").first)
            let response = try APICoding.decoder().decode(CreatePhotoResponse.self, from: example.json)
            for field in ["key", "Content-Type", "policy"] {
                #expect(response.upload.fields[field] != nil, "\(operationID): missing upload field \(field)")
            }
        }
    }

    // MARK: Requests

    struct Sent: Sendable, CustomTestStringConvertible {
        let operationID: String
        let label: String
        let body: @Sendable () throws -> Data
        var testDescription: String { "\(operationID): \(label)" }
    }

    static let photoRequests: [(String, CreatePhotoRequest)] = [
        ("jpeg with takenAt", CreatePhotoRequest(lat: 37.8199, lng: -122.4783,
                                                 takenAt: Date(timeIntervalSince1970: 1_790_000_000.5), contentType: .jpeg)),
        ("heic, no takenAt, extremes", CreatePhotoRequest(lat: -90, lng: 180, takenAt: nil, contentType: .heic)),
    ]

    static let sent: [Sent] = photoRequests.flatMap { label, request in
        ["createPhoto", "createTripPhoto"].map { id in Sent(operationID: id, label: label) { try APICoding.encoder().encode(request) } }
    } + [
        Sent(operationID: "createTrip", label: "dated") {
            try APICoding.encoder().encode(CreateTripRequest(name: "Lisbon long weekend", startDate: CalendarDate("2026-10-01")!,
                                                             endDate: CalendarDate("2026-10-06")!))
        },
        Sent(operationID: "createTrip", label: "open-ended") {
            try APICoding.encoder().encode(CreateTripRequest(name: "Mia's 30th 🎉", startDate: CalendarDate("2026-10-03")!, endDate: nil))
        },
    ]

    @Test(arguments: sent)
    func requestBodiesMatchSchema(_ sent: Sent) throws {
        let operation = try contract.operation(sent.operationID)
        let content = try #require(contract.requestContent(of: operation))
        let schema = try #require(content["schema"] as? [String: Any])
        let body = try JSONSerialization.jsonObject(with: sent.body())
        let problems = validator.errors(body, against: schema)
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test func everyContentTypeTheAppSendsIsAllowed() throws {
        let schema = try #require(contract.lookup("#/components/schemas/PhotoContentType"))
        let allowed = Set(schema["enum"] as? [String] ?? [])
        for type in [PhotoContentType.jpeg, .heic] {
            #expect(allowed.contains(type.rawValue), "\(type.rawValue) not in the contract")
        }
    }

    // MARK: The validator itself

    @Test func validatorCatchesProblems() throws {
        let photo = try #require(contract.requestContent(of: try contract.operation("createPhoto"))?["schema"] as? [String: Any])
        #expect(!validator.errors(["lat": 1, "lng": 2], against: photo).isEmpty, "missing contentType")
        #expect(!validator.errors(["lat": 91, "lng": 2, "contentType": "image/jpeg"], against: photo).isEmpty)
        #expect(!validator.errors(["lat": 1, "lng": 2, "contentType": "image/png"], against: photo).isEmpty)
        #expect(!validator.errors(["lat": 1, "lng": 2, "contentType": "image/jpeg", "extra": true], against: photo).isEmpty)
        #expect(!validator.errors(["lat": 1, "lng": 2, "contentType": "image/jpeg", "takenAt": "yesterday"], against: photo).isEmpty)
        #expect(validator.errors(["lat": 1, "lng": 2, "contentType": "image/jpeg"], against: photo).isEmpty)

        let trip = try #require(contract.requestContent(of: try contract.operation("createTrip"))?["schema"] as? [String: Any])
        #expect(!validator.errors(["name": "", "startDate": "2026-10-03"], against: trip).isEmpty, "blank name")
        #expect(!validator.errors(["name": "x", "startDate": "2026-10-03T00:00:00Z"], against: trip).isEmpty, "date-time for date")
        #expect(!validator.errors(["name": String(repeating: "x", count: 101), "startDate": "2026-10-03"], against: trip).isEmpty)
        #expect(validator.errors(["name": "x", "startDate": "2026-10-03"], against: trip).isEmpty)
    }
}
