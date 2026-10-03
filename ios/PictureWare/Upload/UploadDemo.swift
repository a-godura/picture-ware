#if DEBUG
import ImageIO
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// DEBUG-only screen for trying bulk upload without a backend or sign-in.
///
/// Launch with `-UploadDemo`. Add `-UploadDemoServer http://127.0.0.1:8765` to send the files
/// through the real background `URLSession` to a local test server; without it, a simulated
/// transport is used. The fake API fails some calls on purpose so retries are visible.
enum UploadDemo {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-UploadDemo") }
    static var serverURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-UploadDemoServer"), index + 1 < arguments.count else { return nil }
        return URL(string: arguments[index + 1])
    }

    @MainActor static let center: UploadCenter = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = UploadStore(directory: base.appending(path: "UploadsDemo", directoryHint: .isDirectory))
        let transport: any UploadTransport = serverURL == nil ? SimulatedTransport() : BackgroundUploadTransport.shared
        let center = UploadCenter(transport: transport, store: store)
        center.activate(backend: DemoBackend(server: serverURL ?? URL(string: "https://storage.invalid")!))
        return center
    }()
}

/// Fake API: hands out presigns for the demo server. Every 4th create fails once with a 503.
actor DemoBackend: UploadBackend {
    let server: URL
    private var calls = 0

    init(server: URL) { self.server = server }

    func createPhoto(_ request: CreatePhotoRequest) async throws -> CreatePhotoResponse {
        calls += 1
        try await Task.sleep(for: .milliseconds(300))
        if calls % 4 == 0 { throw APIError.http(status: 503, message: "demo: service unavailable") }
        let id = UUID().uuidString.lowercased()
        return CreatePhotoResponse(id: id, upload: UploadTarget(
            url: server.appending(path: "upload"),
            fields: ["key": "photos/demo/\(id)", "Content-Type": request.contentType.rawValue, "policy": "demo"]
        ))
    }

    func isPhotoListed(id: String) async throws -> Bool { false }
}

/// Pretends to upload: ~2 s of progress; the 3rd upload gets a 403 (expired presign) once and
/// the 5th a 500 once.
actor SimulatedTransport: UploadTransport {
    private var uploads = 0

    func attach(itemID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int? { nil }

    func upload(itemID: String, bodyFile: URL, contentType: String, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        uploads += 1
        let number = uploads
        for step in 1...10 {
            try await Task.sleep(for: .milliseconds(200))
            progress(Double(step) / 10)
        }
        switch number {
        case 3: return 403
        case 5: return 500
        default: return 204
        }
    }

    func cancel(itemID: String) async {}
}

struct UploadDemoView: View {
    private let uploads = UploadDemo.center
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(uploads.items.filter { $0.status == .done }) { item in
                Marker("", systemImage: "photo", coordinate: CLLocationCoordinate2D(latitude: item.lat, longitude: item.lng))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            Text(UploadDemo.serverURL.map { "Upload demo → \($0.host() ?? "")" } ?? "Upload demo (simulated)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                UploadPanel(uploads: uploads)
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button("Samples", systemImage: "wand.and.stars") {
                        Task { await uploads.importCandidates(DemoSamples.candidates()) }
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Add sample photos")
                    AddPhotosButton(uploads: uploads)
                }
            }
            .padding()
        }
    }
}

/// Eight photos with GPS around Lisbon, one without a location, and a repeat of the first.
enum DemoSamples {
    static func candidates() -> [ImportCandidate] {
        let seed = Int.random(in: 0..<1_000_000)
        var images: [Data] = (0..<8).map { index in
            image(hue: Double(index) / 8, seed: seed + index,
                  lat: 38.70 + Double(index % 4) * 0.012, lng: -9.16 + Double(index / 4) * 0.02)
        }
        images.insert(image(hue: 0.5, seed: seed + 99, lat: nil, lng: nil), at: 4)
        images.append(images[0])
        return images.map { data in
            ImportCandidate(identifier: nil, declaredType: .jpeg, load: { data })
        }
    }

    static func image(hue: Double, seed: Int, lat: Double?, lng: Double?) -> Data {
        let width = 1600, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<400 {
            let color = UIColor(hue: (hue + Double.random(in: -0.08...0.08, using: &generator) + 1).truncatingRemainder(dividingBy: 1),
                                saturation: 0.6, brightness: Double.random(in: 0.4...1, using: &generator), alpha: 1)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: Double.random(in: 0...Double(width), using: &generator),
                                           y: Double.random(in: 0...Double(height), using: &generator),
                                           width: 160, height: 160))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let lat, let lng {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(lng), kCGImagePropertyGPSLongitudeRef: lng < 0 ? "W" : "E",
            ]
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
#endif
