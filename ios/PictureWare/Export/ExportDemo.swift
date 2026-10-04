#if DEBUG
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// DEBUG-only harness for trying export without a backend or sign-in.
///
/// Launch with `-PWExportDemo YES` to show a list of generated sample photos (real JPEG/HEIC files
/// with EXIF date + GPS, served from `file://` URLs) and run the real downloader, PhotoKit saver
/// and Files exporter against them. Add `-PWExportDemoFail YES` to make one photo fail its first
/// download (as if its link had expired) to exercise retry.
enum ExportDemo {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "PWExportDemo") }
    static var injectsFailure: Bool { UserDefaults.standard.bool(forKey: "PWExportDemoFail") }

    struct Sample {
        let name: String
        let lat: Double
        let lng: Double
        /// EXIF DateTimeOriginal (local time at `offset`).
        let exifDate: String
        let offset: String
        let takenAt: Date
        let type: UTType
        /// false: the file has no GPS/date, so the saver must fill them in from the API fields.
        let embedsMetadata: Bool
        let hue: Double
    }

    static let samples: [Sample] = [
        Sample(name: "Golden Gate", lat: 37.8199, lng: -122.4783, exifDate: "2026:07:04 18:30:00", offset: "-07:00",
               takenAt: date("2026-07-04T18:30:00-07:00"), type: .jpeg, embedsMetadata: true, hue: 0.02),
        Sample(name: "Eiffel Tower", lat: 48.8584, lng: 2.2945, exifDate: "2026:08:12 21:05:10", offset: "+02:00",
               takenAt: date("2026-08-12T21:05:10+02:00"), type: .heic, embedsMetadata: true, hue: 0.6),
        Sample(name: "Sydney Opera House", lat: -33.8568, lng: 151.2153, exifDate: "2026:01:26 09:15:00", offset: "+11:00",
               takenAt: date("2026-01-26T09:15:00+11:00"), type: .jpeg, embedsMetadata: true, hue: 0.12),
        Sample(name: "Christ the Redeemer", lat: -22.9519, lng: -43.2105, exifDate: "2026:03:01 07:45:00", offset: "-03:00",
               takenAt: date("2026-03-01T07:45:00-03:00"), type: .jpeg, embedsMetadata: true, hue: 0.33),
        Sample(name: "Mount Fuji (no EXIF)", lat: 35.3606, lng: 138.7274, exifDate: "", offset: "",
               takenAt: date("2026-05-05T05:30:00+09:00"), type: .jpeg, embedsMetadata: false, hue: 0.8),
    ]

    private static func date(_ string: String) -> Date { APICoding.parseDate(string)! }

    /// Writes the sample files (once) and returns them as API `Photo`s with file URLs.
    static func photos() throws -> [Photo] {
        let directory = URL.applicationSupportDirectory.appending(path: "ExportDemo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try samples.enumerated().map { index, sample in
            let url = directory.appending(path: "sample-\(index + 1).\(sample.type == .heic ? "heic" : "jpg")")
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try image(for: sample, number: index + 1).write(to: url)
            }
            return Photo(id: "demo-\(index + 1)-\(sample.name.prefix(6).lowercased().filter(\.isLetter))",
                         lat: sample.lat, lng: sample.lng, takenAt: sample.takenAt,
                         createdAt: sample.takenAt.addingTimeInterval(3600), imageUrl: url)
        }
    }

    private static func image(for sample: Sample, number: Int) throws -> Data {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(hue: sample.hue, saturation: 0.7, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: sample.hue + 0.1, saturation: 0.8, brightness: 0.45, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            let title = "#\(number) \(sample.name)" as NSString
            title.draw(at: CGPoint(x: 80, y: 900), withAttributes: [
                .font: UIFont.systemFont(ofSize: 96, weight: .bold), .foregroundColor: UIColor.white,
            ])
            let subtitle = (sample.embedsMetadata ? "EXIF \(sample.exifDate) \(sample.offset)" : "No EXIF date/GPS in file") as NSString
            subtitle.draw(at: CGPoint(x: 84, y: 1030), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .regular), .foregroundColor: UIColor.white,
            ])
        }
        guard let cgImage = rendered.cgImage else { throw ExportError.notAnImage }

        var properties: [CFString: Any] = [:]
        if sample.embedsMetadata {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: sample.exifDate,
                kCGImagePropertyExifDateTimeDigitized: sample.exifDate,
                kCGImagePropertyExifOffsetTimeOriginal: sample.offset,
            ]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(sample.lat),
                kCGImagePropertyGPSLatitudeRef: sample.lat < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(sample.lng),
                kCGImagePropertyGPSLongitudeRef: sample.lng < 0 ? "W" : "E",
            ]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFModel: "Picture Ware Sample Camera"]
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, sample.type.identifier as CFString, 1, nil)
        else { throw ExportError.notAnImage }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.notAnImage }
        return output as Data
    }
}

/// The real downloader, slowed down so progress is visible, optionally failing one photo once.
private actor DemoDownloader: PhotoDownloading {
    private let live = URLSessionPhotoDownloader()
    private var failuresLeft = ExportDemo.injectsFailure ? 1 : 0

    func download(_ photo: Photo) async throws -> DownloadedPhoto {
        try await Task.sleep(for: .milliseconds(700))
        if photo.id.hasPrefix("demo-3"), failuresLeft > 0 {
            failuresLeft -= 1
            throw ExportError.linkExpired
        }
        return try await live.download(photo)
    }
}

struct ExportDemoView: View {
    @State private var photos: [Photo] = []
    @State private var export = ExportModel(fetchPhotos: { try ExportDemo.photos() }, downloader: DemoDownloader())
    @State private var showingExport = false
    @State private var selected: Photo?

    var body: some View {
        NavigationStack {
            List(photos) { photo in
                Button { selected = photo } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: photo.imageUrl) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color.secondary.opacity(0.2) }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(photo.imageUrl.lastPathComponent).font(.headline)
                            Text(photo.takenAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Export Demo")
            .toolbar {
                Button("Save All Photos…", systemImage: "square.and.arrow.down.on.square") { showingExport = true }
            }
            .sheet(isPresented: $showingExport) {
                ExportView(model: export, photoCount: photos.count)
            }
            .sheet(item: $selected) { photo in
                // The map's swipe viewer, as on the real map screen.
                PhotoBrowser(photos: photos, startID: photo.id) { _ in
                    throw ExportError.downloadFailed(status: 0) // no deleting in the demo
                }
            }
            .environment(\.exportModel, export)
            .task { photos = (try? ExportDemo.photos()) ?? [] }
        }
    }
}
#endif
