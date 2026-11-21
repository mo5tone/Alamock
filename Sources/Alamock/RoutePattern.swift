//
//  RoutePattern.swift
//  Alamock
//

/// A method and path pattern that identifies a route or a set of recorded requests.
///
/// `RoutePattern` is the argument of ``MockServer/on(_:)-`` and the shorthand form of
/// ``MockServer/verify(_:times:)-``. Build one from a static factory:
///
/// ```swift
/// mock.on(.get("/users/:id")).respond(.json(["id": 42, "name": "Ada"]))
/// #expect(mock.verify(.get("/users/:id")).isSatisfied)
/// ```
///
/// Both components are optional, and an omitted component matches anything:
///
/// ```swift
/// .get("/users/42")   // GET /users/42
/// .get()              // any GET request
/// .any("/webhooks")   // any method on /webhooks
/// .any                // every request
/// ```
public struct RoutePattern: Hashable, Sendable {
    /// The HTTP method to match, or `nil` for any method.
    public let method: HTTPMethod?

    /// The path pattern to match, or `nil` for any path.
    ///
    /// `:name` captures a segment, `*` matches one segment, and a trailing `**` matches
    /// the remainder. A query string (e.g. `"/search?q=swift"`) adds required query items.
    public let path: String?

    /// Creates a pattern.
    ///
    /// - Parameters:
    ///   - method: The HTTP method to match, or `nil` for any method.
    ///   - path: The path pattern to match, or `nil` for any path.
    public init(method: HTTPMethod? = nil, path: String? = nil) {
        self.method = method
        self.path = path
    }

    /// Matches any method and any path.
    public static let any = RoutePattern()

    /// Matches any method against the given path pattern.
    public static func any(_ path: String? = nil) -> RoutePattern {
        RoutePattern(path: path)
    }

    /// Matches a `CONNECT` request against the given path pattern.
    public static func connect(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .connect, path: path)
    }

    /// Matches a `DELETE` request against the given path pattern.
    public static func delete(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .delete, path: path)
    }

    /// Matches a `GET` request against the given path pattern.
    public static func get(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .get, path: path)
    }

    /// Matches a `HEAD` request against the given path pattern.
    public static func head(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .head, path: path)
    }

    /// Matches an `OPTIONS` request against the given path pattern.
    public static func options(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .options, path: path)
    }

    /// Matches a `PATCH` request against the given path pattern.
    public static func patch(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .patch, path: path)
    }

    /// Matches a `POST` request against the given path pattern.
    public static func post(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .post, path: path)
    }

    /// Matches a `PUT` request against the given path pattern.
    public static func put(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .put, path: path)
    }

    /// Matches a `QUERY` request against the given path pattern.
    public static func query(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .query, path: path)
    }

    /// Matches a `TRACE` request against the given path pattern.
    public static func trace(_ path: String? = nil) -> RoutePattern {
        RoutePattern(method: .trace, path: path)
    }
}
