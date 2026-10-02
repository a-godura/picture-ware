import Foundation

/// Builds the Cognito Hosted UI / OAuth 2.0 URLs and requests.
struct CognitoEndpoints: Sendable {
    let config: AppConfig

    func authorizeURL(pkce: PKCE, state: String) -> URL {
        url("oauth2/authorize", query: [
            ("response_type", "code"),
            ("client_id", config.clientID),
            ("redirect_uri", config.redirectURI),
            ("scope", config.scopes.joined(separator: " ")),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
            ("state", state),
        ])
    }

    func logoutURL() -> URL {
        url("logout", query: [
            ("client_id", config.clientID),
            ("logout_uri", config.signOutURI),
        ])
    }

    func tokenRequest(code: String, verifier: String) -> URLRequest {
        formRequest("oauth2/token", [
            ("grant_type", "authorization_code"),
            ("client_id", config.clientID),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("code_verifier", verifier),
        ])
    }

    func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest("oauth2/token", [
            ("grant_type", "refresh_token"),
            ("client_id", config.clientID),
            ("refresh_token", refreshToken),
        ])
    }

    func revokeRequest(refreshToken: String) -> URLRequest {
        formRequest("oauth2/revoke", [
            ("token", refreshToken),
            ("client_id", config.clientID),
        ])
    }

    /// Extracts the authorization code from the redirect, checking `state`.
    func authorizationCode(from callback: URL, expectedState: String) throws(AuthError) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }

        if let error = item("error") {
            throw .provider(item("error_description") ?? error)
        }
        guard item("state") == expectedState else { throw .stateMismatch }
        guard let code = item("code"), !code.isEmpty else { throw .missingCode }
        return code
    }

    // MARK: - Helpers

    private func endpoint(_ path: String) -> URL {
        config.authDomain.appending(path: path)
    }

    private func url(_ path: String, query: [(String, String)]) -> URL {
        var components = URLComponents(url: endpoint(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = Self.formEncode(query)
        return components.url!
    }

    private func formRequest(_ path: String, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(fields).utf8)
        return request
    }

    /// `application/x-www-form-urlencoded`, encoding everything except RFC 3986 unreserved characters.
    static func formEncode(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

enum AuthError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case cancelled
    case stateMismatch
    case missingCode
    case provider(String)
    case sessionExpired
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The app isn't configured yet. Fill in ios/Config/Config.xcconfig."
        case .notSignedIn: "You're not signed in."
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "Sign-in failed (state mismatch). Please try again."
        case .missingCode: "Sign-in failed (no authorization code)."
        case .provider(let message): "Sign-in failed: \(message)"
        case .sessionExpired: "Your session expired. Please sign in again."
        case .badResponse(let status): "Sign-in failed (HTTP \(status))."
        }
    }
}
