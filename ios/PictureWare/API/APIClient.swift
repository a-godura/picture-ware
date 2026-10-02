import Foundation

enum APIError: LocalizedError, Equatable {
    case unauthorized
    case http(status: Int, message: String?)
    case uploadFailed(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session expired. Please sign in again."
        case .http(let status, let message): message.map { "Server error (\(status)): \($0)" } ?? "Server error (\(status))."
        case .uploadFailed(403): "Upload rejected by storage (the upload link may have expired). Please try again."
        case .uploadFailed(let status): "Upload failed (HTTP \(status))."
        case .invalidResponse: "Unexpected response from the server."
        }
    }
}

/// picture-ware HTTP API client (see backend/API.md).
struct APIClient: Sendable {
    static let maxUploadBytes = 15 * 1024 * 1024

    let baseURL: URL
    let tokens: any AccessTokenProvider
    var session: URLSession = .shared

    func listPhotos() async throws -> [Photo] {
        let data = try await send(request(path: "photos", method: "GET"))
        return try APICoding.decoder().decode(PhotoList.self, from: data).photos
    }

    func createPhoto(_ body: CreatePhotoRequest) async throws -> CreatePhotoResponse {
        var request = request(path: "photos", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try APICoding.encoder().encode(body)
        let data = try await send(request, expecting: 201)
        return try APICoding.decoder().decode(CreatePhotoResponse.self, from: data)
    }

    /// Deletes one of the user's photos. The backend's own 404 means it's already gone, which is what
    /// the caller wanted; any other 404 (e.g. API Gateway's "Not Found" for a missing route) is an error.
    func deletePhoto(id: String) async throws {
        do {
            _ = try await send(request(path: "photos/\(id)", method: "DELETE"), expecting: 204)
        } catch APIError.http(status: 404, message: "photo not found") {
        }
    }

    /// Uploads the file to the presigned S3 POST. No bearer token: S3 authorizes via the policy fields.
    func upload(_ file: Data, contentType: PhotoContentType, to target: UploadTarget,
                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let form = MultipartFormBody.s3Upload(
            fields: target.fields, file: file,
            filename: "photo.\(contentType.fileExtension)", contentType: contentType.rawValue
        )
        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let delegate = progress.map(UploadProgressDelegate.init)
        let (_, response) = try await session.upload(for: request, from: form.finalized(), delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.uploadFailed(status: http.statusCode) }
    }

    // MARK: - Private

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Sends with a bearer token. On 401: refresh once and retry; if still 401, sign out.
    private func send(_ request: URLRequest, expecting expected: Int = 200) async throws -> Data {
        var (data, status) = try await perform(request, token: tokens.validAccessToken())
        if status == 401 {
            let fresh: String
            do {
                fresh = try await tokens.refreshedAccessToken()
            } catch AuthError.sessionExpired {
                throw APIError.unauthorized
            }
            (data, status) = try await perform(request, token: fresh)
            if status == 401 {
                await tokens.sessionExpired()
                throw APIError.unauthorized
            }
        }
        guard status == expected else {
            // Lambda errors are {"error": ...}; API Gateway's own are {"message": ...}.
            let body = try? JSONDecoder().decode([String: String].self, from: data)
            let message = body?["error"] ?? body?["message"]
            throw APIError.http(status: status, message: message)
        }
        return data
    }

    private func perform(_ request: URLRequest, token: String) async throws -> (Data, Int) {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http.statusCode)
    }
}

/// Reports upload progress as a 0...1 fraction.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(_ onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
