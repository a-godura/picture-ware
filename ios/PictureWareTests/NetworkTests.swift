import Foundation
import Testing
@testable import PictureWare

/// Token provider double for APIClient tests.
actor FakeTokenProvider: AccessTokenProvider {
    var token = "old-token"
    var refreshedToken = "new-token"
    private(set) var refreshCount = 0
    private(set) var expiredCount = 0

    func validAccessToken() async throws -> String { token }
    func refreshedAccessToken() async throws -> String {
        refreshCount += 1
        token = refreshedToken
        return token
    }
    func sessionExpired() async { expiredCount += 1 }
}

private let photosJSON = Data("""
{"photos":[{"id":"p1","lat":37.8199,"lng":-122.4783,"takenAt":null,"createdAt":"2026-10-01T18:00:00Z","imageUrl":"https://e.com/p1"}]}
""".utf8)

/// Everything that uses `StubURLProtocol` (a process-wide handler) runs serially here.
@Suite("Network", .serialized)
struct NetworkTests {
    let api: APIClient
    let tokens = FakeTokenProvider()

    init() {
        api = APIClient(baseURL: URL(string: "https://api.example.com")!, tokens: tokens, session: StubURLProtocol.session())
    }

    // MARK: APIClient

    @Test func listSendsBearerToken() async throws {
        StubURLProtocol.install { _ in (200, photosJSON) }
        let photos = try await api.listPhotos()
        #expect(photos.map(\.id) == ["p1"])
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.example.com/photos")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
    }

    @Test func unauthorizedRefreshesOnceAndRetries() async throws {
        StubURLProtocol.install { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token"
                ? (200, photosJSON)
                : (401, Data(#"{"message":"Unauthorized"}"#.utf8))
        }
        let photos = try await api.listPhotos()
        #expect(photos.count == 1)
        #expect(await tokens.refreshCount == 1)
        #expect(await tokens.expiredCount == 0)
        #expect(StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") } ==
            ["Bearer old-token", "Bearer new-token"])
    }

    @Test func secondUnauthorizedSignsOut() async throws {
        StubURLProtocol.install { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        await #expect(throws: APIError.unauthorized) { try await api.listPhotos() }
        #expect(await tokens.refreshCount == 1)
        #expect(await tokens.expiredCount == 1)
        #expect(StubURLProtocol.requests.count == 2)
    }

    @Test func serverErrorMessageIsSurfaced() async throws {
        StubURLProtocol.install { _ in (429, Data(#"{"message":"Too Many Requests"}"#.utf8)) }
        await #expect(throws: APIError.http(status: 429, message: "Too Many Requests")) { try await api.listPhotos() }
        #expect(await tokens.refreshCount == 0)
    }

    @Test func createPhotoPostsJSON() async throws {
        StubURLProtocol.install { _ in
            (201, Data(#"{"id":"abc","upload":{"url":"https://bucket.s3.amazonaws.com","fields":{"key":"photos/abc"}}}"#.utf8))
        }
        let response = try await api.createPhoto(CreatePhotoRequest(lat: 37.8199, lng: -122.4783, takenAt: nil, contentType: .jpeg))
        #expect(response.id == "abc")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["contentType"] as? String == "image/jpeg")
        #expect(body?["lat"] as? Double == 37.8199)
        #expect(body?["takenAt"] == nil)
    }

    @Test func deletePhotoSendsDelete() async throws {
        StubURLProtocol.install { _ in (204, Data()) }
        try await api.deletePhoto(id: "p1")
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.example.com/photos/p1")
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
    }

    @Test func deleteOfMissingPhotoSucceeds() async throws {
        StubURLProtocol.install { _ in (404, Data(#"{"error":"photo not found"}"#.utf8)) }
        try await api.deletePhoto(id: "gone")
    }

    @Test func deleteServerErrorIsSurfaced() async throws {
        StubURLProtocol.install { _ in (500, Data(#"{"error":"internal error"}"#.utf8)) }
        await #expect(throws: APIError.http(status: 500, message: "internal error")) { try await api.deletePhoto(id: "p1") }
    }

    @Test func uploadGoesToS3WithoutBearer() async throws {
        StubURLProtocol.install { _ in (204, Data()) }
        let target = UploadTarget(url: URL(string: "https://bucket.s3.amazonaws.com")!, fields: ["key": "photos/abc"])
        try await api.upload(Data([1, 2, 3]), contentType: .heic, to: target)
        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url == target.url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    @Test func uploadRejected() async throws {
        StubURLProtocol.install { _ in (403, Data("<Error><Code>AccessDenied</Code></Error>".utf8)) }
        let target = UploadTarget(url: URL(string: "https://bucket.s3.amazonaws.com")!, fields: [:])
        await #expect(throws: APIError.uploadFailed(status: 403)) {
            try await api.upload(Data([1]), contentType: .jpeg, to: target)
        }
    }

    // MARK: AuthService

    @Test @MainActor func signInExchangesCodeWithPKCE() async throws {
        StubURLProtocol.install { _ in (200, TestFixtures.tokenJSON(access: "a1", refresh: "r1")) }
        let store = InMemoryTokenStore()
        let web = FakeWebAuthenticator()
        let auth = AuthService(config: TestFixtures.config, store: store,
                               session: StubURLProtocol.session(), webAuthenticator: web)
        #expect(auth.state == .signedOut)

        await auth.signIn()

        #expect(auth.errorMessage == nil)
        #expect(auth.state == .signedIn)
        #expect(store.current?.accessToken == "a1")
        #expect(store.current?.refreshToken == "r1")

        // The verifier sent to /oauth2/token must hash to the challenge sent to /oauth2/authorize.
        let authorize = try #require(web.openedURLs.first)
        let query = URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let challenge = query.first { $0.name == "code_challenge" }?.value
        let tokenRequest = try #require(StubURLProtocol.requests.first)
        let form = tokenRequest.formFields
        #expect(tokenRequest.url?.path() == "/oauth2/token")
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "auth-code-123")
        #expect(form["client_id"] == "client123")
        #expect(PKCE.challenge(for: try #require(form["code_verifier"])) == challenge)
        #expect(try await auth.validAccessToken() == "a1")
    }

    @Test @MainActor func signInRefusedWithPlaceholderConfig() async {
        var config = TestFixtures.config
        config.clientID = "REPLACE_ME"
        let web = FakeWebAuthenticator()
        let auth = AuthService(config: config, store: InMemoryTokenStore(), webAuthenticator: web)
        await auth.signIn()
        #expect(auth.state == .signedOut)
        #expect(auth.errorMessage == AuthError.notConfigured.errorDescription)
        #expect(web.openedURLs.isEmpty)
    }

    @Test @MainActor func expiredAccessTokenIsRefreshed() async throws {
        StubURLProtocol.install { _ in (200, TestFixtures.tokenJSON(access: "a2")) } // no refresh_token in response
        let now = Date()
        let store = InMemoryTokenStore(AuthTokens(
            TokenResponse(accessToken: "a1", idToken: nil, refreshToken: "r1", tokenType: "Bearer", expiresIn: 30),
            receivedAt: now))
        let auth = AuthService(config: TestFixtures.config, store: store, session: StubURLProtocol.session(),
                               webAuthenticator: FakeWebAuthenticator(), now: { now })
        #expect(auth.state == .signedIn)

        #expect(try await auth.validAccessToken() == "a2")
        #expect(store.current?.refreshToken == "r1")
        #expect(StubURLProtocol.requests.first?.formFields["grant_type"] == "refresh_token")
        #expect(StubURLProtocol.requests.first?.formFields["refresh_token"] == "r1")
    }

    @Test @MainActor func revokedRefreshTokenSignsOut() async throws {
        StubURLProtocol.install { _ in (400, Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let store = InMemoryTokenStore(AuthTokens(
            TokenResponse(accessToken: "a1", idToken: nil, refreshToken: "r1", tokenType: "Bearer", expiresIn: 3600),
            receivedAt: .now))
        let auth = AuthService(config: TestFixtures.config, store: store, session: StubURLProtocol.session(),
                               webAuthenticator: FakeWebAuthenticator())
        await #expect(throws: AuthError.sessionExpired) { try await auth.refreshedAccessToken() }
        #expect(auth.state == .signedOut)
        #expect(store.current == nil)
    }

    @Test @MainActor func apiClientWithAuthServiceRefreshesOn401() async throws {
        StubURLProtocol.install { request in
            if request.url?.path() == "/oauth2/token" { return (200, TestFixtures.tokenJSON(access: "fresh")) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                ? (200, photosJSON) : (401, Data(#"{"message":"Unauthorized"}"#.utf8))
        }
        let store = InMemoryTokenStore(AuthTokens(
            TokenResponse(accessToken: "stale", idToken: nil, refreshToken: "r1", tokenType: "Bearer", expiresIn: 3600),
            receivedAt: .now))
        let session = StubURLProtocol.session()
        let auth = AuthService(config: TestFixtures.config, store: store, session: session,
                               webAuthenticator: FakeWebAuthenticator())
        let client = APIClient(baseURL: TestFixtures.config.apiURL, tokens: auth, session: session)

        #expect(try await client.listPhotos().count == 1)
        #expect(StubURLProtocol.requests.map { $0.url!.path() } == ["/photos", "/oauth2/token", "/photos"])
        #expect(store.current?.accessToken == "fresh")
        #expect(auth.state == .signedIn)
    }

    @Test @MainActor func signOutRevokesAndClears() async throws {
        StubURLProtocol.install { _ in (200, Data()) }
        let store = InMemoryTokenStore(AuthTokens(
            TokenResponse(accessToken: "a", idToken: nil, refreshToken: "r1", tokenType: "Bearer", expiresIn: 3600),
            receivedAt: .now))
        let web = FakeWebAuthenticator()
        let auth = AuthService(config: TestFixtures.config, store: store, session: StubURLProtocol.session(),
                               webAuthenticator: web)
        await auth.signOut()
        #expect(auth.state == .signedOut)
        #expect(store.current == nil)
        #expect(StubURLProtocol.requests.first?.url?.path() == "/oauth2/revoke")
        #expect(StubURLProtocol.requests.first?.formFields["token"] == "r1")
        #expect(web.openedURLs.last?.path() == "/logout")
    }
}
