import CoreLocation
import Foundation
import ImageIO
import MapKit
import Testing
import UniformTypeIdentifiers
@testable import PictureWare

@Suite("Location extraction")
struct LocationExtractorTests {
    @Test("GPS reference letters set the sign", arguments: [
        ("N", "E", 37.8199, 122.4783),
        ("N", "W", 37.8199, -122.4783),
        ("S", "E", -33.8568, 151.2153),
        ("S", "W", -22.9519, -43.2105),
    ])
    func gpsHemispheres(latRef: String, lngRef: String, expectedLat: Double, expectedLng: Double) throws {
        let data = TestFixtures.image(gps: TestFixtures.gps(lat: abs(expectedLat), latRef: latRef,
                                                          lng: abs(expectedLng), lngRef: lngRef))
        let location = try #require(LocationExtractor.metadata(from: data).location)
        #expect(abs(location.latitude - expectedLat) < 1e-4)
        #expect(abs(location.longitude - expectedLng) < 1e-4)
    }

    @Test func noGPS() {
        let data = TestFixtures.image()
        #expect(LocationExtractor.metadata(from: data) == .init(location: nil, takenAt: nil))
    }

    @Test func notAnImage() {
        #expect(LocationExtractor.metadata(from: Data("hello".utf8)).location == nil)
    }

    @Test func heicWithGPS() throws {
        let data = TestFixtures.image(type: .heic, gps: TestFixtures.gps(lat: 48.8584, latRef: "N", lng: 2.2945, lngRef: "E"))
        let location = try #require(LocationExtractor.metadata(from: data).location)
        #expect(abs(location.latitude - 48.8584) < 1e-4)
        #expect(abs(location.longitude - 2.2945) < 1e-4)
    }

    @Test func dateTimeOriginalWithOffset() throws {
        let data = TestFixtures.image(
            gps: TestFixtures.gps(lat: 1, latRef: "N", lng: 1, lngRef: "E"),
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:09:01 12:00:00",
                   kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]
        )
        let takenAt = try #require(LocationExtractor.metadata(from: data).takenAt)
        #expect(takenAt == Date(timeIntervalSince1970: 1_788_256_800)) // 10:00 UTC
    }

    @Test func dateTimeOriginalWithoutOffsetUsesDefaultZone() throws {
        let data = TestFixtures.image(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:09:01 10:00:00"])
        let takenAt = try #require(LocationExtractor.metadata(from: data, defaultTimeZone: TimeZone(identifier: "UTC")!).takenAt)
        #expect(takenAt == Date(timeIntervalSince1970: 1_788_256_800))
    }

    @Test func nullIslandIsRejected() {
        let data = TestFixtures.image(gps: TestFixtures.gps(lat: 0, latRef: "N", lng: 0, lngRef: "E"))
        #expect(LocationExtractor.metadata(from: data).location == nil)
    }
}

@Suite("Upload preparation")
struct UploadPreparationTests {
    @Test func jpegPassesThrough() throws {
        let data = TestFixtures.image(type: .jpeg)
        let (out, type) = try UploadPreparation.encode(data, declaredType: .jpeg)
        #expect(type == .jpeg)
        #expect(out == data)
    }

    @Test func heicPassesThrough() throws {
        let data = TestFixtures.image(type: .heic)
        let (out, type) = try UploadPreparation.encode(data, declaredType: .heic)
        #expect(type == .heic)
        #expect(out == data)
    }

    @Test func pngIsReencodedAsJPEG() throws {
        let png = TestFixtures.image(type: .png, gps: TestFixtures.gps(lat: 37.8199, latRef: "N", lng: 122.4783, lngRef: "W"))
        // Location is read before re-encoding and kept even if the JPEG loses metadata.
        let location = LocationExtractor.metadata(from: png).location
        let (out, type) = try UploadPreparation.encode(png, declaredType: .png)
        #expect(type == .jpeg)
        let source = try #require(CGImageSourceCreateWithData(out as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(location == GeoPoint(latitude: 37.8199, longitude: -122.4783))
    }

    @Test func garbageIsRejected() {
        #expect(throws: UploadPreparationError.unreadableImage) {
            try UploadPreparation.encode(Data("nope".utf8), declaredType: .png)
        }
    }
}

@Suite("Map fitting")
struct MapFitTests {
    @Test func noPins() {
        #expect(MapFit.rect(for: []) == nil)
    }

    @Test func containsAllPins() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783),
            CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
        ]
        let rect = try #require(MapFit.rect(for: coordinates))
        for coordinate in coordinates {
            #expect(rect.contains(MKMapPoint(coordinate)))
        }
    }

    @Test func singlePinGetsMinimumSize() throws {
        let rect = try #require(MapFit.rect(for: [CLLocationCoordinate2D(latitude: 37.8199, longitude: -122.4783)]))
        let widthMeters = rect.width / MKMapPointsPerMeterAtLatitude(37.8199)
        #expect(widthMeters >= 2000)
    }
}
