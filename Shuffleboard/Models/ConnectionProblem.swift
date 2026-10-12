import Foundation

// MARK: - ConnectionProblem

/// Why the server can't be reached (#156). While there is one, the app shows the copy of the boards kept on the Mac,
/// read-only, and keeps trying to reconnect.
enum ConnectionProblem: Equatable, Sendable {
    /// The Mac has no network connection.
    case offline
    /// The Mac is online but the server doesn't answer, or answers that it's unavailable (down, in maintenance
    /// mode, or a proxy in front of it can't reach it).
    case serverUnreachable

    /// The problem `error` shows, or nil if it's some other failure (a rejected request, a bad response…), which
    /// means the server was reached.
    init?(_ error: Error) {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                self = .offline

            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .networkConnectionLost:
                self = .serverUnreachable

            default:
                return nil
            }
            return
        }
        if case let .httpStatus(status)? = error as? DeckAPIError, [502, 503, 504].contains(status) {
            self = .serverUnreachable
            return
        }
        return nil
    }

    /// The banner's first sentence.
    var title: String {
        switch self {
        case .offline: "You're offline."
        case .serverUnreachable: "Can't reach the server."
        }
    }
}
