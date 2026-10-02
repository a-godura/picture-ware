import Foundation

/// Raw `/oauth2/token` response. `refresh_token` is absent on refresh grants.
struct TokenResponse: Decodable, Sendable, Equatable {
    let accessToken: String
    let idToken: String?
    let refreshToken: String?
    let tokenType: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

/// Tokens as persisted in the Keychain.
struct AuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var idToken: String?
    var refreshToken: String?
    var expiresAt: Date

    /// - Parameter previousRefreshToken: kept when a refresh response omits a new one.
    init(_ response: TokenResponse, receivedAt: Date, previousRefreshToken: String? = nil) {
        accessToken = response.accessToken
        idToken = response.idToken
        refreshToken = response.refreshToken ?? previousRefreshToken
        expiresAt = receivedAt.addingTimeInterval(TimeInterval(response.expiresIn))
    }

    /// Treat tokens expiring within `leeway` seconds as already expired.
    func isValid(at now: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) > leeway
    }
}
