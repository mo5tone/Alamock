//
//  IntegrationTests.swift
//  AlamockTests
//

import Alamofire
import Foundation
import Testing
@testable import Alamock

/// End-to-end tests that drive ``MockServer`` through real Alamofire `Session` instances.
@Suite("Integration")
final class IntegrationTests {
    private let server: MockServer
    private let session: Session

    init() {
        server = MockServer(name: "IntegrationTests")
        session = server.af.session()
    }

    deinit {
        session.session.invalidateAndCancel()
        server.reset()
    }

    // MARK: - Basic requests

    @Test func asyncGetDecodesJSON() async throws {
        server.on(.get("/users/:id")).respond(.json(["id": "42", "name": "Ada"]))

        let user = try await session.request("https://api.example.com/users/42")
            .serializingDecodable([String: String].self)
            .value

        #expect(user == ["id": "42", "name": "Ada"])
        #expect(server.recordedRequests.count == 1)
        #expect(server.recordedRequests.first?.pathParameters["id"] == "42")
    }

    @Test func completionHandlerAPI() async {
        server.on(.get("/hello")).respond(.text("world"))

        let response = await withCheckedContinuation { continuation in
            session.request("https://api.example.com/hello").responseString { response in
                continuation.resume(returning: response)
            }
        }

        #expect(response.value == "world")
        #expect(response.response?.statusCode == 200)
        #expect(response.error == nil)
    }

    @Test func statusAndHeadersAreDelivered() async {
        server.on(.get("/created")).respond(
            .text("made", status: 201, headers: ["Location": "/created/1", "X-Trace": "abc"])
        )

        let response = await session.request("https://api.example.com/created")
            .serializingString()
            .response

        #expect(response.response?.statusCode == 201)
        #expect(response.response?.value(forHTTPHeaderField: "Location") == "/created/1")
        #expect(response.response?.value(forHTTPHeaderField: "X-Trace") == "abc")
        #expect(response.value == "made")
    }

    @Test func defaultResponseIsEmpty200() async {
        server.on(.get("/empty"))

        let response = await withCheckedContinuation { continuation in
            session.request("https://api.example.com/empty").response { response in
                continuation.resume(returning: response)
            }
        }

        #expect(response.response?.statusCode == 200)
        #expect(response.data?.isEmpty ?? true)
        #expect(response.error == nil)
    }

    // MARK: - Encoders and matchers

    @Test func jsonRequestEncodingIsVisibleToRouteMatcher() async throws {
        server.on(.post("/users"))
            .match(jsonBody: ["name": "Ada"], subset: true)
            .respond(.json(["id": 7]))

        let created = try await session.request(
            "https://api.example.com/users",
            method: .post,
            parameters: ["name": "Ada", "age": 36],
            encoding: JSONEncoding.default
        )
        .serializingDecodable([String: Int].self)
        .value

        #expect(created == ["id": 7])
        let recorded = try #require(server.recordedRequests.first)
        #expect(recorded.method == .post)
        #expect(recorded.header("Content-Type") == "application/json")
        let body = try recorded.decodeBody([String: JSONValueForTests].self)
        #expect(body["name"]?.string == "Ada")
        #expect(body["age"]?.int == 36)
    }

    @Test func queryEncodingIsVisibleToRouteMatcher() async throws {
        server.on(.get("/search?q=swift")).respond(.text("results"))

        let value = try await session.request(
            "https://api.example.com/search",
            parameters: ["q": "swift"],
            encoding: URLEncoding.default
        )
        .serializingString()
        .value

        #expect(value == "results")
        #expect(server.recordedRequests.first?.query["q"] == "swift")
        #expect(server.verify(.get("/search"), times: 1).isSatisfied)
    }

    @Test func formRequestEncodingIsVisibleToRouteMatcher() async throws {
        server.on(.post("/login"))
            .match(formBody: ["username": "ada", "password": "secret"])
            .respond(.status(204))

        let response = await session.request(
            "https://api.example.com/login",
            method: .post,
            parameters: ["username": "ada", "password": "secret"],
            encoding: URLEncoding.httpBody
        )
        .serializingString()
        .response

        #expect(response.response?.statusCode == 204)
        let body = try #require(server.recordedRequests.first?.bodyString)
        #expect(body.contains("username=ada"), "Unexpected body: \(body)")
        #expect(body.contains("password=secret"), "Unexpected body: \(body)")
    }

    @Test func hostMatching() async throws {
        server.on(.get("/resource")).match(host: "api.example.com").respond(.text("api"))
        server.on(.get("/resource")).match(host: "cdn.example.com").respond(.text("cdn"))

        let api = try await session.request("https://api.example.com/resource")
            .serializingString().value
        let cdn = try await session.request("https://cdn.example.com/resource")
            .serializingString().value

        #expect(api == "api")
        #expect(cdn == "cdn")
    }

    @Test func routesAreEvaluatedLastRegisteredFirst() async throws {
        server.on(.get("/value")).respond(.text("first"))
        server.on(.get("/value")).respond(.text("second"))

        let value = try await session.request("https://api.example.com/value")
            .serializingString().value

        #expect(value == "second")
    }

    @Test func removedRouteIsNoLongerMatched() async {
        let route = server.on(.get("/value")).respond(.text("first"))
        route.remove()

        let response = await session.request("https://api.example.com/value")
            .serializingString().response

        #expect(response.response?.statusCode == 500)
        #expect(server.unmatchedRequests.count == 1)
    }

    // MARK: - Dynamic responders and sequences

    @Test func providerResponderUsesCapturedPathParameters() async throws {
        server.on(.get("/users/:id")).respond { request in
            .json(["id": request.pathParameters["id"]!])
        }

        let value = try await session.request("https://api.example.com/users/9")
            .serializingDecodable([String: String].self).value

        #expect(value == ["id": "9"])
    }

    @Test func responseSequenceIsConsumedInOrder() async throws {
        server.on(.get("/flaky")).respond(sequence: [.text("one"), .text("two")])

        let first = try await session.request("https://api.example.com/flaky")
            .serializingString().value
        let second = try await session.request("https://api.example.com/flaky")
            .serializingString().value
        let third = try await session.request("https://api.example.com/flaky")
            .serializingString().value

        #expect(first == "one")
        #expect(second == "two")
        #expect(third == "two", "The last response repeats by default")
    }

    @Test func responseSequenceCanBeExhausted() async {
        server.on(.get("/once")).respond(sequence: [.text("only")], repeatingLast: false)

        let first = try? await session.request("https://api.example.com/once")
            .serializingString().value
        #expect(first == "only")

        do {
            _ = try await session.request("https://api.example.com/once")
                .serializingString().value
            Issue.record("Expected the second request to fail")
        } catch {
            #expect(mockErrorCode(error) == 2, "Unexpected error: \(error)")  // responseSequenceExhausted
        }
    }

    @Test func asyncProviderErrorFailsRequest() async {
        server.on(.get("/throwing")).respond { _ in
            throw MockError.invalidResponse(route: "throwing", url: "https://api.example.com/throwing")
        }

        do {
            _ = try await session.request("https://api.example.com/throwing")
                .serializingString().value
            Issue.record("Expected the request to fail")
        } catch {
            #expect(mockErrorCode(error) == 3, "Unexpected error: \(error)")  // invalidResponse
        }
    }

    /// Returns the stable ``MockError/errorCode`` carried by Alamofire's `sessionTaskFailed`
    /// wrapper, or `nil` when `error` is something else.
    ///
    /// `MockError` crosses URLSession's Objective-C boundary as an `NSError`, so identity is
    /// checked through `MockError.errorDomain` rather than a Swift cast.
    private func mockErrorCode(_ error: Error) -> Int? {
        guard case let .sessionTaskFailed(underlying)? = error.asAFError else {
            return nil
        }
        let nsError = underlying as NSError
        guard nsError.domain == MockError.errorDomain else { return nil }
        return nsError.code
    }

    // MARK: - Delay, cancellation, timeout

    @Test func delayedResponseIsDeliveredAfterDelay() async {
        server.on(.get("/slow")).respond(.text("late").delayed(by: 0.15))

        let start = Date()
        let value = try? await session.request("https://api.example.com/slow")
            .serializingString().value

        #expect(value == "late")
        #expect(Date().timeIntervalSince(start) >= 0.1)
    }

    @Test func cancellationStopsDelayedResponse() async {
        server.on(.get("/cancel")).respond(.text("never").delayed(by: 5))

        let request = session.request("https://api.example.com/cancel")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            request.cancel()
        }

        let response = await withCheckedContinuation { continuation in
            request.responseString { response in
                continuation.resume(returning: response)
            }
        }

        #expect(response.value == nil)
        #expect(response.error != nil)
    }

    @Test func requestTimeoutIsEnforcedByURLSession() async {
        let configuration = server.makeURLSessionConfiguration()
        configuration.timeoutIntervalForRequest = 0.25
        let timeoutSession = Session(configuration: configuration)
        defer { timeoutSession.session.invalidateAndCancel() }

        server.on(.get("/timeout")).respond(.text("too late").delayed(by: 5))

        do {
            _ = try await timeoutSession.request("https://api.example.com/timeout")
                .serializingString().value
            Issue.record("Expected a timeout")
        } catch {
            let urlError = (error as? AFError)?.underlyingError as? URLError
            #expect(urlError?.code == .timedOut, "Unexpected error: \(error)")
        }
    }

    // MARK: - Errors

    @Test func urlErrorResponseFailsRequest() async {
        server.on(.get("/offline")).respond(.error(.notConnectedToInternet))

        do {
            _ = try await session.request("https://api.example.com/offline")
                .serializingString().value
            Issue.record("Expected a transport error")
        } catch {
            let urlError = (error as? AFError)?.underlyingError as? URLError
            #expect(urlError?.code == .notConnectedToInternet, "Unexpected error: \(error)")
        }
    }

    @Test func validationSurfacesHTTPError() async {
        server.on(.get("/missing")).respond(.json(["error": "not found"], status: 404))

        do {
            _ = try await session.request("https://api.example.com/missing")
                .validate()
                .serializingString().value
            Issue.record("Expected a validation error")
        } catch let error as AFError {
            guard case let .responseValidationFailed(reason) = error,
                case let .unacceptableStatusCode(code) = reason
            else {
                Issue.record("Unexpected AFError: \(error)")
                return
            }
            #expect(code == 404)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func retryPolicyRetriesMockedFailure() async throws {
        let retrySession = server.af.session(
            interceptor: RetryPolicy(
                retryLimit: 2,
                exponentialBackoffScale: 0,
                retryableHTTPStatusCodes: [500]
            )
        )
        defer { retrySession.session.invalidateAndCancel() }

        server.on(.get("/flaky")).respond(sequence: [.status(500), .text("recovered")])

        let value = try await retrySession.request("https://api.example.com/flaky")
            .serializingString().value

        #expect(value == "recovered")
        #expect(server.recordedRequests.count == 2)
    }

    // MARK: - Uploads and downloads

    @Test func uploadDataBodyIsReadable() async throws {
        server.on(.post("/upload"))
            .match(textBody: "hello-data")
            .respond(.text("stored"))

        let value = try await session.upload(
            Data("hello-data".utf8),
            to: "https://api.example.com/upload"
        )
        .serializingString().value

        #expect(value == "stored")
        #expect(server.recordedRequests.first?.bodyString == "hello-data")
    }

    @Test func uploadFileBodyIsReadable() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alamock-upload-\(UUID().uuidString).txt")
        try Data("file-body".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        server.on(.post("/upload-file"))
            .match(textBody: "file-body")
            .respond(.text("stored"))

        let value = try await session.upload(fileURL, to: "https://api.example.com/upload-file")
            .serializingString().value

        #expect(value == "stored")
        #expect(server.recordedRequests.first?.bodyString == "file-body")
    }

    @Test func multipartUploadBodyIsReadable() async throws {
        server.on(.post("/upload-multipart"))
            .match(
                body:
                    .predicate { body in
                        guard let body, let text = String(data: body, encoding: .utf8) else { return false }
                        return text.contains("name=\"file\"")
                            && text.contains("filename=\"hello.txt\"")
                            && text.contains("hello multipart")
                    }
            )
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

        #expect(result == ["uploaded": true])
        #expect(server.recordedRequests.count == 1)
    }

    @Test func downloadBodyIsWrittenToDestination() async throws {
        server.on(.get("/file")).respond(.data(Data("downloaded".utf8)))

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

        #expect(fileURL.path == destinationURL.path)
        #expect(try String(contentsOf: destinationURL, encoding: .utf8) == "downloaded")
    }

    // MARK: - Redirects

    @Test func redirectIsFollowedAndBothHopsAreRecorded() async throws {
        server.on(.get("/old")).respond(.redirect(to: "/new"))
        server.on(.get("/new")).respond(.text("moved"))

        let value = try await session.request("https://api.example.com/old")
            .serializingString().value

        #expect(value == "moved")
        #expect(server.recordedRequests.map(\.path) == ["/old", "/new"])
        let allMatched = server.recordedRequests.allSatisfy(\.wasMatched)
        #expect(allMatched)
    }

    @Test func redirectIsNotFollowedWhenDisabled() async {
        server.followsRedirects = false
        server.on(.get("/old")).respond(.redirect(to: "/new"))
        server.on(.get("/new")).respond(.text("moved"))

        let response = await session.request("https://api.example.com/old")
            .serializingString().response

        #expect(response.response?.statusCode == 302)
        #expect(response.response?.value(forHTTPHeaderField: "Location") == "/new")
        #expect(server.recordedRequests.map(\.path) == ["/old"])
    }

    // MARK: - Isolation and concurrency

    @Test func twoServersAreIsolated() async throws {
        let serverA = MockServer(name: "A")
        let serverB = MockServer(name: "B")
        let sessionA = serverA.af.session()
        let sessionB = serverB.af.session()
        defer {
            sessionA.session.invalidateAndCancel()
            sessionB.session.invalidateAndCancel()
            serverA.reset()
            serverB.reset()
        }

        serverA.on(.get("/who")).respond(.text("A"))
        serverB.on(.get("/who")).respond(.text("B"))

        let values: [String: String] = try await withThrowingTaskGroup(
            of: (String, String).self
        ) { group in
            group.addTask {
                (
                    "A",
                    try await sessionA.request("https://api.example.com/who")
                        .serializingString().value
                )
            }
            group.addTask {
                (
                    "B",
                    try await sessionB.request("https://api.example.com/who")
                        .serializingString().value
                )
            }

            var result: [String: String] = [:]
            for try await (name, value) in group {
                result[name] = value
            }
            return result
        }

        #expect(values == ["A": "A", "B": "B"])
        #expect(serverA.recordedRequests.count == 1)
        #expect(serverB.recordedRequests.count == 1)
        #expect(serverA.verify(.get("/who")).isSatisfied)
        #expect(serverB.verify(.get("/who")).isSatisfied)
    }

    @Test func concurrentRequestsAreAllRecorded() async throws {
        server.on(.get("/items/:id")).respond { request in
            .json(["id": request.pathParameters["id"]!])
        }

        // Capture the session locally: `addTask` takes a `sending` closure, and the test
        // instance is not `Sendable`. `Session` is `@unchecked Sendable`, so the local copy
        // can cross into the task group safely.
        let session = self.session

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await session.request("https://api.example.com/items/\(index)")
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

        #expect(Set(ids).count == 20)
        #expect(server.recordedRequests.count == 20)
        #expect(server.verify(.get("/items/:id"), times: 20).isSatisfied)
    }

    @Test func requestFailsClosedWhenServerIsDeallocated() async {
        var configuration: URLSessionConfiguration!
        do {
            let temporaryServer = MockServer(name: "deallocated")
            temporaryServer.on(.get("/x")).respond(.text("never"))
            configuration = temporaryServer.makeURLSessionConfiguration()
        }

        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let outcome = await dataTaskResult(
            urlSession,
            URL(string: "https://api.example.com/x")!
        )
        #expect(outcome.data == nil)
        #expect(outcome.response == nil)
        #expect(outcome.error != nil)
    }

    @Test func requestWithoutServerIdentifierFailsClosed() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }

        let outcome = await dataTaskResult(
            urlSession,
            URL(string: "https://api.example.com/x")!
        )
        #expect(outcome.data == nil)
        #expect(outcome.response == nil)
        #expect(outcome.error != nil)
    }

    // MARK: - Raw URLSession

    @Test func rawURLSessionConfigurationInterceptsRequests() async {
        server.on(.get("/raw")).respond(.text("raw ok"))

        let urlSession = URLSession(configuration: server.makeURLSessionConfiguration())
        defer { urlSession.invalidateAndCancel() }

        let outcome = await dataTaskResult(
            urlSession,
            URL(string: "https://api.example.com/raw")!
        )
        #expect(outcome.error == nil)
        #expect((outcome.response as? HTTPURLResponse)?.statusCode == 200)
        #expect(
            outcome.data.map { String(decoding: $0, as: UTF8.self) } == "raw ok"
        )
    }

    // MARK: - Unmatched requests

    @Test func unmatchedRequestIsRejectedHermetically() async {
        server.on(.get("/known")).respond(.text("ok"))

        let response = await session.request("https://api.example.com/unknown")
            .serializingString()
            .response

        #expect(response.response?.statusCode == 500)
        #expect(
            response.response?.value(forHTTPHeaderField: "X-Alamock-Error")
                == "unmatched-request"
        )
        let body = response.value
        #expect(body?.contains("No mock route matched") ?? false)
        #expect(server.unmatchedRequests.count == 1)
        #expect(server.hasUnmatchedRequests)
        #expect(server.recordedRequests.count == 1)
    }

    @Test func unmatchedRequestCanRespondWithFallback() async {
        server.unmatchedRequestBehavior = .respond(.text("fallback", status: 418))

        let response = await session.request("https://api.example.com/anything")
            .serializingString().response

        #expect(response.response?.statusCode == 418)
        #expect(response.value == "fallback")
        #expect(server.hasUnmatchedRequests)
    }

    @Test func unmatchedRequestCanFailWithError() async {
        server.unmatchedRequestBehavior = .failWith(.notConnectedToInternet)

        do {
            _ = try await session.request("https://api.example.com/anything")
                .serializingString().value
            Issue.record("Expected a transport error")
        } catch {
            let urlError = (error as? AFError)?.underlyingError as? URLError
            #expect(urlError?.code == .notConnectedToInternet, "Unexpected error: \(error)")
        }
    }

    // MARK: - Verification

    @Test func verificationReportsMatches() async throws {
        server.on(.get("/ping")).respond(.text("pong"))

        _ = try await session.request("https://api.example.com/ping").serializingString().value
        _ = try await session.request("https://api.example.com/ping").serializingString().value

        let satisfied = server.verify(.get("/ping"), times: 2)
        #expect(satisfied.isSatisfied)
        #expect(satisfied.actualCount == 2)
        #expect(satisfied.matchingRequests.count == 2)
        #expect(satisfied.wasCalled)

        let unsatisfied = server.verify(.get("/ping"), times: 1)
        #expect(!unsatisfied.isSatisfied)
        #expect(unsatisfied.actualCount == 2)
        #expect(unsatisfied.failureMessage.contains("recorded 2"))

        #expect(!server.verify(.post("/ping")).isSatisfied)
    }

    @Test func routeWithAnyMethodMatchesEveryMethod() async throws {
        server.on(.any("/webhooks")).respond(.text("accepted"))

        let get = try await session.request("https://api.example.com/webhooks")
            .serializingString().value
        let post = try await session.request(
            "https://api.example.com/webhooks",
            method: .post
        ).serializingString().value

        #expect(get == "accepted")
        #expect(post == "accepted")
        #expect(server.verify(.any("/webhooks"), times: 2).isSatisfied)
    }

    @Test func routeWithAnyPathMatchesEveryPath() async throws {
        server.on(.get()).respond(.text("matched"))

        let value = try await session.request("https://api.example.com/deep/path")
            .serializingString().value

        #expect(value == "matched")
        #expect(server.verify(.get(), times: 1).isSatisfied)
    }

    @Test func routeWithAnyPatternMatchesEverything() async throws {
        server.on(.any).respond(.text("any"))

        let value = try await session.request(
            "https://api.example.com/anything",
            method: .put
        ).serializingString().value

        #expect(value == "any")
        #expect(server.verify(.any).isSatisfied)
    }

    @Test func verificationCanMatchAnyPathForAMethod() async throws {
        server.on(.get("/one")).respond(.text("one"))
        server.on(.get("/two")).respond(.text("two"))
        server.on(.post("/three")).respond(.text("three"))

        _ = try await session.request("https://api.example.com/one").serializingString().value
        _ = try await session.request("https://api.example.com/two").serializingString().value
        _ = try await session.request(
            "https://api.example.com/three",
            method: .post
        ).serializingString().value

        #expect(server.verify(.get()).actualCount == 2)
        #expect(server.verify(.post()).actualCount == 1)
        #expect(server.verify(.get("/one")).actualCount == 1)
        #expect(server.verify(.delete()).actualCount == 0)
    }

    @Test func recordedRequestsCanBeFilteredByMatcher() async throws {
        server.on(.get("/users/:id")).respond(.text("ok"))
        server.on(.post("/users")).respond(.text("created"))

        _ = try await session.request("https://api.example.com/users/1").serializingString().value
        _ = try await session.request("https://api.example.com/users/2").serializingString().value
        _ = try await session.request(
            "https://api.example.com/users",
            method: .post
        ).serializingString().value

        let gets = server.recordedRequests(matching: RequestMatcher(method: .get))
        #expect(gets.count == 2)
        #expect(gets.compactMap { $0.pathParameters["id"] } == ["1", "2"])
    }

    // MARK: - Configuration

    @Test func configurationPreservesBaseSettingsAndStripsRoutingHeader() async throws {
        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 7
        base.httpAdditionalHeaders = ["X-Custom": "custom-value"]

        let configuration = server.makeURLSessionConfiguration(base: base)

        #expect(configuration.timeoutIntervalForRequest == 7)
        #expect(configuration.httpAdditionalHeaders?["X-Custom"] as? String == "custom-value")
        #expect(
            configuration.httpAdditionalHeaders?[MockURLProtocol.serverIdentifierHeader] as? String
                == server.id.uuidString
        )
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)

        server.on(.get("/custom")).respond(.text("ok"))
        let customSession = Session(configuration: configuration)
        defer { customSession.session.invalidateAndCancel() }

        _ = try await customSession.request("https://api.example.com/custom")
            .serializingString().value

        let recorded = try #require(server.recordedRequests.first)
        #expect(recorded.header(MockURLProtocol.serverIdentifierHeader) == nil)
        #expect(recorded.header("X-Custom") == "custom-value")
    }

    @Test func sessionWithCustomConfiguration() async throws {
        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 12
        base.httpAdditionalHeaders = ["X-Base": "kept"]

        let customSession = server.af.session(configuration: base)
        defer { customSession.session.invalidateAndCancel() }

        server.on(.get("/configured")).respond(.text("ok"))
        let value = try await customSession.request("https://api.example.com/configured")
            .serializingString().value

        #expect(value == "ok")
        #expect(customSession.session.configuration.timeoutIntervalForRequest == 12)
        #expect(
            customSession.session.configuration.httpAdditionalHeaders?["X-Base"] as? String
                == "kept"
        )
        #expect(server.recordedRequests.first?.header("X-Base") == "kept")
    }

    // MARK: - State management

    @Test func resetClearsRoutesAndRecordings() async throws {
        server.on(.get("/x")).respond(.text("x"))
        _ = try await session.request("https://api.example.com/x").serializingString().value
        #expect(server.recordedRequests.count == 1)

        server.reset()

        #expect(server.registeredRoutes.isEmpty)
        #expect(server.recordedRequests.isEmpty)
        #expect(server.unmatchedRequests.isEmpty)
        #expect(server.recordedRequests(matching: RequestMatcher()).isEmpty)
    }

    @Test func resetRecordingsKeepsRoutes() async throws {
        server.on(.get("/x")).respond(.text("x"))
        _ = try await session.request("https://api.example.com/x").serializingString().value

        server.resetRecordings()

        #expect(server.recordedRequests.isEmpty)
        #expect(server.registeredRoutes.count == 1)

        let value = try await session.request("https://api.example.com/x")
            .serializingString().value
        #expect(value == "x")
    }

    // MARK: - Helpers

    /// The callback arguments of a raw `URLSession` data task.
    private struct DataTaskOutcome {
        let data: Data?
        let response: URLResponse?
        let error: Error?
    }

    /// Runs a raw `URLSession` data task and returns its callback arguments.
    private func dataTaskResult(
        _ urlSession: URLSession,
        _ url: URL
    ) async -> DataTaskOutcome {
        await withCheckedContinuation { continuation in
            urlSession.dataTask(with: url) { data, response, error in
                continuation.resume(
                    returning: DataTaskOutcome(data: data, response: response, error: error)
                )
            }.resume()
        }
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
