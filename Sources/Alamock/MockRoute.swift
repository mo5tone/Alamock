//
//  MockRoute.swift
//  Alamock
//

import Foundation

/// A route registered on a ``MockServer``.
///
/// Routes are created with ``MockServer/on(_:_:)-`` and are evaluated in reverse
/// registration order: the most recently registered matching route wins. This makes it
/// easy for a single test to override a route registered in `setUp()`.
///
/// Routes are configured with a chainable API:
///
/// ```swift
/// mock.on(.post, "/users/:id")
///     .matchingHeader("Authorization", "Bearer token")
///     .matchingJSONBody(["name": "Ada"])
///     .respond(.json(["id": 1], status: 201))
/// ```
public final class MockRoute: @unchecked Sendable, CustomStringConvertible {
    /// The required HTTP method, or `nil` for any method.
    public let method: HTTPMethod?

    /// The path pattern this route was registered with.
    public let path: String

    private weak var server: MockServer?
    private let lock = NSLock()
    private var matcher: RequestMatcher
    private var responder: MockResponder
    private var removed = false

    // MARK: - Init

    init(server: MockServer, method: HTTPMethod?, path: String) {
        self.server = server
        self.method = method
        self.path = path
        self.matcher = RequestMatcher(method: method, path: path)
        self.responder = .default
    }

    // MARK: - Matching

    /// The matcher currently describing this route.
    public var requestMatcher: RequestMatcher {
        lock.sync { matcher }
    }

    /// Restricts the route to requests with the given host (case-insensitive).
    @discardableResult
    public func matchingHost(_ host: String) -> Self {
        lock.sync { matcher.host = host }
        return self
    }

    /// Merges additional required query items into the route.
    ///
    /// A value of `nil` requires the query item to be present with any value.
    @discardableResult
    public func matchingQuery(_ queryItems: [String: String?]) -> Self {
        lock.sync {
            matcher.queryItems.merge(queryItems) { _, new in new }
        }
        return self
    }

    /// Requires the given header to be present with the given value.
    ///
    /// Pass `nil` to require presence only. Header names are matched case-insensitively.
    @discardableResult
    public func matchingHeader(_ name: String, _ value: String?) -> Self {
        lock.sync {
            matcher.headers[name] = value
        }
        return self
    }

    /// Merges additional required headers into the route.
    @discardableResult
    public func matchingHeaders(_ headers: [String: String?]) -> Self {
        lock.sync {
            matcher.headers.merge(headers) { _, new in new }
        }
        return self
    }

    /// Requires a body that satisfies `matcher`.
    @discardableResult
    public func matchingBody(_ matcher: MockBodyMatcher) -> Self {
        lock.sync {
            self.matcher.body = matcher
        }
        return self
    }

    /// Requires a JSON body equal to `object` (or containing `object`'s fields when
    /// `subset` is `true`).
    @discardableResult
    public func matchingJSONBody(_ object: Any, subset: Bool = false) -> Self {
        matchingBody(.json(object, subset: subset))
    }

    /// Requires a UTF-8 body equal to `text`.
    @discardableResult
    public func matchingTextBody(_ text: String) -> Self {
        matchingBody(.text(text))
    }

    /// Requires a form-urlencoded body containing the given fields.
    @discardableResult
    public func matchingFormBody(_ fields: [String: String]) -> Self {
        matchingBody(.form(fields))
    }

    /// Adds an arbitrary predicate that is evaluated after all other constraints.
    ///
    /// ```swift
    /// mock.on(.get, "/search").matching { request in
    ///     request.query["q"]?.count ?? 0 > 3
    /// }
    /// ```
    @discardableResult
    public func matching(_ predicate: @escaping @Sendable (RecordedRequest) -> Bool) -> Self {
        lock.sync {
            let existing = matcher.predicate
            if let existing {
                matcher.predicate = { request in
                    existing(request) && predicate(request)
                }
            } else {
                matcher.predicate = predicate
            }
        }
        return self
    }

    // MARK: - Responding

    /// Responds with a fixed ``MockResponse``.
    @discardableResult
    public func respond(_ response: MockResponse) -> Self {
        lock.sync {
            responder = .response(response)
        }
        return self
    }

    /// Responds with a different value for each successive request.
    ///
    /// This is useful for retry, pagination, and token-refresh scenarios:
    ///
    /// ```swift
    /// mock.on(.get, "/flaky").respond(sequence: [.status(500), .json(["ok": true])])
    /// ```
    ///
    /// - Parameters:
    ///   - responses: The responses to deliver in order. Must not be empty.
    ///   - repeatingLast: When `true` (the default), the final response is repeated after
    ///     the sequence is exhausted. When `false`, further requests fail with
    ///     ``MockError/responseSequenceExhausted(route:)``.
    @discardableResult
    public func respond(sequence responses: [MockResponse], repeatingLast: Bool = true) -> Self {
        precondition(!responses.isEmpty, "A response sequence must contain at least one response.")
        let sequence = ResponseSequence(
            responses: responses,
            repeatingLast: repeatingLast,
            route: description
        )
        lock.sync {
            responder = .sequence(sequence)
        }
        return self
    }

    /// Responds using a custom, synchronous provider.
    ///
    /// The provider receives the fully recorded request, including captured path
    /// parameters, so responses can vary by request:
    ///
    /// ```swift
    /// mock.on(.get, "/users/:id").respond { request in
    ///     .json(["id": request.pathParameters["id"]!])
    /// }
    /// ```
    ///
    /// Throwing from the provider fails the request with the thrown error.
    @discardableResult
    public func respond(
        _ provider: @escaping @Sendable (RecordedRequest) throws -> MockResponse
    ) -> Self {
        lock.sync {
            responder = .provider(provider)
        }
        return self
    }

    /// Removes this route from its server.
    public func remove() {
        lock.sync { removed = true }
        server?.removeRoute(self)
    }

    public var description: String {
        requestMatcher.description
    }

    // MARK: - Internal

    func match(_ request: RecordedRequest) -> [String: String]? {
        lock.sync { matcher.match(request) }
    }

    func response(for request: RecordedRequest) throws -> MockResponse {
        let provider = lock.sync { responder }
        return try provider.respond(request)
    }

    var isRemoved: Bool {
        lock.sync { removed }
    }
}

// MARK: - Responder

private struct MockResponder: Sendable {
    let respond: @Sendable (RecordedRequest) throws -> MockResponse

    static let `default` = MockResponder { _ in MockResponse(statusCode: 200) }

    static func response(_ response: MockResponse) -> MockResponder {
        MockResponder { _ in response }
    }

    static func sequence(_ sequence: ResponseSequence) -> MockResponder {
        MockResponder { _ in try sequence.next() }
    }

    static func provider(
        _ provider: @escaping @Sendable (RecordedRequest) throws -> MockResponse
    ) -> MockResponder {
        MockResponder(respond: provider)
    }
}

private final class ResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [MockResponse]
    private let repeatingLast: Bool
    private let route: String
    private var index = 0

    init(responses: [MockResponse], repeatingLast: Bool, route: String) {
        self.responses = responses
        self.repeatingLast = repeatingLast
        self.route = route
    }

    func next() throws -> MockResponse {
        lock.lock()
        defer { lock.unlock() }

        if index < responses.count {
            let response = responses[index]
            index += 1
            return response
        }

        if repeatingLast, let last = responses.last {
            return last
        }

        throw MockError.responseSequenceExhausted(route: route)
    }
}
