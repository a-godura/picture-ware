import Foundation

/// Exponential backoff: `baseDelay * 2^(attempt-1)`, capped, with optional jitter so a batch
/// that failed together doesn't retry in lockstep.
struct RetryPolicy: Sendable, Equatable {
    var maxAttempts = 5
    var baseDelay: TimeInterval = 2
    var maxDelay: TimeInterval = 60
    /// Fraction of the delay randomized away (0 = deterministic).
    var jitter = 0.25

    static let standard = RetryPolicy()

    /// Delay before the next try after `attempt` failures (1-based).
    func delay(afterAttempt attempt: Int, random: Double = .random(in: 0...1)) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(maxDelay, baseDelay * pow(2, exponent))
        return raw * (1 - jitter * random)
    }
}

/// How the queue reacts to a failure.
enum FailureKind: Sendable, Equatable {
    /// Try again later (server hiccup, throttling); counts toward `maxAttempts`.
    case transient
    /// No connection: keep waiting with backoff, without using up attempts.
    case offline
    /// The presigned upload was refused (most likely expired): get a new one and retry.
    case presignRejected
    /// Needs the user to sign in again; stop until they retry.
    case needsSignIn
    /// Retrying won't help (bad request, too large).
    case permanent
}

enum UploadFailure {
    static func classify(_ error: any Error) -> FailureKind {
        switch error {
        case let error as APIError:
            switch error {
            case .unauthorized: return .needsSignIn
            case .invalidResponse: return .transient
            case .uploadFailed(let status): return classify(storageStatus: status)
            case .http(let status, _):
                if status == 408 || status == 429 || status >= 500 { return .transient }
                if status == 401 { return .needsSignIn }
                return .permanent
            }
        case let error as AuthError:
            switch error {
            case .badResponse, .provider: return .transient
            default: return .needsSignIn
            }
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed:
                return .offline
            default:
                return .transient
            }
        default:
            // Includes file errors: the body file is rebuilt on the next attempt.
            return .transient
        }
    }

    /// Storage (S3 presigned POST) HTTP status after the body was sent.
    static func classify(storageStatus status: Int) -> FailureKind {
        switch status {
        case 403: .presignRejected // "Policy expired" / signature no longer valid
        case 408, 429, 500...: .transient
        default: .permanent // 400 (e.g. EntityTooLarge), 412, ...
        }
    }

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
