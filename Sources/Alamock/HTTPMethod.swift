//
//  HTTPMethod.swift
//  Alamock
//

/// The HTTP method of a request.
///
/// Alamock ships its own method type instead of re-exporting Alamofire's, so the core
/// API depends only on Foundation. The constants mirror Alamofire's set; custom or
/// extension methods can be created with ``init(rawValue:)``.
public struct HTTPMethod: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public static let connect = HTTPMethod(rawValue: "CONNECT")
    public static let delete = HTTPMethod(rawValue: "DELETE")
    public static let get = HTTPMethod(rawValue: "GET")
    public static let head = HTTPMethod(rawValue: "HEAD")
    public static let options = HTTPMethod(rawValue: "OPTIONS")
    public static let patch = HTTPMethod(rawValue: "PATCH")
    public static let post = HTTPMethod(rawValue: "POST")
    public static let put = HTTPMethod(rawValue: "PUT")
    public static let query = HTTPMethod(rawValue: "QUERY")
    public static let trace = HTTPMethod(rawValue: "TRACE")

    /// The uppercase method name, e.g. `"GET"`.
    public let rawValue: String

    /// Creates a method from its raw name.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The raw method name.
    public var description: String { rawValue }
}
