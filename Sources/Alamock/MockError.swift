//
//  MockError.swift
//  Alamock
//

import Foundation

/// Errors produced by the mock transport itself (as opposed to errors you deliberately
/// emulate with ``MockResponse/error(_:)``).
public enum MockError: Error, LocalizedError, Sendable, Equatable {
    /// A request carried a mock-server identifier that no live ``MockServer`` owns.
    ///
    /// This usually means a test forgot to keep its `MockServer` alive for the duration of
    /// the request, or a session was reused after its server was deallocated.
    case serverUnavailable(identifier: String)

    /// A route responded with a sequence whose entries have been exhausted and the route
    /// was configured with `repeatingLast: false`.
    case responseSequenceExhausted(route: String)

    /// The mock transport could not construct an `HTTPURLResponse` for a response.
    case invalidResponse(route: String, url: String)

    /// The response body of an upload request could not be read from its stream.
    case unreadableRequestBody(route: String)

    public var errorDescription: String? {
        switch self {
        case let .serverUnavailable(identifier):
            return """
            No live MockServer is registered for identifier \(identifier). \
            Keep the MockServer referenced for as long as its URLSession is used.
            """
        case let .responseSequenceExhausted(route):
            return """
            The response sequence for route \(route) is exhausted and repeatingLast is false. \
            Either register more responses or let the sequence repeat its last value.
            """
        case let .invalidResponse(route, url):
            return "Could not build an HTTPURLResponse for \(route) at \(url)."
        case let .unreadableRequestBody(route):
            return "Could not read the HTTP body stream of the request matched by \(route)."
        }
    }
}

extension MockError: CustomNSError {
    /// The `NSError` domain a mock error carries when it crosses URLSession's Objective-C boundary.
    ///
    /// URLSession reports protocol failures through `Error` values whose `NSError` domain is the
    /// error's Swift type name, so this is stable across module renames and can be asserted on.
    public static let errorDomain = "Alamock.MockError"

    /// A stable numeric code per case, for assertions on the `NSError` surfaced by URLSession.
    public var errorCode: Int {
        switch self {
        case .serverUnavailable: return 1
        case .responseSequenceExhausted: return 2
        case .invalidResponse: return 3
        case .unreadableRequestBody: return 4
        }
    }

    /// Bridges ``errorDescription`` into `NSError.localizedDescription`.
    public var errorUserInfo: [String: Any] {
        guard let errorDescription else { return [:] }
        return [NSLocalizedDescriptionKey: errorDescription]
    }
}
