//
//  AlamofireSupport.swift
//  Alamock
//

import Alamofire
import Foundation

extension MockServer {
    /// The Alamofire-specific conveniences.
    ///
    /// The primary seam is `URLSession`-based — ``makeURLSessionConfiguration(base:)``,
    /// ``configure(_:)``, and ``MockURLProtocol`` — so the mock needs no Alamofire import.
    /// `af` groups the helpers that hand back Alamofire types, making the dependency
    /// visible at the call site (like RxSwift's `.rx`):
    ///
    /// ```swift
    /// import Alamofire
    /// import Alamock
    ///
    /// let mock = MockServer()
    /// let session = mock.af.session()
    /// ```
    public var af: AlamofireSupport { AlamofireSupport(server: self) }
}

extension MockServer {
    /// The Alamofire integration surface of a ``MockServer``, reached through ``af``.
    public struct AlamofireSupport: Sendable {
        private let server: MockServer

        init(server: MockServer) {
            self.server = server
        }

        /// Creates an Alamofire `Session` wired to this server.
        ///
        /// Each call returns a new session; invalidate it when the test finishes.
        ///
        /// - Parameter interceptor: An optional request interceptor, e.g. a `RetryPolicy`.
        ///   All interceptors run normally because the mock only replaces the transport.
        public func session(interceptor: (any RequestInterceptor)? = nil) -> Session {
            Session(
                configuration: server.makeURLSessionConfiguration(),
                interceptor: interceptor
            )
        }

        /// Creates an Alamofire `Session` from a customized configuration and this server.
        ///
        /// Use this to keep production settings such as timeouts, headers, and a custom
        /// `URLSessionDelegate` while routing the session through the mock:
        ///
        /// ```swift
        /// let base = URLSessionConfiguration.ephemeral
        /// base.timeoutIntervalForRequest = 5
        /// let session = mock.af.session(configuration: base, interceptor: retryPolicy)
        /// ```
        ///
        /// - Parameters:
        ///   - configuration: The configuration to copy and wire to this server.
        ///   - interceptor: An optional request interceptor, e.g. a `RetryPolicy`.
        public func session(
            configuration: URLSessionConfiguration,
            interceptor: (any RequestInterceptor)? = nil
        ) -> Session {
            Session(
                configuration: server.makeURLSessionConfiguration(base: configuration),
                interceptor: interceptor
            )
        }
    }
}
