//
//  RecordedRequest.swift
//  Alamock
//

import Foundation

/// An immutable snapshot of an HTTP request that reached a ``MockServer``.
///
/// Recorded requests are available through ``MockServer/recordedRequests`` and
/// ``MockServer/unmatchedRequests``, and are passed to custom responders and predicates.
public struct RecordedRequest: Sendable, CustomStringConvertible {
    /// The HTTP method of the request.
    public let method: HTTPMethod

    /// The full request URL.
    public let url: URL

    /// All request headers, excluding the mock transport's private routing header.
    public let headers: [String: String]

    /// The request body, when one was present and readable.
    ///
    /// For upload requests the body is read from `httpBodyStream` when URLSession does not
    /// expose it as `httpBody`.
    public let body: Data?

    /// The time at which the mock server received the request.
    public let recordedAt: Date

    /// A description of the route that matched, or `nil` when no route matched.
    public let matchedRoute: String?

    /// Values captured by `:` segments of the matched route's path pattern.
    public let pathParameters: [String: String]

    /// Whether a registered route matched this request.
    public var wasMatched: Bool { matchedRoute != nil }

    /// The percent-decoded path of the URL, e.g. `/users/42`.
    public var path: String { url.path }

    /// The decoded query items of the URL.
    public var queryItems: [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    /// The decoded query parameters, with the last occurrence winning for repeated names.
    public var query: [String: String] {
        var result: [String: String] = [:]
        for item in queryItems {
            if let value = item.value {
                result[item.name] = value
            }
        }
        return result
    }

    /// The host of the URL, if any.
    public var host: String? { url.host }

    /// The request body decoded as a UTF-8 string, if possible.
    public var bodyString: String? {
        guard let body else { return nil }
        return String(data: body, encoding: .utf8)
    }

    /// Returns the value of a header, using case-insensitive name matching.
    public func header(_ name: String) -> String? {
        headers.value(forHeader: name)
    }

    /// Parses the request body as JSON and returns the resulting Foundation object.
    public func jsonBody() throws -> Any {
        guard let body else {
            throw MockDecodingError.emptyBody
        }
        return try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
    }

    /// Decodes the request body as JSON into `type`.
    public func decodeBody<Value: Decodable>(
        _ type: Value.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value {
        guard let body else {
            throw MockDecodingError.emptyBody
        }
        return try decoder.decode(type, from: body)
    }

    /// A human-readable summary such as `GET https://example.com/users/42 (matched GET /users/:id)`.
    public var description: String {
        let suffix = matchedRoute.map { " (matched \($0))" } ?? " (unmatched)"
        return "\(method.rawValue) \(url.absoluteString)\(suffix)"
    }

    // MARK: - Internal

    init(
        request: URLRequest,
        body: Data?,
        recordedAt: Date = Date(),
        matchedRoute: String? = nil,
        pathParameters: [String: String] = [:],
        headerFieldsToRemove: Set<String> = []
    ) {
        self.method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        self.url = request.url ?? URL(string: "about:blank")!
        self.headers = Self.filteredHeaders(
            request.allHTTPHeaderFields ?? [:],
            removing: headerFieldsToRemove
        )
        self.body = body
        self.recordedAt = recordedAt
        self.matchedRoute = matchedRoute
        self.pathParameters = pathParameters
    }

    func withMatch(route: String, pathParameters: [String: String]) -> RecordedRequest {
        RecordedRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            recordedAt: recordedAt,
            matchedRoute: route,
            pathParameters: pathParameters
        )
    }

    private init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String],
        body: Data?,
        recordedAt: Date,
        matchedRoute: String?,
        pathParameters: [String: String]
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.recordedAt = recordedAt
        self.matchedRoute = matchedRoute
        self.pathParameters = pathParameters
    }

    private static func filteredHeaders(
        _ headers: [String: String],
        removing names: Set<String>
    ) -> [String: String] {
        guard !names.isEmpty else { return headers }
        let lowercaseNames = Set(names.map { $0.lowercased() })
        return headers.filter { !lowercaseNames.contains($0.key.lowercased()) }
    }
}

/// Errors thrown while decoding a recorded request body.
public enum MockDecodingError: Error, LocalizedError, Sendable {
    /// The request had no body.
    case emptyBody

    public var errorDescription: String? {
        "The request has no body to decode."
    }
}
