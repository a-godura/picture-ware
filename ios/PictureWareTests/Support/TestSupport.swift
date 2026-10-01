import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PictureWare

/// URLProtocol stub. Tests using it live in the `.serialized` `NetworkTests` suite,
/// since the handler is process-global.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Data(reading: stream)
        }
        let handler = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            append(buffer, count: count)
        }
    }
}

extension URLRequest {
    var bodyString: String { httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// Parses an `application/x-www-form-urlencoded` body.
    var formFields: [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = bodyString
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }

    var current: AuthTokens? { lock.withLock { tokens } }
    func load() throws -> AuthTokens? { current }
    func save(_ tokens: AuthTokens) throws { lock.withLock { self.tokens = tokens } }
    func clear() throws { lock.withLock { tokens = nil } }
}

/// Plays the browser: answers the authorize URL with a redirect carrying `code` and the same `state`.
@MainActor
final class FakeWebAuthenticator: WebAuthenticator {
    var openedURLs: [URL] = []
    var code = "auth-code-123"

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        openedURLs.append(url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.path().hasSuffix("/logout") {
            return URL(string: "picture-ware://auth/signout")!
        }
        let state = items.first { $0.name == "state" }?.value ?? ""
        return URL(string: "picture-ware://auth/callback?code=\(code)&state=\(state)")!
    }
}

enum TestFixtures {
    static let config = AppConfig(
        apiURL: URL(string: "https://api.example.com")!,
        authDomain: URL(string: "https://pw.auth.us-east-2.amazoncognito.com")!,
        clientID: "client123"
    )

    static func tokenJSON(access: String, refresh: String? = nil, expiresIn: Int = 3600) -> Data {
        var object: [String: Any] = [
            "access_token": access, "id_token": "id-\(access)", "token_type": "Bearer", "expires_in": expiresIn,
        ]
        if let refresh { object["refresh_token"] = refresh }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A small image written with ImageIO, optionally carrying GPS and EXIF dictionaries.
    static func image(type: UTType = .jpeg, gps: [CFString: Any]? = nil, exif: [CFString: Any]? = nil) -> Data {
        let width = 8, height = 8
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let gps { properties[kCGImagePropertyGPSDictionary] = gps }
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func gps(lat: Double, latRef: String, lng: Double, lngRef: String) -> [CFString: Any] {
        [
            kCGImagePropertyGPSLatitude: lat,
            kCGImagePropertyGPSLatitudeRef: latRef,
            kCGImagePropertyGPSLongitude: lng,
            kCGImagePropertyGPSLongitudeRef: lngRef,
        ]
    }
}
