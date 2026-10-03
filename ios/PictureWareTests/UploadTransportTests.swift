import Foundation
import Testing
@testable import PictureWare

/// `BackgroundUploadTransport`'s bookkeeping, driven through `StubURLProtocol`. A real background
/// session can't use custom protocol classes, so this uses an ephemeral configuration; the
/// delegate code paths (matching tasks by `taskDescription`, status, progress) are the same.
/// These live in the serialized `NetworkTests` suite because the stub handler is process-global.
extension NetworkTests {
    private func transport() -> BackgroundUploadTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return BackgroundUploadTransport(configuration: configuration)
    }

    private func bodyFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "body-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func transportPostsTheBodyFile() async throws {
        StubURLProtocol.install { _ in (204, Data()) }
        let status = try await transport().upload(
            itemID: "item-1", bodyFile: bodyFile("multipart-body"), contentType: "multipart/form-data; boundary=X",
            to: URL(string: "https://bucket.example.com")!, progress: { _ in }
        )
        #expect(status == 204)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.host() == "bucket.example.com")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=X")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.bodyString == "multipart-body")
    }

    @Test func transportReturnsStorageStatus() async throws {
        StubURLProtocol.install { _ in (403, Data("<Error><Code>AccessDenied</Code></Error>".utf8)) }
        let status = try await transport().upload(
            itemID: "item-1", bodyFile: bodyFile("x"), contentType: "multipart/form-data; boundary=X",
            to: URL(string: "https://bucket.example.com")!, progress: { _ in }
        )
        #expect(status == 403)
    }

    @Test func transportSurfacesConnectionErrors() async throws {
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let transport = transport()
        let file = try bodyFile("x")
        await #expect(throws: URLError.self) {
            try await transport.upload(
                itemID: "item-1", bodyFile: file, contentType: "multipart/form-data; boundary=X",
                to: URL(string: "https://bucket.example.com")!, progress: { _ in }
            )
        }
    }

    @Test func transportHasNothingToAttachToForUnknownItems() async throws {
        #expect(try await transport().attach(itemID: "nope", progress: { _ in }) == nil)
    }

    @Test func eventsCompletionHandlerRunsEvenIfEventsFinishedFirst() async throws {
        let transport = transport()
        transport.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        await withCheckedContinuation { continuation in
            transport.setEventsCompletionHandler { continuation.resume() }
        }
    }
}
