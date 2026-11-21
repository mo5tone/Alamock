//
//  MockBodyMatcher.swift
//  Alamock
//

import CoreFoundation
import Foundation

/// Describes the request body a ``MockRoute`` must receive for the route to match.
///
/// ```swift
/// // Exact JSON comparison, ignoring key order and whitespace:
/// mock.on(.post, "/users").match(jsonBody: ["name": "Ada"])
///
/// // Only the listed fields must match:
/// mock.on(.post, "/users").match(jsonBody: ["name": "Ada"], subset: true)
///
/// // Form-encoded bodies:
/// mock.on(.post, "/login").match(formBody: ["user": "ada", "password": "secret"])
///
/// // Anything goes:
/// mock.on(.post, "/raw").match(body: .predicate { $0?.count == 16 })
/// ```
public struct MockBodyMatcher: Sendable, CustomStringConvertible {
    enum Kind {
        case data(Data)
        case text(String)
        case json(expected: Data, subset: Bool)
        case form([String: String])
        case predicate(@Sendable (Data?) -> Bool)
    }

    let kind: Kind
    private let label: String

    private init(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
    }

    // MARK: - Factories

    /// Matches a body that is byte-for-byte identical to `data`.
    public static func data(_ data: Data) -> MockBodyMatcher {
        MockBodyMatcher(kind: .data(data), label: "body data (\(data.count) bytes)")
    }

    /// Matches a UTF-8 body equal to `string`.
    public static func text(_ string: String) -> MockBodyMatcher {
        MockBodyMatcher(kind: .text(string), label: "body text \"\(string)\"")
    }

    /// Matches a JSON body.
    ///
    /// The comparison is semantic: key order, whitespace, and object formatting do not
    /// matter. When `subset` is `false`, the bodies must be deeply equal. When `subset`
    /// is `true`, every field in `object` must exist with an equal value in the request
    /// body, while extra fields are allowed. Nested objects are compared recursively.
    ///
    /// If `object` cannot be serialized to JSON, the matcher never matches and its
    /// description explains the failure.
    public static func json(_ object: Any, subset: Bool = false) -> MockBodyMatcher {
        // Validate inside an array first: `JSONSerialization.data(withJSONObject:)` raises an
        // Objective-C exception (a crash) for unsupported values instead of returning an error.
        guard JSONSerialization.isValidJSONObject([object]) else {
            return MockBodyMatcher(
                kind: .predicate { _ in false },
                label: "invalid JSON matcher (the value contains a type JSONSerialization cannot represent)"
            )
        }

        do {
            let expected = try JSONSerialization.data(
                withJSONObject: object,
                options: [.fragmentsAllowed, .sortedKeys]
            )
            return MockBodyMatcher(
                kind: .json(expected: expected, subset: subset),
                label: subset ? "body JSON subset \(Self.describe(object))" : "body JSON \(Self.describe(object))"
            )
        } catch {
            return MockBodyMatcher(
                kind: .predicate { _ in false },
                label: "invalid JSON matcher (\(error))"
            )
        }
    }

    /// Matches a body that contains every key/value pair in `fields` when parsed as
    /// `application/x-www-form-urlencoded` data. Extra fields are allowed.
    public static func form(_ fields: [String: String]) -> MockBodyMatcher {
        MockBodyMatcher(kind: .form(fields), label: "form body \(fields)")
    }

    /// Matches any body for which `predicate` returns `true`.
    public static func predicate(_ predicate: @escaping @Sendable (Data?) -> Bool) -> MockBodyMatcher {
        MockBodyMatcher(kind: .predicate(predicate), label: "custom body predicate")
    }

    /// Matches any body that decodes as the given type and satisfies `condition`.
    public static func decodable<Value: Decodable & Sendable>(
        _ type: Value.Type,
        decoder: JSONDecoder = JSONDecoder(),
        where condition: @escaping @Sendable (Value) -> Bool
    ) -> MockBodyMatcher {
        MockBodyMatcher(
            kind: .predicate { body in
                guard let body, let value = try? decoder.decode(type, from: body) else { return false }
                return condition(value)
            },
            label: "body decodable as \(type) satisfying a predicate"
        )
    }

    // MARK: - Matching

    /// Returns whether `body` satisfies the matcher.
    public func matches(_ body: Data?) -> Bool {
        switch kind {
        case let .data(expected):
            return body == expected
        case let .text(expected):
            guard let body, let text = String(data: body, encoding: .utf8) else { return false }
            return text == expected
        case let .json(expected, subset):
            guard
                let body,
                let actual = JSONValue(data: body),
                let expectedValue = JSONValue(data: expected)
            else {
                return false
            }
            return subset ? Self.isSubset(expectedValue, of: actual) : expectedValue == actual
        case let .form(expected):
            guard let body, let text = String(data: body, encoding: .utf8) else { return false }
            var components = URLComponents()
            components.query = text
            let actual = components.queryItems ?? []
            return expected.allSatisfy { name, value in
                actual.contains { $0.name == name && $0.value == value }
            }
        case let .predicate(predicate):
            return predicate(body)
        }
    }

    public var description: String { label }

    // MARK: - Private

    private static func describe(_ object: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.fragmentsAllowed, .sortedKeys]
            ),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: object)
        }
        return string
    }

    private static func isSubset(_ expected: JSONValue, of actual: JSONValue) -> Bool {
        switch (expected, actual) {
        case let (.object(expectedFields), .object(actualFields)):
            return expectedFields.allSatisfy { key, expectedValue in
                guard let actualValue = actualFields[key] else { return false }
                return isSubset(expectedValue, of: actualValue)
            }
        case let (.array(expectedItems), .array(actualItems)):
            guard expectedItems.count == actualItems.count else { return false }
            return zip(expectedItems, actualItems).allSatisfy { isSubset($0, of: $1) }
        default:
            return expected == actual
        }
    }
}

// MARK: - JSON value

/// A `Sendable`, `Equatable` representation of a JSON value, used for semantic comparison.
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        self.init(object)
    }

    init?(_ object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var items: [JSONValue] = []
            items.reserveCapacity(array.count)
            for element in array {
                guard let value = JSONValue(element) else { return nil }
                items.append(value)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            var fields: [String: JSONValue] = [:]
            fields.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = JSONValue(element) else { return nil }
                fields[key] = value
            }
            self = .object(fields)
        default:
            return nil
        }
    }
}
