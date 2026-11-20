//
//  MockURLProtocol.swift
//  Alamock
//

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The `URLProtocol` that routes requests to a ``MockServer``.
///
/// You never register this type globally. ``MockServer/configure(_:)`` installs it in the
/// protocol classes of the `URLSessionConfiguration` it returns, and every request in that
/// session is answered by the mock.
///
/// Requests are routed by a private header that ``MockServer`` injects into the session
/// configuration. The header is stripped before requests are recorded, so tests never see
/// it. A request that reaches the protocol without a valid server identifier fails closed
/// (it is never sent to the network), which keeps tests hermetic.
public final class MockURLProtocol: URLProtocol {
    /// The request header used to route requests to the owning ``MockServer``.
    ///
    /// This header is an implementation detail and is removed before requests are recorded.
    public static let serverIdentifierHeader = "X-Alamock-Server-ID"

    private static let deliveryQueue = DispatchQueue(
        label: "org.alamock.delivery",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let stateLock = NSLock()
    private var stopped = false
    private var pendingWork: DispatchWorkItem?

    // MARK: - URLProtocol

    /// The protocol is only installed in sessions that a ``MockServer`` configured, so every
    /// request in those sessions belongs to us. Requests without a server identifier fail
    /// closed in ``startLoading()``.
    public override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        let request = self.request
        let url = request.url ?? URL(string: "about:blank")!
        let routeDescription = "\(request.httpMethod ?? "GET") \(url.path)"

        guard let identifier = request.value(forHTTPHeaderField: Self.serverIdentifierHeader) else {
            finish(with: MockError.serverUnavailable(identifier: "<missing \(Self.serverIdentifierHeader)>"))
            return
        }

        guard let server = MockServerRegistry.shared.server(forIdentifier: identifier) else {
            finish(with: MockError.serverUnavailable(identifier: identifier))
            return
        }

        let body: Data?
        switch Self.readBody(of: request) {
        case .none:
            body = nil
        case let .data(data):
            body = data
        case .failed:
            finish(with: MockError.unreadableRequestBody(route: routeDescription))
            return
        }

        let recorded = RecordedRequest(
            request: request,
            body: body,
            headerFieldsToRemove: [Self.serverIdentifierHeader]
        )

        let resolution = server.resolve(recorded)

        if let error = resolution.error {
            finish(with: error)
            return
        }

        guard let response = resolution.response else {
            finish(with: MockError.invalidResponse(route: routeDescription, url: url.absoluteString))
            return
        }

        deliver(response, for: url, server: server, originalRequest: request)
    }

    public override func stopLoading() {
        stateLock.lock()
        stopped = true
        let work = pendingWork
        pendingWork = nil
        stateLock.unlock()
        work?.cancel()
    }

    // MARK: - Delivery

    private var isStopped: Bool {
        stateLock.sync { stopped }
    }

    private func finish(with error: any Error) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func deliver(
        _ response: MockResponse,
        for url: URL,
        server: MockServer,
        originalRequest: URLRequest
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.perform(response, for: url, server: server, originalRequest: originalRequest)
        }

        guard response.delay > 0 else {
            work.perform()
            return
        }

        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        pendingWork = work
        stateLock.unlock()

        Self.deliveryQueue.asyncAfter(deadline: .now() + response.delay, execute: work)
    }

    private func perform(
        _ response: MockResponse,
        for url: URL,
        server: MockServer,
        originalRequest: URLRequest
    ) {
        guard let client else { return }

        if let error = response.error {
            client.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let httpResponse = response.makeHTTPResponse(for: url) else {
            client.urlProtocol(
                self,
                didFailWithError: MockError.invalidResponse(
                    route: "\(originalRequest.httpMethod ?? "GET") \(url.path)",
                    url: url.absoluteString
                )
            )
            return
        }

        if server.followsRedirects, let redirect = Self.redirectRequest(for: response, from: originalRequest) {
            // Hand the redirect to URLSession. It follows the location, creates a new
            // request through this protocol (so the redirect target is recorded too), and
            // runs Alamofire's redirect handler and interceptors as usual.
            client.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: httpResponse)
            client.urlProtocolDidFinishLoading(self)
            return
        }

        client.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)

        if !response.body.isEmpty {
            client.urlProtocol(self, didLoad: response.body)
        }

        client.urlProtocolDidFinishLoading(self)
    }

    // MARK: - Helpers

    private enum BodyReadResult {
        case none
        case data(Data)
        case failed
    }

    private static func readBody(of request: URLRequest) -> BodyReadResult {
        if let body = request.httpBody {
            return .data(body)
        }

        guard let stream = request.httpBodyStream else {
            return .none
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                return .failed
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return .data(data)
    }

    /// Builds the request URLSession should issue after a redirect.
    ///
    /// `301`, `302`, and `303` switch non-`GET`/`HEAD` requests to `GET` without a body;
    /// `307` and `308` preserve the method and body. Sensitive headers are dropped when the
    /// redirect changes host.
    private static func redirectRequest(
        for response: MockResponse,
        from request: URLRequest
    ) -> URLRequest? {
        let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

        guard redirectStatusCodes.contains(response.statusCode),
            let location = response.headers.value(forHeader: "Location"),
            !location.isEmpty,
            let currentURL = request.url,
            let targetURL = URL(string: location, relativeTo: currentURL)?.absoluteURL,
            targetURL != currentURL
        else {
            return nil
        }

        var redirect = request
        redirect.url = targetURL

        let method = request.httpMethod?.uppercased() ?? "GET"
        let switchesToGET =
            response.statusCode == 303
            || ((response.statusCode == 301 || response.statusCode == 302)
                && method != "GET"
                && method != "HEAD")

        if switchesToGET {
            redirect.httpMethod = "GET"
            redirect.httpBody = nil
            redirect.httpBodyStream = nil
            redirect.setValue(nil, forHTTPHeaderField: "Content-Length")
            redirect.setValue(nil, forHTTPHeaderField: "Content-Type")
        }

        let hostChanged = request.url?.host?.caseInsensitiveCompare(targetURL.host ?? "") != .orderedSame
        if hostChanged {
            for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
                redirect.setValue(nil, forHTTPHeaderField: header)
            }
        }

        return redirect
    }
}
