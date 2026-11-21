//
//  MockPathPattern.swift
//  Alamock
//

import Foundation

/// A lightweight path pattern used by ``RequestMatcher``.
///
/// Patterns are matched against `URL.path` segment by segment:
///
/// - A literal segment matches itself, e.g. `/users`.
/// - `:name` matches exactly one segment and captures it in
///   ``RecordedRequest/pathParameters``. Example: `/users/:id`.
/// - `*` matches exactly one segment without capturing it. Example: `/files/*`.
/// - `**` (allowed only as the final segment) matches zero or more remaining segments.
///   The pattern `**` therefore matches every path.
///
/// Trailing slashes are ignored, so `/users/` is equivalent to `/users`.
///
/// ```swift
/// let pattern = MockPathPattern("/users/:id/repos/*")
/// pattern.captures(in: "/users/42/repos/alamock")
/// // ["id": "42"]
/// ```
public struct MockPathPattern: Sendable, Equatable, CustomStringConvertible {
    /// The pattern exactly as it was provided.
    public let rawValue: String

    private let segments: [Segment]
    private let matchesEverything: Bool

    private enum Segment: Sendable, Equatable {
        case literal(String)
        case parameter(String)
        case wildcard
        case remainder
    }

    /// Creates a path pattern.
    ///
    /// - Parameter pattern: A path such as `/users/:id`. A leading slash is optional.
    public init(_ pattern: String) {
        let raw = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        self.rawValue = pattern

        let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        var parsed: [Segment] = []
        for (index, part) in parts.enumerated() {
            if part == "**" {
                precondition(
                    index == parts.count - 1,
                    "A '**' path segment is only supported as the final segment (pattern: \(pattern))."
                )
                parsed.append(.remainder)
            } else if part == "*" {
                parsed.append(.wildcard)
            } else if part.hasPrefix(":"), part.count > 1 {
                parsed.append(.parameter(String(part.dropFirst())))
            } else {
                parsed.append(.literal(part))
            }
        }

        self.segments = parsed
        self.matchesEverything = parsed == [.remainder]
    }

    /// Attempts to match `path`, returning captured path parameters on success.
    ///
    /// - Parameter path: A percent-decoded path such as `/users/42`.
    /// - Returns: A dictionary of captured `:name` segments, or `nil` when the path does
    ///   not match. An empty dictionary means the path matched without parameters.
    public func captures(in path: String) -> [String: String]? {
        if matchesEverything {
            return [:]
        }

        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        var parameters: [String: String] = [:]
        var pathIndex = 0

        for segment in segments {
            switch segment {
            case .remainder:
                return parameters
            case let .literal(expected):
                guard pathIndex < parts.count, parts[pathIndex] == expected else { return nil }
            case .wildcard:
                guard pathIndex < parts.count else { return nil }
            case let .parameter(name):
                guard pathIndex < parts.count else { return nil }
                parameters[name] = parts[pathIndex]
            }
            pathIndex += 1
        }

        return pathIndex == parts.count ? parameters : nil
    }

    public var description: String { rawValue }
}
