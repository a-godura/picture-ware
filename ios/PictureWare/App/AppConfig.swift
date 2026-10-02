import Foundation

/// Backend + Cognito settings. Values come from `ios/Config/Config.xcconfig`
/// via Info.plist keys `PWApiUrl`, `PWAuthDomain` and `PWClientId`.
struct AppConfig: Sendable, Equatable {
    var apiURL: URL
    var authDomain: URL
    var clientID: String
    var redirectURI = "picture-ware://auth/callback"
    var signOutURI = "picture-ware://auth/signout"
    var callbackScheme = "picture-ware"
    var scopes = ["openid", "email", "profile"]

    /// True while Config.xcconfig still holds the `REPLACE_ME` placeholders.
    var isPlaceholder: Bool {
        [apiURL.absoluteString, authDomain.absoluteString, clientID].contains { $0.contains("REPLACE_ME") }
    }

    static func load(from bundle: Bundle = .main) -> AppConfig {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        func url(_ key: String) -> URL {
            let raw = value(key)
            guard let url = URL(string: raw), url.scheme == "https", url.host() != nil else {
                return URL(string: "https://REPLACE_ME.invalid")!
            }
            return url
        }
        let clientID = value("PWClientId")
        return AppConfig(
            apiURL: url("PWApiUrl"),
            authDomain: url("PWAuthDomain"),
            clientID: clientID.isEmpty ? "REPLACE_ME" : clientID
        )
    }
}
