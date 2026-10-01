import Foundation
import Observation

/// Supplies bearer tokens to the API client.
protocol AccessTokenProvider: Sendable {
    /// A non-expired access token, refreshing first if needed.
    func validAccessToken() async throws -> String
    /// Forces a refresh (used after the API answered 401).
    func refreshedAccessToken() async throws -> String
    /// Called when the API still rejects us after a refresh.
    func sessionExpired() async
}

/// Cognito Hosted UI sign-in (authorization code + PKCE), token storage and refresh.
@MainActor
@Observable
final class AuthService: AccessTokenProvider {
    enum State: Equatable { case signedOut, signedIn }

    private(set) var state: State = .signedOut
    private(set) var isWorking = false
    var errorMessage: String?

    @ObservationIgnored let config: AppConfig
    @ObservationIgnored private let endpoints: CognitoEndpoints
    @ObservationIgnored private let store: any TokenStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let webAuthenticator: any WebAuthenticator
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var tokens: AuthTokens?
    @ObservationIgnored private var refreshTask: Task<AuthTokens, any Error>?

    init(
        config: AppConfig,
        store: any TokenStore = KeychainStore(),
        session: URLSession = .shared,
        webAuthenticator: (any WebAuthenticator)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.endpoints = CognitoEndpoints(config: config)
        self.store = store
        self.session = session
        self.webAuthenticator = webAuthenticator ?? SystemWebAuthenticator()
        self.now = now
        self.tokens = try? store.load()
        // A stored refresh token (or a still-valid access token) means we're signed in.
        if let tokens, tokens.refreshToken != nil || tokens.isValid(at: now()) {
            state = .signedIn
        }
    }

    // MARK: - Sign in / out

    func signIn() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            guard !config.isPlaceholder else { throw AuthError.notConfigured }
            let pkce = PKCE.generate()
            let state = PKCE.randomState()
            let callback = try await webAuthenticator.authenticate(
                url: endpoints.authorizeURL(pkce: pkce, state: state),
                callbackScheme: config.callbackScheme
            )
            let code = try endpoints.authorizationCode(from: callback, expectedState: state)
            let response = try await sendTokenRequest(endpoints.tokenRequest(code: code, verifier: pkce.verifier))
            try persist(AuthTokens(response, receivedAt: now()))
            self.state = .signedIn
        } catch AuthError.cancelled {
            // User closed the sheet; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Revokes the refresh token, clears local tokens and ends the Hosted UI session.
    func signOut() async {
        isWorking = true
        defer { isWorking = false }
        if let refreshToken = tokens?.refreshToken {
            _ = try? await session.data(for: endpoints.revokeRequest(refreshToken: refreshToken))
        }
        clearLocalSession()
        // Best effort: clears the Cognito cookie so the next sign-in shows the login page.
        _ = try? await webAuthenticator.authenticate(url: endpoints.logoutURL(), callbackScheme: config.callbackScheme)
    }

    // MARK: - AccessTokenProvider

    func validAccessToken() async throws -> String {
        guard let tokens else { throw AuthError.notSignedIn }
        if tokens.isValid(at: now()) { return tokens.accessToken }
        return try await refreshedAccessToken()
    }

    func refreshedAccessToken() async throws -> String {
        // Coalesce concurrent refreshes into one network call.
        if let refreshTask { return try await refreshTask.value.accessToken }
        guard let refreshToken = tokens?.refreshToken else {
            clearLocalSession()
            throw AuthError.sessionExpired
        }
        let task = Task { () throws -> AuthTokens in
            let response = try await self.sendTokenRequest(self.endpoints.refreshRequest(refreshToken: refreshToken))
            return AuthTokens(response, receivedAt: self.now(), previousRefreshToken: refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let newTokens = try await task.value
            try persist(newTokens)
            return newTokens.accessToken
        } catch AuthError.sessionExpired {
            clearLocalSession()
            throw AuthError.sessionExpired
        }
    }

    func sessionExpired() async {
        clearLocalSession()
        errorMessage = AuthError.sessionExpired.errorDescription
    }

    // MARK: - Private

    private func persist(_ tokens: AuthTokens) throws {
        self.tokens = tokens
        try store.save(tokens)
    }

    private func clearLocalSession() {
        tokens = nil
        try? store.clear()
        state = .signedOut
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        case 400, 401:
            // Cognito returns 400 {"error":"invalid_grant"} for a revoked/expired refresh token.
            let body = try? JSONDecoder().decode([String: String].self, from: data)
            if body?["error"] == "invalid_grant" { throw AuthError.sessionExpired }
            throw AuthError.provider(body?["error"] ?? "HTTP \(status)")
        default:
            throw AuthError.badResponse(status)
        }
    }
}
