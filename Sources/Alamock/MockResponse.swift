//
//  MockResponse.swift
//  Alamock
//
//  Created by Alamock contributors.
//

import Foundation

/// A canned response returned by a ``MockRoute``.
///
/// `MockResponse` describes everything the mock transport needs in order to emulate a
/// server: the HTTP status code, response headers, body bytes, an optional artificial
/// delay, and an optional transport-level failure.
///
/// ```swift
/// mock.on(.get("/users/1")).respond(.json(["id": 1, "name": "Ada"], status: 200))
/// mock.on(.post("/login")).respond(.status(401).with(header: "WWW-Authenticate", "Bearer"))
/// mock.on(.get("/slow")).respond(.json([:]).delayed(by: 0.5))
/// mock.on(.get("/offline")).respond(.error(.notConnectedToInternet))
/// ```
public struct MockResponse: Sendable {
    /// The HTTP status code of the emulated response.
    public var statusCode: Int

    /// Response headers. Header lookup performed by the mock transport is case-insensitive,
    /// but the dictionary itself preserves the casing you provide.
    public var headers: [String: String]

    /// The response body bytes.
    public var body: Data

    /// An artificial delay, in seconds, applied before the response is delivered.
    ///
    /// The delay is implemented with `DispatchQueue.asyncAfter`, so it does not block any
    /// thread. Use it to exercise loading states, cancellation, and race conditions.
    public var delay: TimeInterval

    /// A transport-level failure to emulate instead of an HTTP response.
    ///
    /// When set, the mock transport fails the request with this `URLError` rather than
    /// delivering an `HTTPURLResponse`. Alamofire surfaces it as
    /// `AFError.sessionTaskFailed(error:)`.
    public var error: URLError?

    /// Creates a mock response.
    ///
    /// - Parameters:
    ///   - status: The HTTP status code. Defaults to `200`.
    ///   - headers: Response headers. Defaults to empty.
    ///   - body: Response body bytes. Defaults to empty.
    ///   - delay: Artificial delay in seconds. Defaults to `0`.
    ///   - error: A transport-level error to emulate. Defaults to `nil`.
    public init(
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data(),
        delay: TimeInterval = 0,
        error: URLError? = nil
    ) {
        self.statusCode = status
        self.headers = headers
        self.body = body
        self.delay = delay
        self.error = error
    }

    // MARK: - Factories

    /// A response with raw body data.
    public static func data(
        _ data: Data,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> MockResponse {
        MockResponse(status: status, headers: headers, body: data)
    }

    /// A plain text response. Adds `Content-Type: text/plain; charset=utf-8` unless one is provided.
    public static func text(
        _ string: String,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> MockResponse {
        let merged = headers.withDefaultValue(
            for: "Content-Type",
            value: "text/plain; charset=utf-8"
        )
        return MockResponse(status: status, headers: merged, body: Data(string.utf8))
    }

    /// A JSON response built from a JSON-serializable object (`[String: Any]`, `[Any]`, scalars, …).
    ///
    /// Adds `Content-Type: application/json` unless one is provided. If `object` is not a valid
    /// JSON object, the returned response is a `500` with a diagnostic body and the header
    /// `X-Alamock-Error: json-serialization-failed` so the mistake is visible in the test
    /// rather than silently swallowed.
    public static func json(
        _ object: Any,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> MockResponse {
        let merged = headers.withDefaultValue(for: "Content-Type", value: "application/json")

        // `JSONSerialization.data(withJSONObject:)` raises an Objective-C exception (a crash,
        // not a Swift error) for values it cannot represent, so validate the value inside an
        // array first — this accepts top-level fragments as well as containers — and report a
        // diagnostic response instead of trapping.
        guard JSONSerialization.isValidJSONObject([object]) else {
            return jsonSerializationFailure(
                JSONValueNotRepresentableError.unsupportedValue,
                headers: merged,
                status: status
            )
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.fragmentsAllowed, .sortedKeys]
            )
            return MockResponse(status: status, headers: merged, body: data)
        } catch {
            return jsonSerializationFailure(error, headers: merged, status: status)
        }
    }

    /// A JSON response built from any `Encodable` value.
    ///
    /// Adds `Content-Type: application/json` unless one is provided.
    public static func json<Value: Encodable>(
        _ value: Value,
        status: Int = 200,
        headers: [String: String] = [:],
        encoder: JSONEncoder = JSONEncoder()
    ) -> MockResponse {
        let merged = headers.withDefaultValue(for: "Content-Type", value: "application/json")

        do {
            return MockResponse(
                status: status,
                headers: merged,
                body: try encoder.encode(value)
            )
        } catch {
            return jsonSerializationFailure(error, headers: merged, status: status)
        }
    }

    /// An empty response with the given status code and headers.
    public static func empty(
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> MockResponse {
        MockResponse(status: status, headers: headers)
    }

    /// A response containing only a status code.
    public static func status(_ statusCode: Int) -> MockResponse {
        MockResponse(status: statusCode)
    }

    /// A transport-level failure, e.g. ``URLError/timedOut`` or
    /// ``URLError/notConnectedToInternet``.
    ///
    /// Alamofire surfaces the failure as `AFError.sessionTaskFailed(error:)`.
    public static func error(_ code: URLError.Code) -> MockResponse {
        MockResponse(error: URLError(code))
    }

    /// A redirect response with a `Location` header.
    ///
    /// ```swift
    /// mock.on(.get("/old")).respond(.redirect(to: "/new"))
    /// mock.on(.get("/new")).respond(.text("moved"))
    /// ```
    ///
    /// - Note: The mock transport reports the redirect to URLSession, which follows it
    ///   through the mock again — so both the original and redirected requests are recorded,
    ///   and Alamofire's `redirectHandler` and interceptors observe the redirect exactly as
    ///   they would for a real server. Set ``MockServer/followsRedirects`` to `false` to
    ///   deliver the `3xx` response unchanged.
    public static func redirect(
        to location: String,
        status: Int = 302,
        headers: [String: String] = [:]
    ) -> MockResponse {
        let merged = headers.withDefaultValue(for: "Location", value: location)
        return MockResponse(status: status, headers: merged)
    }

    // MARK: - Modifiers

    /// Returns a copy of the response with an artificial delay in seconds.
    public func delayed(by seconds: TimeInterval) -> MockResponse {
        var copy = self
        copy.delay = max(0, seconds)
        return copy
    }

    /// Returns a copy of the response with a different status code.
    public func with(status statusCode: Int) -> MockResponse {
        var copy = self
        copy.statusCode = statusCode
        return copy
    }

    /// Returns a copy of the response with an added (or replaced) header.
    public func with(header name: String, _ value: String) -> MockResponse {
        var copy = self
        copy.headers[name] = value
        return copy
    }

    /// Returns a copy of the response with additional headers.
    public func with(headers additionalHeaders: [String: String]) -> MockResponse {
        var copy = self
        for (name, value) in additionalHeaders {
            copy.headers[name] = value
        }
        return copy
    }

    /// Returns a copy of the response with a replaced body.
    public func with(body data: Data) -> MockResponse {
        var copy = self
        copy.body = data
        return copy
    }

    // MARK: - Internal

    /// Builds the `HTTPURLResponse` delivered to URLSession.
    func makeHTTPResponse(for url: URL) -> HTTPURLResponse? {
        var fields = headers

        if !body.isEmpty, fields.value(forHeader: "Content-Length") == nil {
            fields["Content-Length"] = String(body.count)
        }

        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fields
        )
    }

    private static func jsonSerializationFailure(
        _ error: Error,
        headers: [String: String],
        status: Int
    ) -> MockResponse {
        let message = """
            MockResponse.json could not serialize the provided object: \(error)
            """
        return MockResponse(
            status: status == 200 ? 500 : status,
            headers: headers.withDefaultValue(
                for: "X-Alamock-Error",
                value: "json-serialization-failed"
            ).withDefaultValue(for: "Content-Type", value: "text/plain; charset=utf-8"),
            body: Data(message.utf8)
        )
    }
}

/// Internal reason recorded when a JSON value cannot be represented by `JSONSerialization`.
private enum JSONValueNotRepresentableError: Error, CustomStringConvertible {
    case unsupportedValue

    var description: String {
        "the value contains a type that JSONSerialization cannot represent"
    }
}

// MARK: - Header helpers
extension Dictionary where Key == String, Value == String {
    /// Case-insensitive header lookup.
    func value(forHeader name: String) -> String? {
        if let exact = self[name] {
            return exact
        }
        return first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Returns a copy of the dictionary with `value` inserted for `name` unless a header
    /// with the same (case-insensitive) name already exists.
    func withDefaultValue(for name: String, value: String) -> [String: String] {
        guard self.value(forHeader: name) == nil else { return self }
        var copy = self
        copy[name] = value
        return copy
    }
}
