import CoreLocation
import Foundation

enum PhotoContentType: String, Codable, Sendable {
    case jpeg = "image/jpeg"
    case heic = "image/heic"

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
}

/// `POST /photos` body.
struct CreatePhotoRequest: Encodable, Sendable, Equatable {
    let lat: Double
    let lng: Double
    let takenAt: Date?
    let contentType: PhotoContentType
}

/// `POST /photos` 201 response.
struct CreatePhotoResponse: Decodable, Sendable, Equatable {
    let id: String
    let upload: UploadTarget
}

/// Presigned S3 POST.
struct UploadTarget: Decodable, Sendable, Equatable {
    let url: URL
    let fields: [String: String]
}

/// `GET /photos` response.
struct PhotoList: Decodable, Sendable {
    let photos: [Photo]
}

struct Photo: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let lat: Double
    let lng: Double
    let takenAt: Date?
    let createdAt: Date
    let imageUrl: URL

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// RFC 3339 coding shared by requests and responses.
enum APICoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an RFC 3339 timestamp, got \(string)"
            ))
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601))
        }
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// Accepts RFC 3339 with or without fractional seconds (Go emits either).
    static func parseDate(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
}
