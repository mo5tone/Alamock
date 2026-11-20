//
//  MockServer.swift
//  Alamock
//

import Alamofire
import Foundation

/// What a ``MockServer`` does with a request that matches no registered route.
public enum UnmatchedRequestBehavior: Sendable {
    /// Respond with an HTTP `500` diagnostic response listing the registered routes.
    ///
    /// This is the default: unmatched requests never reach the network, so a missing stub
    /// fails the test rather than silently making a real request.
    case reject

    /// Respond with a fixed ``MockResponse``.
    case respond(MockResponse)

    /// Fail the request with a transport-level error.
    case failWith(URLError)
}

/// A stateful, pluggable mock HTTP server for Alamofire unit tests.
///
/// A `MockServer` owns routes, records every request it receives, and is bound to a
/// `URLSession` through a custom `URLProtocol`. Because the mock plugs into URLSession —
/// the only seam Alamofire's public API exposes — the entire Alamofire stack runs
/// unmodified: parameter encoding, response serializers, validation, retriers, and
/// interceptors all behave as they do in production.
///
/// ```swift
/// final class UserServiceTests: XCTestCase {
///     var mock: MockServer!
///     var session: Session!
///
///     override func setUp() {
///         super.setUp()
///         mock = MockServer()
///         session = mock.makeSession()
///         mock.on(.get, "/users/:id").respond(.json(["id": 42, "name": "Ada"]))
///     }
///
///     func testFetchesUser() async throws {
///         let service = UserService(session: session)
///         let user = try await service.user(id: 42)
///         XCTAssertEqual(user.name, "Ada")
///         XCTAssertTrue(mock.verify(.get, "/users/:id").isSatisfied)
///     }
/// }
/// ```
///
/// ## Isolation
///
/// Each server has a unique identifier that is injected into the session configuration's
/// additional headers. Requests are routed to the server that created the session, so
/// multiple servers can run concurrently without interfering with one another.
///
/// ## Route evaluation
///
/// Routes are evaluated in reverse registration order: the route registered most recently
/// wins. This lets a single test override a route installed in `setUp()`.
public final class MockServer: @unchecked Sendable {
    /// A process-wide server suitable for tests that do not need isolation.
    ///
    /// Call ``reset()`` in `setUp()` or `tearDown()` when using it.
    public static let shared = MockServer(name: "Shared")

    /// The unique identifier of this server.
    public let id = UUID()

    /// A human-readable name used in diagnostics.
    public let name: String

    private let lock = NSLock()
    private var routes: [MockRoute] = []
    private var recordings: [RecordedRequest] = []
    private var unmatchedRecordings: [RecordedRequest] = []
    private var behavior: UnmatchedRequestBehavior = .reject
    private var redirectsFollowed = true

    /// Creates and registers a mock server.
    ///
    /// - Parameter name: A human-readable name used in diagnostics.
    public init(name: String = "MockServer") {
        self.name = name
        MockServerRegistry.shared.register(self)
    }

    deinit {
        MockServerRegistry.shared.unregister(identifier: identifier)
    }

    /// The value injected into the private routing header for this server.
    var identifier: String {
        id.uuidString
    }

    // MARK: - Session configuration

    /// Returns a `URLSessionConfiguration` wired to this server.
    ///
    /// The returned configuration:
    /// - installs ``MockURLProtocol`` as the first protocol class,
    /// - injects this server's routing identifier into the additional headers,
    /// - disables the URL cache so responses are always served fresh.
    ///
    /// - Parameter base: The configuration to copy. Defaults to `.ephemeral`.
    public func makeURLSessionConfiguration(
        base: URLSessionConfiguration = .ephemeral
    ) -> URLSessionConfiguration {
        let configuration = base.copy() as? URLSessionConfiguration ?? base
        configure(configuration)
        return configuration
    }

    /// Wires an existing `URLSessionConfiguration` to this server, in place.
    ///
    /// Use this when you need to customize the configuration (timeouts, headers, …) before
    /// creating a session:
    ///
    /// ```swift
    /// let configuration = URLSessionConfiguration.ephemeral
    /// configuration.timeoutIntervalForRequest = 5
    /// mock.configure(configuration)
    /// let session = Session(configuration: configuration)
    /// ```
    public func configure(_ configuration: URLSessionConfiguration) {
        var protocolClasses = configuration.protocolClasses ?? []

        let mockProtocol = ObjectIdentifier(MockURLProtocol.self)
        if !protocolClasses.contains(where: { ObjectIdentifier($0) == mockProtocol }) {
            protocolClasses.insert(MockURLProtocol.self, at: 0)
        }
        configuration.protocolClasses = protocolClasses

        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[MockURLProtocol.serverIdentifierHeader] = identifier
        configuration.httpAdditionalHeaders = headers

        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    }

    /// Creates an Alamofire `Session` wired to this server.
    ///
    /// - Parameter interceptor: An optional request interceptor, e.g. a `RetryPolicy`.
    ///   All interceptors run normally because the mock only replaces the transport.
    public func makeSession(interceptor: (any RequestInterceptor)? = nil) -> Session {
        Session(configuration: makeURLSessionConfiguration(), interceptor: interceptor)
    }

    /// Creates an Alamofire `Session` from a customized configuration and this server.
    ///
    /// Use this to keep production settings such as timeouts, headers, and a custom
    /// `URLSessionDelegate` while routing the session through the mock:
    ///
    /// ```swift
    /// let base = URLSessionConfiguration.ephemeral
    /// base.timeoutIntervalForRequest = 5
    /// let session = mock.makeSession(configuration: base, interceptor: retryPolicy)
    /// ```
    ///
    /// - Parameters:
    ///   - configuration: The configuration to copy and wire to this server.
    ///   - interceptor: An optional request interceptor, e.g. a `RetryPolicy`.
    public func makeSession(
        configuration: URLSessionConfiguration,
        interceptor: (any RequestInterceptor)? = nil
    ) -> Session {
        Session(
            configuration: makeURLSessionConfiguration(base: configuration),
            interceptor: interceptor
        )
    }

    // MARK: - Routes

    /// Registers a route and returns it for configuration.
    ///
    /// - Parameters:
    ///   - method: The method to match, or `nil` for any method.
    ///   - path: A path pattern, evaluated against the request path. `:name` captures a
    ///     segment, `*` matches one segment, and a trailing `**` matches the remainder.
    ///     A query string in `path` (e.g. `"/search?q=swift"`) adds required query items.
    @discardableResult
    public func on(_ method: HTTPMethod? = nil, _ path: String = "**") -> MockRoute {
        let route = MockRoute(server: self, method: method, path: path)
        lock.sync {
            routes.append(route)
        }
        return route
    }

    /// Registers a route that matches any HTTP method.
    @discardableResult
    public func onAnyRequest(_ path: String = "**") -> MockRoute {
        on(nil, path)
    }

    /// Registers a `GET` route.
    @discardableResult
    public func onGet(_ path: String = "**") -> MockRoute {
        on(.get, path)
    }

    /// Registers a `POST` route.
    @discardableResult
    public func onPost(_ path: String = "**") -> MockRoute {
        on(.post, path)
    }

    /// Registers a `PUT` route.
    @discardableResult
    public func onPut(_ path: String = "**") -> MockRoute {
        on(.put, path)
    }

    /// Registers a `PATCH` route.
    @discardableResult
    public func onPatch(_ path: String = "**") -> MockRoute {
        on(.patch, path)
    }

    /// Registers a `DELETE` route.
    @discardableResult
    public func onDelete(_ path: String = "**") -> MockRoute {
        on(.delete, path)
    }

    /// Registers a `HEAD` route.
    @discardableResult
    public func onHead(_ path: String = "**") -> MockRoute {
        on(.head, path)
    }

    /// Registers an `OPTIONS` route.
    @discardableResult
    public func onOptions(_ path: String = "**") -> MockRoute {
        on(.options, path)
    }

    /// The routes currently registered, in registration order.
    public var registeredRoutes: [MockRoute] {
        lock.sync { routes }
    }

    /// Removes a route.
    public func removeRoute(_ route: MockRoute) {
        lock.sync {
            routes.removeAll { $0 === route }
        }
    }

    /// Removes every registered route.
    public func removeAllRoutes() {
        lock.sync {
            routes.removeAll()
        }
    }

    // MARK: - Recordings

    /// Every request the server has received, successfully matched or not, in arrival order.
    public var recordedRequests: [RecordedRequest] {
        lock.sync { recordings }
    }

    /// Requests that did not match any route, in arrival order.
    public var unmatchedRequests: [RecordedRequest] {
        lock.sync { unmatchedRecordings }
    }

    /// Whether any request failed to match a route.
    public var hasUnmatchedRequests: Bool {
        lock.sync { !unmatchedRecordings.isEmpty }
    }

    /// The recorded requests satisfying `matcher`, in arrival order.
    public func recordedRequests(matching matcher: RequestMatcher) -> [RecordedRequest] {
        recordedRequests.filter { matcher.matches($0) }
    }

    /// Verifies how many requests matching `matcher` the server recorded.
    ///
    /// - Parameters:
    ///   - matcher: The request matcher.
    ///   - times: The exact number of expected matches. Defaults to `1`.
    public func verify(_ matcher: RequestMatcher, times: Int = 1) -> MockVerification {
        MockVerification(
            matcher: matcher,
            expectedCount: times,
            matchingRequests: recordedRequests(matching: matcher)
        )
    }

    /// Verifies how many requests with the given method (and optional path pattern) the
    /// server recorded.
    ///
    /// - Parameters:
    ///   - method: The HTTP method to match.
    ///   - path: An optional path pattern. When `nil`, any path matches.
    ///   - times: The exact number of expected matches. Defaults to `1`.
    public func verify(
        _ method: HTTPMethod,
        _ path: String? = nil,
        times: Int = 1
    ) -> MockVerification {
        verify(RequestMatcher(method: method, path: path), times: times)
    }

    // MARK: - Behavior

    /// How unmatched requests are handled. Defaults to ``UnmatchedRequestBehavior/reject``.
    public var unmatchedRequestBehavior: UnmatchedRequestBehavior {
        get { lock.sync { behavior } }
        set { lock.sync { behavior = newValue } }
    }

    /// Whether `3xx` responses carrying a `Location` header are followed.
    ///
    /// When `true` (the default), the mock reports the redirect to URLSession, which
    /// follows it through the mock again — so both the original and redirected requests are
    /// recorded, and Alamofire's `redirectHandler` and interceptors observe the redirect
    /// exactly as they would in production.
    public var followsRedirects: Bool {
        get { lock.sync { redirectsFollowed } }
        set { lock.sync { redirectsFollowed = newValue } }
    }

    /// Clears routes, recordings, unmatched requests, and restores default behavior.
    public func reset() {
        lock.sync {
            routes.removeAll()
            recordings.removeAll()
            unmatchedRecordings.removeAll()
            behavior = .reject
            redirectsFollowed = true
        }
    }

    /// Clears recordings and unmatched requests, keeping routes and behavior.
    public func resetRecordings() {
        lock.sync {
            recordings.removeAll()
            unmatchedRecordings.removeAll()
        }
    }

    // MARK: - Internal

    struct Resolution {
        let request: RecordedRequest
        let response: MockResponse?
        let error: (any Error)?
    }

    func resolve(_ request: RecordedRequest) -> Resolution {
        let (currentRoutes, currentBehavior) = lock.sync { (routes, behavior) }

        for route in currentRoutes.reversed() where !route.isRemoved {
            guard let parameters = route.match(request) else { continue }

            let matched = request.withMatch(
                route: route.requestMatcher.description,
                pathParameters: parameters
            )

            lock.sync {
                recordings.append(matched)
            }

            do {
                return Resolution(
                    request: matched,
                    response: try route.response(for: matched),
                    error: nil
                )
            } catch {
                return Resolution(request: matched, response: nil, error: error)
            }
        }

        lock.sync {
            recordings.append(request)
            unmatchedRecordings.append(request)
        }

        switch currentBehavior {
        case .reject:
            return Resolution(
                request: request,
                response: Self.unmatchedResponse(for: request, routes: currentRoutes),
                error: nil
            )
        case let .respond(response):
            return Resolution(request: request, response: response, error: nil)
        case let .failWith(error):
            return Resolution(request: request, response: nil, error: error)
        }
    }

    private static func unmatchedResponse(
        for request: RecordedRequest,
        routes: [MockRoute]
    ) -> MockResponse {
        let registeredRoutes = routes.reversed().map { $0.requestMatcher.description }

        let payload: [String: Any] = [
            "error": "No mock route matched \(request.method.rawValue) \(request.url.absoluteString)",
            "registeredRoutes": registeredRoutes,
            "hint": "Register a matching route, e.g. mock.on(.get, \"/path\").respond(.json([...]))",
        ]

        return MockResponse.json(payload, status: 500)
            .withHeader("X-Alamock-Error", "unmatched-request")
    }
}
