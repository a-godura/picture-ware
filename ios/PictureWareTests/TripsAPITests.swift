import Foundation
import Testing
@testable import PictureWare

@Suite("Trip models")
struct TripModelTests {
    @Test func calendarDateParsing() throws {
        let date = try #require(CalendarDate("2026-10-03"))
        #expect(date.year == 2026 && date.month == 10 && date.day == 3)
        #expect(date.description == "2026-10-03")
        for bad in ["2026-10-3", "2026-13-01", "2026-02-30", "26-10-03", "2026-10-03T00:00:00Z", "２０２６-10-03", ""] {
            #expect(CalendarDate(bad) == nil, "\(bad)")
        }
        #expect(CalendarDate("2028-02-29") != nil)
        #expect(CalendarDate("2026-09-30")! < CalendarDate("2026-10-01")!)
    }

    @Test func createTripRequestOmitsMissingEndDate() throws {
        let json = String(decoding: try APICoding.encoder().encode(
            CreateTripRequest(name: "Lisbon", startDate: CalendarDate("2026-10-01")!, endDate: CalendarDate("2026-10-06")!)
        ), as: UTF8.self)
        #expect(json == #"{"endDate":"2026-10-06","name":"Lisbon","startDate":"2026-10-01"}"#)

        let open = try JSONSerialization.jsonObject(with: APICoding.encoder().encode(
            CreateTripRequest(name: "Open", startDate: CalendarDate("2026-10-03")!, endDate: nil)
        )) as! [String: Any]
        #expect(Set(open.keys) == ["name", "startDate"])
    }

    @Test func tripRejectsDateTimeAsDate() {
        let json = #"{"id":"t","name":"n","startDate":"2026-10-03T00:00:00Z","endDate":null,"createdBy":"u","createdAt":"2026-10-03T00:00:00Z"}"#
        #expect(throws: DecodingError.self) { try APICoding.decoder().decode(Trip.self, from: Data(json.utf8)) }
    }
}

/// A `TripsAPI` serving fixed pages, for `allTripPhotos`.
private actor PagedTrips: TripsAPI {
    let pages: [String?: TripPhotoPage]
    private(set) var requestedCursors: [String?] = []

    init(pages: [String?: TripPhotoPage]) { self.pages = pages }

    func listTripPhotos(tripID: String, cursor: String?, limit: Int?) async throws -> TripPhotoPage {
        requestedCursors.append(cursor)
        return pages[cursor] ?? TripPhotoPage(photos: [], nextCursor: nil)
    }

    func listTrips() async throws -> [Trip] { [] }
    func createTrip(_ body: CreateTripRequest) async throws -> Trip { throw APIError.invalidResponse }
    func getTrip(id: String) async throws -> Trip { throw APIError.invalidResponse }
    func createTripPhoto(tripID: String, _ body: CreatePhotoRequest) async throws -> CreatePhotoResponse { throw APIError.invalidResponse }
    func deleteTripPhoto(tripID: String, photoID: String) async throws {}
}

@Suite("Trip paging")
struct TripPagingTests {
    static func photo(_ id: String) -> TripPhoto {
        TripPhoto(id: id, lat: 0, lng: 0, takenAt: nil, createdAt: Date(timeIntervalSince1970: 0),
                  uploaderId: "u", imageUrl: URL(string: "https://example.com/\(id)")!)
    }

    @Test func followsNextCursorIncludingEmptyPages() async throws {
        let api = PagedTrips(pages: [
            nil: TripPhotoPage(photos: [Self.photo("a"), Self.photo("b")], nextCursor: "c1"),
            "c1": TripPhotoPage(photos: [], nextCursor: "c2"),
            "c2": TripPhotoPage(photos: [Self.photo("c")], nextCursor: nil),
        ])
        let photos = try await api.allTripPhotos(tripID: "t")
        #expect(photos.map(\.id) == ["a", "b", "c"])
        #expect(await api.requestedCursors == [nil, "c1", "c2"])
    }

    @Test func repeatedCursorStops() async throws {
        let api = PagedTrips(pages: [
            nil: TripPhotoPage(photos: [Self.photo("a")], nextCursor: "loop"),
            "loop": TripPhotoPage(photos: [Self.photo("b")], nextCursor: "loop"),
        ])
        await #expect(throws: APIError.invalidResponse) { _ = try await api.allTripPhotos(tripID: "t") }
    }
}

// Uses StubURLProtocol, so these run inside the serialized `NetworkTests` suite.
extension NetworkTests {
    @Test func listTripPhotosSendsCursorAndLimit() async throws {
        StubURLProtocol.install { _ in (200, Data(#"{"photos":[],"nextCursor":null}"#.utf8)) }
        _ = try await api.listTripPhotos(tripID: "t1", cursor: "a+b/c=", limit: 2)
        let url = try #require(StubURLProtocol.requests.first?.url)
        #expect(url.path() == "/trips/t1/photos")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = try #require(components.queryItems)
        #expect(items.first { $0.name == "limit" }?.value == "2")
        #expect(items.first { $0.name == "cursor" }?.value == "a+b/c=")
        #expect(components.percentEncodedQuery?.contains("+") == false, "a raw + would reach the server as a space")
    }

    @Test func firstTripPhotoPageHasNoQuery() async throws {
        StubURLProtocol.install { _ in (200, Data(#"{"photos":[],"nextCursor":null}"#.utf8)) }
        _ = try await api.listTripPhotos(tripID: "t1", cursor: nil, limit: nil)
        #expect(StubURLProtocol.requests.first?.url?.query() == nil)
    }

    @Test func createTripPostsJSON() async throws {
        StubURLProtocol.install { _ in
            (201, Data(#"{"id":"t1","name":"Lisbon","startDate":"2026-10-01","endDate":null,"createdBy":"u","createdAt":"2026-10-01T00:00:00Z"}"#.utf8))
        }
        let trip = try await api.createTrip(CreateTripRequest(name: "Lisbon", startDate: CalendarDate("2026-10-01")!, endDate: nil))
        #expect(trip.id == "t1" && trip.endDate == nil)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/trips")
        #expect(request.bodyString == #"{"name":"Lisbon","startDate":"2026-10-01"}"#)
    }

    @Test func createTripPhotoPostsToTheTrip() async throws {
        StubURLProtocol.install { _ in
            (201, Data(#"{"id":"p","upload":{"url":"https://bucket.s3.amazonaws.com","fields":{"key":"trips/t1/p"}}}"#.utf8))
        }
        let created = try await api.createTripPhoto(tripID: "t1", CreatePhotoRequest(lat: 1, lng: 2, takenAt: nil, contentType: .heic))
        #expect(created.upload.fields["key"] == "trips/t1/p")
        #expect(StubURLProtocol.requests.first?.url?.path() == "/trips/t1/photos")
    }

    @Test func deleteTripPhotoTreatsOnlyPhotoNotFoundAsDone() async throws {
        StubURLProtocol.install { _ in (404, Data(#"{"error":"photo not found"}"#.utf8)) }
        try await api.deleteTripPhoto(tripID: "t1", photoID: "p")
        #expect(StubURLProtocol.requests.first?.url?.path() == "/trips/t1/photos/p")
        #expect(StubURLProtocol.requests.first?.httpMethod == "DELETE")

        StubURLProtocol.install { _ in (404, Data(#"{"error":"trip not found"}"#.utf8)) }
        await #expect(throws: APIError.http(status: 404, message: "trip not found")) {
            try await api.deleteTripPhoto(tripID: "t1", photoID: "p")
        }
        StubURLProtocol.install { _ in (403, Data(#"{"error":"only the person who uploaded a photo can delete it"}"#.utf8)) }
        await #expect(throws: APIError.http(status: 403, message: "only the person who uploaded a photo can delete it")) {
            try await api.deleteTripPhoto(tripID: "t1", photoID: "p")
        }
    }

    @Test func getTripAndListTrips() async throws {
        let trip = #"{"id":"t1","name":"N","startDate":"2026-10-01","endDate":"2026-10-06","createdBy":"u","createdAt":"2026-10-01T00:00:00Z"}"#
        StubURLProtocol.install { request in
            (200, Data((request.url?.path() == "/trips" ? #"{"trips":[\#(trip)]}"# : trip).utf8))
        }
        #expect(try await api.listTrips().map(\.id) == ["t1"])
        #expect(try await api.getTrip(id: "t1").endDate == CalendarDate("2026-10-06"))
        #expect(StubURLProtocol.requests.map { $0.url?.path() } == ["/trips", "/trips/t1"])
    }
}
