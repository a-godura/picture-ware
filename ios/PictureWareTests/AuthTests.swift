import Foundation
import Testing
@testable import PictureWare

@Suite("PKCE")
struct PKCETests {
    @Test("RFC 7636 Appendix B test vector")
    func rfc7636Vector() {
        let bytes: [UInt8] = [
            116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173,
            187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83,
            132, 141, 121,
        ]
        let pkce = PKCE(verifierBytes: bytes)
        #expect(pkce.verifier == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(pkce.method == "S256")
    }

    @Test func generatedVerifierIsValid() {
        let pkce = PKCE.generate()
        // RFC 7636 §4.1: 43...128 chars of [A-Z a-z 0-9 - . _ ~]
        #expect((43...128).contains(pkce.verifier.count))
        #expect(pkce.verifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) })
        #expect(pkce.challenge == PKCE.challenge(for: pkce.verifier))
        #expect(PKCE.generate().verifier != pkce.verifier)
    }
}

@Suite("Cognito endpoints")
struct CognitoEndpointsTests {
    let endpoints = CognitoEndpoints(config: TestFixtures.config)

    @Test func authorizeURL() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = endpoints.authorizeURL(pkce: pkce, state: "xyz")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "pw.auth.us-east-2.amazoncognito.com")
        #expect(components.path == "/oauth2/authorize")

        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items == [
            "response_type": "code",
            "client_id": "client123",
            "redirect_uri": "picture-ware://auth/callback",
            "scope": "openid email profile",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
            "state": "xyz",
        ])
        // Strict encoding: spaces as %20, reserved characters escaped.
        let query = try #require(components.percentEncodedQuery)
        #expect(query.contains("scope=openid%20email%20profile"))
        #expect(query.contains("redirect_uri=picture-ware%3A%2F%2Fauth%2Fcallback"))
    }

    @Test func logoutURL() {
        #expect(endpoints.logoutURL().absoluteString ==
            "https://pw.auth.us-east-2.amazoncognito.com/logout?client_id=client123&logout_uri=picture-ware%3A%2F%2Fauth%2Fsignout")
    }

    @Test func tokenRequest() {
        let request = endpoints.tokenRequest(code: "abc", verifier: "ver")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pw.auth.us-east-2.amazoncognito.com/oauth2/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(request.bodyString ==
            "grant_type=authorization_code&client_id=client123&code=abc&redirect_uri=picture-ware%3A%2F%2Fauth%2Fcallback&code_verifier=ver")
    }

    @Test func refreshAndRevokeRequests() {
        let refresh = endpoints.refreshRequest(refreshToken: "r+t/=")
        #expect(refresh.bodyString == "grant_type=refresh_token&client_id=client123&refresh_token=r%2Bt%2F%3D")
        let revoke = endpoints.revokeRequest(refreshToken: "rt")
        #expect(revoke.url?.path() == "/oauth2/revoke")
        #expect(revoke.formFields == ["token": "rt", "client_id": "client123"])
    }

    @Test func callbackParsing() throws {
        let ok = URL(string: "picture-ware://auth/callback?code=c0de&state=s1")!
        #expect(try endpoints.authorizationCode(from: ok, expectedState: "s1") == "c0de")

        #expect(throws: AuthError.stateMismatch) {
            try endpoints.authorizationCode(from: ok, expectedState: "other")
        }
        let denied = URL(string: "picture-ware://auth/callback?error=access_denied&error_description=nope&state=s1")!
        #expect(throws: AuthError.provider("nope")) {
            try endpoints.authorizationCode(from: denied, expectedState: "s1")
        }
        let noCode = URL(string: "picture-ware://auth/callback?state=s1")!
        #expect(throws: AuthError.missingCode) {
            try endpoints.authorizationCode(from: noCode, expectedState: "s1")
        }
    }
}

@Suite("Tokens")
struct TokenTests {
    @Test func decodesCognitoTokenResponse() throws {
        let json = """
        {"id_token":"eyJ.id","access_token":"eyJ.access","refresh_token":"eyJ.refresh","expires_in":3600,"token_type":"Bearer"}
        """
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        #expect(response == TokenResponse(accessToken: "eyJ.access", idToken: "eyJ.id",
                                          refreshToken: "eyJ.refresh", tokenType: "Bearer", expiresIn: 3600))

        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = AuthTokens(response, receivedAt: now)
        #expect(tokens.expiresAt == now.addingTimeInterval(3600))
        #expect(tokens.isValid(at: now))
        #expect(!tokens.isValid(at: now.addingTimeInterval(3550))) // within 60 s leeway
    }

    @Test func refreshResponseKeepsPreviousRefreshToken() throws {
        let json = #"{"id_token":"i","access_token":"a2","expires_in":300,"token_type":"Bearer"}"#
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        #expect(response.refreshToken == nil)
        let tokens = AuthTokens(response, receivedAt: .now, previousRefreshToken: "old-refresh")
        #expect(tokens.refreshToken == "old-refresh")
        #expect(tokens.accessToken == "a2")
    }

    /// Unsigned builds (CI uses CODE_SIGNING_ALLOWED=NO) have no keychain entitlement and get
    /// errSecMissingEntitlement (-34018), so the round trip only runs where the keychain works.
    static let keychainAvailable: Bool = {
        let probe = KeychainStore(service: "com.agodura.pictureware.tests", account: "probe")
        let tokens = AuthTokens(TokenResponse(accessToken: "a", idToken: nil, refreshToken: nil, tokenType: "Bearer", expiresIn: 1),
                                receivedAt: .now)
        defer { try? probe.clear() }
        return (try? probe.save(tokens)) != nil
    }()

    @Test(.enabled(if: TokenTests.keychainAvailable, "Keychain needs a signed build"))
    func keychainRoundTrip() throws {
        let store = KeychainStore(service: "com.agodura.pictureware.tests", account: UUID().uuidString)
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let tokens = AuthTokens(TokenResponse(accessToken: "a", idToken: nil, refreshToken: "r", tokenType: "Bearer", expiresIn: 60),
                                receivedAt: Date(timeIntervalSince1970: 0))
        try store.save(tokens)
        #expect(try store.load() == tokens)
        var updated = tokens
        updated.accessToken = "b"
        try store.save(updated)
        #expect(try store.load() == updated)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func placeholderConfigIsDetected() {
        #expect(!TestFixtures.config.isPlaceholder)
        var config = TestFixtures.config
        config.clientID = "REPLACE_ME"
        #expect(config.isPlaceholder)
    }

    /// Verifies the xcconfig -> Info.plist -> AppConfig chain (including the `https:/$()/` escaping).
    @Test func bundledConfigLoads() {
        let bundled = AppConfig.load()
        #expect(!bundled.isPlaceholder)
        #expect(bundled.apiURL.scheme == "https")
        #expect(bundled.apiURL.host()?.hasSuffix(".amazonaws.com") == true)
        #expect(bundled.apiURL.path().isEmpty || bundled.apiURL.path() == "/")
        #expect(bundled.authDomain.scheme == "https")
        #expect(bundled.authDomain.host()?.hasSuffix(".amazoncognito.com") == true)
        #expect(!bundled.clientID.isEmpty && !bundled.clientID.contains(" "))
        #expect(bundled.redirectURI == "picture-ware://auth/callback")
    }
}
