//
//  RequestMatcher.swift
//  Alamock
//

import Alamofire
import Foundation

/// A composable description of the requests matching a ``MockRoute`` or a
/// ``MockServer/verify(_:times:)-`` assertion.
///
/// Every property is optional; only the properties you set constrain matching. A matcher
/// with no constraints matches every request.
///
/// ```swift
/// let matcher = RequestMatcher(
///     method: .post,
///     path: "/users/:id",
///     headers: ["Authorization": nil],        // header must be present
///     body: .json(["name": "Ada"])
/// )
/// XCTAssertTrue(matcher.matches(recordedRequest))
/// ```
public struct RequestMatcher: @unchecked Sendable, CustomStringConvertible {
    /// The required HTTP method, or `nil` to accept any method.
    public var method: HTTPMethod?

    /// The required host (case-insensitive), or `nil` to accept any host.
    public var host: String?

    /// The required path pattern, or `nil` to accept any path.
    public var path: MockPathPattern?

    /// Required query items. A value of `nil` only requires the item to be present.
    public var queryItems: [String: String?]

    /// Required headers. Names are matched case-insensitively; a value of `nil` only
    /// requires the header to be present.
    public var headers: [String: String?]

    /// A required body shape, or `nil` to accept any body.
    public var body: MockBodyMatcher?

    /// An additional custom predicate evaluated last.
    public var predicate: (@Sendable (RecordedRequest) -> Bool)?

    /// Creates a request matcher.
    ///
    /// - Parameters:
    ///   - method: Required method, or `nil` for any.
    ///   - path: Required path pattern. A query string in this value is parsed into
    ///     `queryItems`, e.g. `"/search?q=swift"`. `nil` accepts any path.
    ///   - host: Required host, or `nil` for any.
    ///   - queryItems: Required query items; `nil` values only require presence.
    ///   - headers: Required headers; `nil` values only require presence.
    ///   - body: Required body shape.
    ///   - predicate: An extra custom predicate.
    public init(
        method: HTTPMethod? = nil,
        path: String? = nil,
        host: String? = nil,
        queryItems: [String: String?] = [:],
        headers: [String: String?] = [:],
        body: MockBodyMatcher? = nil,
        predicate: (@Sendable (RecordedRequest) -> Bool)? = nil
    ) {
        var expectedQueryItems = queryItems

        if let path {
            let (pattern, parsedItems) = Self.splitQuery(from: path)
            self.path = MockPathPattern(pattern)
            for item in parsedItems {
                if expectedQueryItems[item.name] == nil {
                    expectedQueryItems[item.name] = item.value
                }
            }
        } else {
            self.path = nil
        }

        self.method = method
        self.host = host
        self.queryItems = expectedQueryItems
        self.headers = headers
        self.body = body
        self.predicate = predicate
    }

    /// Returns whether `request` satisfies every constraint.
    public func matches(_ request: RecordedRequest) -> Bool {
        match(request) != nil
    }

    /// Returns the captured path parameters when the request matches, `nil` otherwise.
    ///
    /// - Note: This is intentionally not public because it is only meaningful for matching,
    ///   not for verification. ``RecordedRequest/pathParameters`` exposes values captured by
    ///   the route that actually matched a request.
    func match(_ request: RecordedRequest) -> [String: String]? {
        if let method, request.method != method {
            return nil
        }

        if let host, request.url.host?.caseInsensitiveCompare(host) != .orderedSame {
            return nil
        }

        var captured: [String: String] = [:]
        if let path {
            guard let parameters = path.match(path: request.path) else { return nil }
            captured = parameters
        }

        if !queryItems.isEmpty {
            let recordedItems = request.queryItems
            for (name, expectedValue) in queryItems {
                let matchingItems = recordedItems.filter { $0.name == name }
                guard !matchingItems.isEmpty else { return nil }
                if let expectedValue, !matchingItems.contains(where: { $0.value == expectedValue }) {
                    return nil
                }
            }
        }

        if !headers.isEmpty {
            for (name, expectedValue) in headers {
                guard let actualValue = request.header(name) else { return nil }
                if let expectedValue, actualValue != expectedValue {
                    return nil
                }
            }
        }

        if let body, !body.matches(request.body) {
            return nil
        }

        if let predicate {
            // Give the predicate a request view that exposes the path parameters captured
            // by the pattern above, so predicates can assert on `:id`-style segments.
            let predicateRequest = captured.isEmpty
                ? request
                : request.withMatch(route: description, pathParameters: captured)
            guard predicate(predicateRequest) else { return nil }
        }

        return captured
    }

    /// A human-readable summary such as `GET /users/:id (query page=2)`.
    public var description: String {
        var components: [String] = []
        components.append(method?.rawValue ?? "ANY")
        components.append(path?.rawValue ?? "**")

        if let host {
            components.append("host \(host)")
        }
        if !queryItems.isEmpty {
            let query = queryItems
                .sorted { $0.key < $1.key }
                .map { name, value in value.map { "\(name)=\($0)" } ?? "\(name)" }
                .joined(separator: "&")
            components.append("query [\(query)]")
        }
        if !headers.isEmpty {
            let headerNames = headers.keys.sorted().joined(separator: ", ")
            components.append("headers [\(headerNames)]")
        }
        if let body {
            components.append("\(body)")
        }

        return components.joined(separator: " ")
    }

    // MARK: - Private

    private static func splitQuery(from rawPath: String) -> (String, [URLQueryItem]) {
        guard let queryStart = rawPath.firstIndex(of: "?") else {
            return (rawPath, [])
        }

        let pattern = String(rawPath[..<queryStart])
        let rawQuery = String(rawPath[rawPath.index(after: queryStart)...])

        var components = URLComponents()
        components.query = rawQuery
        return (pattern, components.queryItems ?? [])
    }
}
