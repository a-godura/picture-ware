#if DEBUG
import MapKit
import SwiftUI
import UIKit

/// Offline sample data for previews, tests and the `-PWSampleMap` launch argument: a
/// three-person trip through Lisbon, Sintra and Porto with locally rendered images, so the map
/// experience can be tried with no backend and no sign-in.
enum SampleTrip {
    struct Spot { let name: String; let lat: Double; let lng: Double; let day: Int; let hour: Double }

    static let spots: [Spot] = [
        Spot(name: "Belém Tower", lat: 38.6916, lng: -9.2160, day: 0, hour: 10),
        Spot(name: "Jerónimos", lat: 38.6979, lng: -9.2068, day: 0, hour: 12),
        Spot(name: "LX Factory", lat: 38.7033, lng: -9.1784, day: 0, hour: 16),
        Spot(name: "Praça do Comércio", lat: 38.7075, lng: -9.1364, day: 1, hour: 10),
        Spot(name: "Alfama", lat: 38.7114, lng: -9.1303, day: 1, hour: 13),
        Spot(name: "Senhora do Monte", lat: 38.7193, lng: -9.1329, day: 1, hour: 19),
        Spot(name: "Pena Palace", lat: 38.7876, lng: -9.3906, day: 2, hour: 11),
        Spot(name: "Quinta da Regaleira", lat: 38.7963, lng: -9.3961, day: 2, hour: 14),
        Spot(name: "Cabo da Roca", lat: 38.7804, lng: -9.4989, day: 2, hour: 18),
        Spot(name: "Livraria Lello", lat: 41.1468, lng: -8.6149, day: 3, hour: 11),
        Spot(name: "Ribeira", lat: 41.1406, lng: -8.6131, day: 3, hour: 15),
        Spot(name: "Dom Luís I Bridge", lat: 41.1399, lng: -8.6094, day: 3, hour: 20),
        Spot(name: "Foz do Douro", lat: 41.1496, lng: -8.6765, day: 4, hour: 17),
    ]

    static let uploaders = ["ana": "Ana", "ben": "Ben", "chloe": "Chloé"]
    static let start = Date(timeIntervalSince1970: 1_788_220_800) // 2026-09-01 00:00 UTC

    /// `count` photos spread over the spots in capture order. Every 4th photo at a spot is
    /// taken at exactly the same place as the previous one (a burst); the last `undated`
    /// photos have no capture time.
    static func photos(count: Int = 60, undated: Int = 3, imageURL: (Int) -> URL = placeholderURL) -> [Photo] {
        var rng = SplitMix(seed: 11)
        return (0..<count).map { i in
            let spotIndex = i * spots.count / count
            let spot = spots[spotIndex]
            let burst = i % 4 == 3
            let jitter = burst ? 0 : 0.0012
            let lat = spot.lat + (rng.unit() - 0.5) * jitter, lng = spot.lng + (rng.unit() - 0.5) * jitter
            let taken = start.addingTimeInterval(Double(spot.day) * 86_400 + spot.hour * 3600 + Double(i) * 240)
            return Photo(
                id: String(format: "sample-%04d", i),
                lat: burst ? spot.lat : lat,
                lng: burst ? spot.lng : lng,
                takenAt: i >= count - undated ? nil : taken,
                createdAt: start.addingTimeInterval(7 * 86_400 + Double(i)),
                imageUrl: imageURL(spotIndex)
            )
        }
    }

    /// The sample uploader of a sample photo: runs of a few photos each, rotating through
    /// everyone, like friends taking turns with the camera.
    static func uploader(of photo: Photo) -> String? {
        guard let index = Int(photo.id.dropFirst("sample-".count)) else { return nil }
        let keys = uploaders.keys.sorted()
        return keys[(index / 3 + index / 7) % keys.count]
    }

    static func placeholderURL(_ index: Int) -> URL { URL(string: "https://example.invalid/\(index).jpg")! }

    /// Renders one JPEG per spot into Caches (once) and returns its file URL.
    static func renderedImageURL(_ index: Int) -> URL {
        let dir = URL.cachesDirectory.appending(path: "SampleTrip", directoryHint: .isDirectory)
        let url = dir.appending(path: "spot-\(index).jpg")
        if FileManager.default.fileExists(atPath: url.path()) { return url }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hue = CGFloat(index) / CGFloat(spots.count)
        let size = CGSize(width: 600, height: 450)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.08, saturation: 0.8, brightness: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let text = spots[index].name as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .bold), .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
        try? image.jpegData(compressionQuality: 0.8)?.write(to: url)
        return url
    }

    /// Deterministic generator so the sample trip looks the same every run.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}

/// The map screen on sample data (DEBUG only). Launch with `-PWSampleMap YES`; optional
/// `-PWSampleCount <n>` and `-PWSampleState replay|browse|filter` for screenshots.
struct SampleTripMapScreen: View {
    @State private var experience = MapExperience(uploaderKey: SampleTrip.uploader(of:),
                                                  uploaderName: { SampleTrip.uploaders[$0] ?? $0 })
    @State private var position: MapCameraPosition = .automatic
    var count = UserDefaults.standard.integer(forKey: "PWSampleCount")
    var state = UserDefaults.standard.string(forKey: "PWSampleState")

    var body: some View {
        TripMap(experience: experience, position: $position) { photo in
            experience.photos.removeAll { $0.id == photo.id }
        }
        .overlay(alignment: .bottom) {
            TimelineBar(experience: experience).padding()
        }
        .task {
            let photos = SampleTrip.photos(count: count > 0 ? count : 60, imageURL: SampleTrip.renderedImageURL)
            experience.photos = photos
            if let rect = MapFit.rect(for: photos.filter { $0.lat < 39 }.map(\.coordinate)) {
                position = .rect(rect)
            }
            switch state {
            case "replay":
                experience.isTimelineOpen = true
                experience.cutoff = experience.timeline.range.map { $0.date(atFraction: 0.3) }
            case "browse":
                experience.browsing = .init(photos: experience.visible, startID: experience.visible[5].id)
            case "filter":
                experience.uploaderFilter.hidden = [.uploader("ben")]
            default: break
            }
        }
    }
}

#Preview("Sample trip") {
    SampleTripMapScreen()
}

#Preview("1,000 photos") {
    SampleTripMapScreen(count: 1000)
}

#Preview("Replay") {
    SampleTripMapScreen(state: "replay")
}

#Preview("Swipe viewer") {
    let photos = SampleTrip.photos(count: 8, imageURL: SampleTrip.renderedImageURL)
    PhotoBrowser(photos: photos, startID: photos[2].id) { _ in }
}

#Preview("Cluster pins") {
    let photos = SampleTrip.photos(count: 12, undated: 0, imageURL: SampleTrip.renderedImageURL)
    HStack(spacing: 24) {
        ClusterPin(cluster: MapCluster(id: "a", coordinate: photos[0].coordinate, members: [photos[0]]))
        ClusterPin(cluster: MapCluster(id: "b", coordinate: photos[0].coordinate, members: Array(photos.prefix(7))))
        ClusterPin(cluster: MapCluster(id: "c", coordinate: photos[0].coordinate, members: photos + photos + photos))
    }
    .padding(40)
}
#endif
