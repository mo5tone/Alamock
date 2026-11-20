//
//  IntegrationTests.swift
//  AlamockTests
//

import Alamofire
import XCTest
@testable import Alamock

/// End-to-end tests that drive ``MockServer`` through real Alamofire `Session` instances.
final class IntegrationTests: XCTestCase {
    private var server: MockServer!
    private var session: Session!

    override func setUp() {
        super.setUp()
        server = MockServer(name: "IntegrationTests")
        session = server.makeSession()
    }

    override func tearDown() {
        session.session.invalidateAndCancel()
        session = nil
        server.reset()
        server = nil
        super.tearDown()
    }

    // MARK: - Basic requests

    func testAsyncGetDecodesJSON() async throws {
        server.onGet("/users/:id").respond(.json(["id": "42", "name": "Ada"]))

        let user = try await session.request("https://api.example.com/users/42")
            .serializingDecodable([String: String].self)
            .value

        XCTAssertEqual(user, ["id": "42", "name": "Ada"])
        XCTAssertEqual(server.recordedRequests.count, 1)
        XCTAssertEqual(server.recordedRequests.first?.pathParameters["id"], "42")
    }

    func testCompletionHandlerAPI() {
        server.onGet("/hello").respond(.text("world"))

        let expectation = expectation(description: "request completed")
        session.request("https://api.example.com/hello").responseString { response in
            XCTAssertEqual(response.value, "world")
            XCTAssertEqual(response.response?.statusCode, 200)
            XCTAssertNil(response.error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testStatusAndHeadersAreDelivered() async {
        server.onGet("/created").respond(
            .text("made", status: 201, headers: ["Location": "/created/1", "X-Trace": "abc"])
        )

        let response = await session.request("https://api.example.com/created")
            .serializingString()
            .response

        XCTAssertEqual(response.response?.statusCode, 201)
        XCTAssertEqual(response.response?.value(forHTTPHeaderField: "Location"), "/created/1")
        XCTAssertEqual(response.response?.value(forHTTPHeaderField: "X-Trace"), "abc")
        XCTAssertEqual(response.value, "made")
    }

    func testDefaultResponseIsEmpty200() {
        server.onGet("/empty")

        let expectation = expectation(description: "empty response")
        session.request("https://api.example.com/empty").response { response in
            XCTAssertEqual(response.response?.statusCode, 200)
            XCTAssertTrue(response.data?.isEmpty ?? true)
            XCTAssertNil(response.error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Encoders and matchers

    func testJSONRequestEncodingIsVisibleToRouteMatcher() async throws {
        server.onPost("/users")
            .matchingJSONBody(["name": "Ada"], subset: true)
            .respond(.json(["id": 7]))

        let created = try await session.request(
            "https://api.example.com/users",
            method: .post,
            parameters: ["name": "Ada", "age": 36],
            encoding: JSONEncoding.default
        )
        .serializingDecodable([String: Int].self)
        .value

        XCTAssertEqual(created, ["id": 7])
        let recorded = try XCTUnwrap(server.recordedRequests.first)
        XCTAssertEqual(recorded.method, .post)
        XCTAssertEqual(recorded.header("Content-Type"), "application/json")
        let body = try recorded.decodeBody([String: JSONValueForTests].self)
        XCTAssertEqual(body["name"]?.string, "Ada")
        XCTAssertEqual(body["age"]?.int, 36)
    }

    func testQueryEncodingIsVisibleToRouteMatcher() async throws {
        server.onGet("/search?q=swift").respond(.text("results"))

        let value = try await session.request(
            "https://api.example.com/search",
            parameters: ["q": "swift"],
            encoding: URLEncoding.default
        )
        .serializingString()
        .value

        XCTAssertEqual(value, "results")
        XCTAssertEqual(server.recordedRequests.first?.query["q"], "swift")
        XCTAssertTrue(server.verify(.get, "/search", times: 1).isSatisfied)
    }

    func testFormRequestEncodingIsVisibleToRouteMatcher() async throws {
        server.onPost("/login")
            .matchingFormBody(["username": "ada", "password": "secret"])
            .respond(.status(204))

        let response = await session.request(
            "https://api.example.com/login",
            method: .post,
            parameters: ["username": "ada", "password": "secret"],
            encoding: URLEncoding.httpBody
        )
        .serializingString()
        .response

        XCTAssertEqual(response.response?.statusCode, 204)
        let body = try XCTUnwrap(server.recordedRequests.first?.bodyString)
        XCTAssertTrue(body.contains("username=ada"), "Unexpected body: \(body)")
        XCTAssertTrue(body.contains("password=secret"), "Unexpected body: \(body)")
    }

    func testHeaderMatching() async throws {
        server.onGet("/private")
            .matchingHeader("Authorization", "Bearer token")
            .respond(.text("ok"))

        let value = try await session.request(
            "https://api.example.com/private",
            headers: ["Authorization": "Bearer token"]
        )
        .serializingString()
        .value

        XCTAssertEqual(value, "ok")
    }

    func testHostMatching() async throws {
        server.onGet("/resource").matchingHost("api.example.com").respond(.text("api"))
        server.onGet("/resource").matchingHost("cdn.example.com").respond(.text("cdn"))

        let api = try await session.request("https://api.example.com/resource")
            .serializingString().value
        let cdn = try await session.request("https://cdn.example.com/resource")
            .serializingString().value

        XCTAssertEqual(api, "api")
        XCTAssertEqual(cdn, "cdn")
    }

    func testRoutesAreEvaluatedLastRegisteredFirst() async throws {
        server.onGet("/value").respond(.text("first"))
        server.onGet("/value").respond(.text("second"))

        let value = try await session.request("https://api.example.com/value")
            .serializingString().value

        XCTAssertEqual(value, "second")
    }

    func testRemovedRouteIsNoLongerMatched() async throws {
        let route = server.onGet("/value").respond(.text("first"))
        route.remove()

        let response = await session.request("https://api.example.com/value")
            .serializingString().response

        XCTAssertEqual(response.response?.statusCode, 500)
        XCTAssertEqual(server.unmatchedRequests.count, 1)
    }

    // MARK: - Dynamic responders and sequences

    func testProviderResponderUsesCapturedPathParameters() async throws {
        server.onGet("/users/:id").respond { request in
            .json(["id": request.pathParameters["id"]!])
        }

        let value = try await session.request("https://api.example.com/users/9")
            .serializingDecodable([String: String].self).value

        XCTAssertEqual(value, ["id": "9"])
    }

    func testResponseSequenceIsConsumedInOrder() async throws {
        server.onGet("/flaky").respond(sequence: [.text("one"), .text("two")])

        let first = try await session.request("https://api.example.com/flaky")
            .serializingString().value
        let second = try await session.request("https://api.example.com/flaky")
            .serializingString().value
        let third = try await session.request("https://api.example.com/flaky")
            .serializingString().value

        XCTAssertEqual(first, "one")
        XCTAssertEqual(second, "two")
        XCTAssertEqual(third, "two", "The last response repeats by default")
    }

    func testResponseSequenceCanBeExhausted() async {
        server.onGet("/once").respond(sequence: [.text("only")], repeatingLast: false)

        let first = try? await session.request("https://api.example.com/once")
            .serializingString().value
        XCTAssertEqual(first, "only")

        do {
            _ = try await session.request("https://api.example.com/once")
                .serializingString().value
            XCTFail("Expected the second request to fail")
        } catch {
            assertMockError(error, code: 2) // responseSequenceExhausted
        }
    }

    func testAsyncProviderErrorFailsRequest() async {
        server.onGet("/throwing").respond { _ in
            throw MockError.invalidResponse(route: "throwing", url: "https://api.example.com/throwing")
        }

        do {
            _ = try await session.request("https://api.example.com/throwing")
                .serializingString().value
            XCTFail("Expected the request to fail")
        } catch {
            assertMockError(error, code: 3) // invalidResponse
        }
    }

    /// Asserts that `error` is Alamofire's `sessionTaskFailed` wrapper around a `MockError`
    /// with the given stable ``MockError/errorCode``.
    ///
    /// `MockError` crosses URLSession's Objective-C boundary as an `NSError`, so identity is
    /// checked through `MockError.errorDomain` rather than a Swift cast.
    private func assertMockError(
        _ error: Error,
        code: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .sessionTaskFailed(underlying)? = error.asAFError else {
            return XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        let nsError = underlying as NSError
        XCTAssertEqual(nsError.domain, MockError.errorDomain, file: file, line: line)
        XCTAssertEqual(nsError.code, code, file: file, line: line)
    }

    // MARK: - Delay, cancellation, timeout

    func testDelayedResponseIsDeliveredAfterDelay() {
        server.onGet("/slow").respond(.text("late").delayed(by: 0.15))

        let expectation = expectation(description: "delayed response")
        let start = Date()
        session.request("https://api.example.com/slow").responseString { response in
            XCTAssertEqual(response.value, "late")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
    }

    func testCancellationStopsDelayedResponse() {
        server.onGet("/cancel").respond(.text("never").delayed(by: 5))

        let expectation = expectation(description: "cancelled")
        let request = session.request("https://api.example.com/cancel")
        request.responseString { response in
            XCTAssertNil(response.value)
            XCTAssertNotNil(response.error)
            expectation.fulfill()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            request.cancel()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testRequestTimeoutIsEnforcedByURLSession() async {
        let configuration = server.makeURLSessionConfiguration()
        configuration.timeoutIntervalForRequest = 0.25
        let timeoutSession = Session(configuration: configuration)
        defer { timeoutSession.session.invalidateAndCancel() }

        server.onGet("/timeout").respond(.text("too late").delayed(by: 5))

        do {
            _ = try await timeoutSession.request("https://api.example.com/timeout")
                .serializingString().value
            XCTFail("Expected a timeout")
        } catch {
            let urlError = (error as? AFError)?.underlyingError as? URLError
            XCTAssertEqual(urlError?.code, .timedOut, "Unexpected error: \(error)")
        }
    }

    // MARK: - Errors

    func testURLErrorResponseFailsRequest() async {
        server.onGet("/offline").respond(.error(.notConnectedToInternet))

        do {
            _ = try await session.request("https://api.example.com/offline")
                .serializingString().value
            XCTFail("Expected a transport error")
        } catch {
            let urlError = (error as? AFError)?.underlyingError as? URLError
            XCTAssertEqual(urlError?.code, .notConnectedToInternet, "Unexpected error: \(error)")
        }
    }

    func testValidationSurfacesHTTPError() async {
        server.onGet("/missing").respond(.json(["error": "not found"], status: 404))

        do {
            _ = try await session.request("https://api.example.com/missing")
                .validate()
                .serializingString().value
            XCTFail("Expected a validation error")
        } catch let error as AFError {
            guard case let .responseValidationFailed(reason) = error,
                  case let .unacceptableStatusCode(code) = reason
            else {
                return XCTFail("Unexpected AFError: \(error)")
            }
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetryPolicyRetriesMockedFailure() async throws {
        let retrySession = server.makeSession(
            interceptor: RetryPolicy(
                retryLimit: 2,
                exponentialBackoffScale: 0,
                retryableHTTPStatusCodes: [500]
            )
        )
        defer { retrySession.session.invalidateAndCancel() }

        server.onGet("/flaky").respond(sequence: [.status(500), .text("recovered")])

        let value = try await retrySession.request("https://api.example.com/flaky")
            .serializingString().value

        XCTAssertEqual(value, "recovered")
        XCTAssertEqual(server.recordedRequests.count, 2)
    }

    // MARK: - Uploads and downloads

    func testUploadDataBodyIsReadable() async throws {
        server.onPost("/upload")
            .matchingTextBody("hello-data")
            .respond(.text("stored"))

        let value = try await session.upload(
            Data("hello-data".utf8),
            to: "https://api.example.com/upload"
        )
        .serializingString().value

        XCTAssertEqual(value, "stored")
        XCTAssertEqual(server.recordedRequests.first?.bodyString, "hello-data")
    }

    func testUploadFileBodyIsReadable() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alamock-upload-\(UUID().uuidString).txt")
        try Data("file-body".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        server.onPost("/upload-file")
            .matchingTextBody("file-body")
            .respond(.text("stored"))

        let value = try await session.upload(fileURL, to: "https://api.example.com/upload-file")
            .serializingString().value

        XCTAssertEqual(value, "stored")
        XCTAssertEqual(server.recordedRequests.first?.bodyString, "file-body")
    }

    func testMultipartUploadBodyIsReadable() async throws {
        server.onPost("/upload-multipart")
            .matchingBody(.predicate { body in
                guard let body, let text = String(data: body, encoding: .utf8) else { return false }
                return text.contains("name=\"file\"")
                    && text.contains("filename=\"hello.txt\"")
                    && text.contains("hello multipart")
            })
            .respond(.json(["uploaded": true]))

        let result = try await session.upload(
            multipartFormData: { form in
                form.append(
                    Data("hello multipart".utf8),
                    withName: "file",
                    fileName: "hello.txt",
                    mimeType: "text/plain"
                )
            },
            to: "https://api.example.com/upload-multipart"
        )
        .serializingDecodable([String: Bool].self)
        .value

        XCTAssertEqual(result, ["uploaded": true])
        XCTAssertEqual(server.recordedRequests.count, 1)
    }

    func testDownloadBodyIsWrittenToDestination() async throws {
        server.onGet("/file").respond(.data(Data("downloaded".utf8)))

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alamock-download-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let destination: DownloadRequest.Destination = { _, _ in
            (destinationURL, [.removePreviousFile])
        }

        let fileURL = try await session.download(
            "https://api.example.com/file",
            to: destination
        )
        .serializingDownloadedFileURL()
        .value

        XCTAssertEqual(fileURL.path, destinationURL.path)
        XCTAssertEqual(try String(contentsOf: destinationURL, encoding: .utf8), "downloaded")
    }

    // MARK: - Redirects

    func testRedirectIsFollowedAndBothHopsAreRecorded() async throws {
        server.onGet("/old").respond(.redirect(to: "/new"))
        server.onGet("/new").respond(.text("moved"))

        let value = try await session.request("https://api.example.com/old")
            .serializingString().value

        XCTAssertEqual(value, "moved")
        XCTAssertEqual(server.recordedRequests.map(\.path), ["/old", "/new"])
        XCTAssertTrue(server.recordedRequests.allSatisfy(\.wasMatched))
    }

    func testRedirectIsNotFollowedWhenDisabled() async {
        server.followsRedirects = false
        server.onGet("/old").respond(.redirect(to: "/new"))
        server.onGet("/new").respond(.text("moved"))

        let response = await session.request("https://api.example.com/old")
            .serializingString().response

        XCTAssertEqual(response.response?.statusCode, 302)
        XCTAssertEqual(response.response?.value(forHTTPHeaderField: "Location"), "/new")
        XCTAssertEqual(server.recordedRequests.map(\.path), ["/old"])
    }

    // MARK: - Isolation and concurrency

    func testTwoServersAreIsolated() async throws {
        let serverA = MockServer(name: "A")
        let serverB = MockServer(name: "B")
        let sessionA = serverA.makeSession()
        let sessionB = serverB.makeSession()
        defer {
            sessionA.session.invalidateAndCancel()
            sessionB.session.invalidateAndCancel()
            serverA.reset()
            serverB.reset()
        }

        serverA.onGet("/who").respond(.text("A"))
        serverB.onGet("/who").respond(.text("B"))

        let values: [String: String] = try await withThrowingTaskGroup(
            of: (String, String).self
        ) { group in
            group.addTask {
                ("A", try await sessionA.request("https://api.example.com/who")
                    .serializingString().value)
            }
            group.addTask {
                ("B", try await sessionB.request("https://api.example.com/who")
                    .serializingString().value)
            }

            var result: [String: String] = [:]
            for try await (name, value) in group {
                result[name] = value
            }
            return result
        }

        XCTAssertEqual(values, ["A": "A", "B": "B"])
        XCTAssertEqual(serverA.recordedRequests.count, 1)
        XCTAssertEqual(serverB.recordedRequests.count, 1)
        XCTAssertTrue(serverA.verify(.get, "/who").isSatisfied)
        XCTAssertTrue(serverB.verify(.get, "/who").isSatisfied)
    }

    func testConcurrentRequestsAreAllRecorded() async throws {
        server.onGet("/items/:id").respond { request in
            .json(["id": request.pathParameters["id"]!])
        }

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await self.session.request("https://api.example.com/items/\(index)")
                        .serializingDecodable([String: String].self)
                        .value["id"]!
                }
            }

            var seen: [String] = []
            for try await id in group {
                seen.append(id)
            }
            return seen
        }

        XCTAssertEqual(Set(ids).count, 20)
        XCTAssertEqual(server.recordedRequests.count, 20)
        XCTAssertTrue(server.verify(.get, "/items/:id", times: 20).isSatisfied)
    }

    func testRequestFailsClosedWhenServerIsDeallocated() {
        var configuration: URLSessionConfiguration!
        do {
            let temporaryServer = MockServer(name: "deallocated")
            temporaryServer.onGet("/x").respond(.text("never"))
            configuration = temporaryServer.makeURLSessionConfiguration()
        }

        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let expectation = expectation(description: "request fails closed")
        urlSession.dataTask(with: URL(string: "https://api.example.com/x")!) { data, response, error in
            XCTAssertNil(data)
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.resume()

        wait(for: [expectation], timeout: 5)
    }

    func testRequestWithoutServerIdentifierFailsClosed() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let expectation = expectation(description: "request fails closed")
        urlSession.dataTask(with: URL(string: "https://api.example.com/x")!) { data, response, error in
            XCTAssertNil(data)
            XCTAssertNil(response)
            XCTAssertNotNil(error)
            expectation.fulfill()
        }.resume()

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Raw URLSession

    func testRawURLSessionConfigurationInterceptsRequests() {
        server.onGet("/raw").respond(.text("raw ok"))

        let urlSession = URLSession(configuration: server.makeURLSessionConfiguration())
        defer { urlSession.invalidateAndCancel() }

        let expectation = expectation(description: "raw request")
        urlSession.dataTask(with: URL(string: "https://api.example.com/raw")!) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "raw ok")
            expectation.fulfill()
        }.resume()

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Unmatched requests

    func testUnmatchedRequestIsRejectedHermetically() async {
        server.onGet("/known").respond(.text("ok"))

        let response = await session.request("https://api.example.com/unknown")
            .serializingString()
            .response

        XCTAssertEqual(response.response?.statusCode, 500)
        XCTAssertEqual(
            response.response?.value(forHTTPHeaderField: "X-Alamock-Error"),
            "unmatched-request"
        )
        let body = try? XCTUnwrap(response.value)
        XCTAssertTrue(body?.contains("No mock route matched") ?? false)
        XCTAssertEqual(server.unmatchedRequests.count, 1)
        XCTAssertTrue(server.hasUnmatchedRequests)
        XCTAssertEqual(server.recordedRequests.count, 1)
    }

    func testUnmatchedRequestCanRespondWithFallback() async {
        server.unmatchedRequestBehavior = .respond(.text("fallback", status: 418))

        let response = await session.request("https://api.example.com/anything")
            .serializingString().response

        XCTAssertEqual(response.response?.statusCode, 418)
        XCTAssertEqual(response.value, "fallback")
        XCTAssertTrue(server.hasUnmatchedRequests)
    }

    func testUnmatchedRequestCanFailWithError() async {
        server.unmatchedRequestBehavior = .failWith(URLError(.notConnectedToInternet))

        do {
            _ = try await session.request("https://api.example.com/anything")
                .serializingString().value
            XCTFail("Expected a transport error")
        } catch {
            let urlError = (error as? AFError)?.underlyingError as? URLError
            XCTAssertEqual(urlError?.code, .notConnectedToInternet, "Unexpected error: \(error)")
        }
    }

    // MARK: - Verification

    func testVerificationReportsMatches() async throws {
        server.onGet("/ping").respond(.text("pong"))

        _ = try await session.request("https://api.example.com/ping").serializingString().value
        _ = try await session.request("https://api.example.com/ping").serializingString().value

        let satisfied = server.verify(.get, "/ping", times: 2)
        XCTAssertTrue(satisfied.isSatisfied)
        XCTAssertEqual(satisfied.actualCount, 2)
        XCTAssertEqual(satisfied.matchingRequests.count, 2)
        XCTAssertTrue(satisfied.wasCalled)

        let unsatisfied = server.verify(.get, "/ping", times: 1)
        XCTAssertFalse(unsatisfied.isSatisfied)
        XCTAssertEqual(unsatisfied.actualCount, 2)
        XCTAssertTrue(unsatisfied.failureMessage.contains("recorded 2"))

        XCTAssertFalse(server.verify(.post, "/ping").isSatisfied)
    }

    func testRecordedRequestsCanBeFilteredByMatcher() async throws {
        server.onGet("/users/:id").respond(.text("ok"))
        server.onPost("/users").respond(.text("created"))

        _ = try await session.request("https://api.example.com/users/1").serializingString().value
        _ = try await session.request("https://api.example.com/users/2").serializingString().value
        _ = try await session.request(
            "https://api.example.com/users",
            method: .post
        ).serializingString().value

        let gets = server.recordedRequests(matching: RequestMatcher(method: .get))
        XCTAssertEqual(gets.count, 2)
        XCTAssertEqual(gets.compactMap { $0.pathParameters["id"] }, ["1", "2"])
    }

    // MARK: - Configuration

    func testConfigurationPreservesBaseSettingsAndStripsRoutingHeader() async throws {
        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 7
        base.httpAdditionalHeaders = ["X-Custom": "custom-value"]

        let configuration = server.makeURLSessionConfiguration(base: base)

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(configuration.httpAdditionalHeaders?["X-Custom"] as? String, "custom-value")
        XCTAssertEqual(
            configuration.httpAdditionalHeaders?[MockURLProtocol.serverIdentifierHeader] as? String,
            server.id.uuidString
        )
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        server.onGet("/custom").respond(.text("ok"))
        let customSession = Session(configuration: configuration)
        defer { customSession.session.invalidateAndCancel() }

        _ = try await customSession.request("https://api.example.com/custom")
            .serializingString().value

        let recorded = try XCTUnwrap(server.recordedRequests.first)
        XCTAssertNil(recorded.header(MockURLProtocol.serverIdentifierHeader))
        XCTAssertEqual(recorded.header("X-Custom"), "custom-value")
    }

    func testMakeSessionWithCustomConfiguration() async throws {
        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 12
        base.httpAdditionalHeaders = ["X-Base": "kept"]

        let customSession = server.makeSession(configuration: base)
        defer { customSession.session.invalidateAndCancel() }

        server.onGet("/configured").respond(.text("ok"))
        let value = try await customSession.request("https://api.example.com/configured")
            .serializingString().value

        XCTAssertEqual(value, "ok")
        XCTAssertEqual(customSession.session.configuration.timeoutIntervalForRequest, 12)
        XCTAssertEqual(
            customSession.session.configuration.httpAdditionalHeaders?["X-Base"] as? String,
            "kept"
        )
        XCTAssertEqual(server.recordedRequests.first?.header("X-Base"), "kept")
    }

    // MARK: - State management

    func testResetClearsRoutesAndRecordings() async throws {
        server.onGet("/x").respond(.text("x"))
        _ = try await session.request("https://api.example.com/x").serializingString().value
        XCTAssertEqual(server.recordedRequests.count, 1)

        server.reset()

        XCTAssertTrue(server.registeredRoutes.isEmpty)
        XCTAssertTrue(server.recordedRequests.isEmpty)
        XCTAssertTrue(server.unmatchedRequests.isEmpty)
        XCTAssertTrue(server.recordedRequests(matching: RequestMatcher()).isEmpty)
    }

    func testResetRecordingsKeepsRoutes() async throws {
        server.onGet("/x").respond(.text("x"))
        _ = try await session.request("https://api.example.com/x").serializingString().value

        server.resetRecordings()

        XCTAssertTrue(server.recordedRequests.isEmpty)
        XCTAssertEqual(server.registeredRoutes.count, 1)

        let value = try await session.request("https://api.example.com/x")
            .serializingString().value
        XCTAssertEqual(value, "x")
    }
}

/// A tiny `Decodable` JSON container used to assert on request bodies in tests.
private struct JSONValueForTests: Decodable {
    let string: String?
    let int: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        string = try? container.decode(String.self)
        int = try? container.decode(Int.self)
    }
}
