import CryptoKit
import Foundation
import Security

/// Proof Key for Code Exchange (RFC 7636), S256 method.
struct PKCE: Sendable, Equatable {
    let verifier: String
    let challenge: String
    let method = "S256"

    /// 32 random bytes -> 43-character base64url verifier.
    static func generate() -> PKCE {
        PKCE(verifierBytes: randomBytes(count: 32))
    }

    init(verifierBytes: [UInt8]) {
        self.init(verifier: Data(verifierBytes).base64URLEncodedString())
    }

    init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// Random URL-safe string, used for the OAuth `state` parameter.
    static func randomState() -> String {
        Data(randomBytes(count: 16)).base64URLEncodedString()
    }

    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
