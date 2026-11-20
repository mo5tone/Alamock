//
//  MockVerification.swift
//  Alamock
//

import Foundation

/// The result of a ``MockServer/verify(_:times:)-`` assertion.
///
/// Verification is deliberately not tied to XCTest or any other test framework: assert on
/// ``isSatisfied`` (using `XCTAssertTrue(verification.isSatisfied, verification.failureMessage)`)
/// or on ``actualCount``.
public struct MockVerification: Sendable, CustomStringConvertible {
    /// The matcher used for verification.
    public let matcher: RequestMatcher

    /// The number of expected matching requests.
    public let expectedCount: Int

    /// The requests recorded by the server that satisfy `matcher`, in arrival order.
    public let matchingRequests: [RecordedRequest]

    /// Creates a verification result.
    public init(matcher: RequestMatcher, expectedCount: Int, matchingRequests: [RecordedRequest]) {
        self.matcher = matcher
        self.expectedCount = expectedCount
        self.matchingRequests = matchingRequests
    }

    /// The number of requests that actually matched.
    public var actualCount: Int {
        matchingRequests.count
    }

    /// Whether the server recorded exactly `expectedCount` matching requests.
    public var isSatisfied: Bool {
        actualCount == expectedCount
    }

    /// Whether at least one request matched.
    public var wasCalled: Bool {
        actualCount > 0
    }

    /// A message describing the expectation and the requests that were actually recorded.
    ///
    /// Pass this to `XCTAssertTrue` as its failure message:
    ///
    /// ```swift
    /// let verification = mock.verify(.post, "/login")
    /// XCTAssertTrue(verification.isSatisfied, verification.failureMessage)
    /// ```
    public var failureMessage: String {
        var lines = [
            "Expected \(expectedCount) request(s) matching \(matcher), but recorded \(actualCount)."
        ]

        if matchingRequests.isEmpty {
            lines.append("No matching requests were recorded.")
        } else {
            lines.append("Matching requests:")
            lines.append(contentsOf: matchingRequests.map { "  - \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    /// A one-line summary, e.g. `✓ GET /users/1 (1/1)`.
    public var description: String {
        let symbol = isSatisfied ? "✓" : "✗"
        return "\(symbol) \(matcher) (\(actualCount)/\(expectedCount))"
    }
}
