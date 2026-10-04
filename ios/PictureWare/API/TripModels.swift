import CoreLocation
import Foundation

/// A calendar day (`YYYY-MM-DD`, OpenAPI `format: date`), with no time or time zone.
struct CalendarDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = Calendar(identifier: .gregorian)
        guard (1...9999).contains(year), components.isValidDate else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly `YYYY-MM-DD`.
    init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let date = CalendarDate(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Expected a date like 2026-10-03, got \(string)"))
        }
        self = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// `POST /trips` body.
struct CreateTripRequest: Encodable, Sendable, Equatable {
    let name: String
    let startDate: CalendarDate
    /// Omitted (not null) when the trip has no end date yet.
    let endDate: CalendarDate?
}

/// A trip the caller is a member of.
struct Trip: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let startDate: CalendarDate
    /// `nil` while the trip is open-ended.
    let endDate: CalendarDate?
    /// User id (Cognito sub) of the creator.
    let createdBy: String
    let createdAt: Date
}

/// `GET /trips` response.
struct TripList: Decodable, Sendable {
    let trips: [Trip]
}

/// A photo in a trip, from any member.
struct TripPhoto: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let takenAt: Date?
    let createdAt: Date
    /// User id (Cognito sub) of the member who uploaded it.
    let uploaderId: String
    let imageUrl: URL

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// One page of `GET /trips/{tripId}/photos`.
struct TripPhotoPage: Decodable, Sendable {
    let photos: [TripPhoto]
    /// Pass as `cursor` for the next page; `nil` on the last page.
    let nextCursor: String?
}
