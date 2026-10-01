import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GeoPoint: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0)
    }
}

/// Reads GPS position and capture time from image metadata (EXIF/GPS) with ImageIO.
enum LocationExtractor {
    struct Metadata: Sendable, Equatable {
        var location: GeoPoint?
        var takenAt: Date?
    }

    static func metadata(from data: Data, defaultTimeZone: TimeZone = .current) -> Metadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return Metadata() }
        return metadata(fromProperties: properties, defaultTimeZone: defaultTimeZone)
    }

    static func metadata(fromProperties properties: [CFString: Any], defaultTimeZone: TimeZone = .current) -> Metadata {
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return Metadata(
            location: gps.flatMap(location(fromGPS:)),
            takenAt: exif.flatMap { captureDate(fromExif: $0, defaultTimeZone: defaultTimeZone) }
        )
    }

    /// EXIF stores unsigned degrees plus N/S and E/W reference letters.
    static func location(fromGPS gps: [CFString: Any]) -> GeoPoint? {
        guard let lat = number(gps[kCGImagePropertyGPSLatitude]),
              let lng = number(gps[kCGImagePropertyGPSLongitude])
        else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let lngRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        let point = GeoPoint(
            latitude: latRef == "S" ? -abs(lat) : (latRef == "N" ? abs(lat) : lat),
            longitude: lngRef == "W" ? -abs(lng) : (lngRef == "E" ? abs(lng) : lng)
        )
        return point.isValid ? point : nil
    }

    /// `DateTimeOriginal` ("yyyy:MM:dd HH:mm:ss") with `OffsetTimeOriginal` ("+02:00") when present.
    static func captureDate(fromExif exif: [CFString: Any], defaultTimeZone: TimeZone) -> Date? {
        guard let raw = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(timeZone(fromOffset:))
            ?? defaultTimeZone
        return formatter.date(from: raw)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        // "+05:30" / "-08:00"
        let parts = offset.dropFirst().split(separator: ":")
        guard let sign = offset.first, sign == "+" || sign == "-", parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1])
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }
}
