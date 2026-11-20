//
//  MatcherTests.swift
//  AlamockTests
//

import Alamofire
import XCTest
@testable import Alamock

final class MockPathPatternTests: XCTestCase {
    func testExactPath() {
        let pattern = MockPathPattern("/users/42")
        XCTAssertEqual(pattern.match(path: "/users/42"), [:])
        XCTAssertNil(pattern.match(path: "/users/43"))
    }

    func testNamedSegmentCapture() {
        let pattern = MockPathPattern("/users/:id/posts/:postID")
        XCTAssertEqual(
            pattern.match(path: "/users/42/posts/7"),
            ["id": "42", "postID": "7"]
        )
        XCTAssertNil(pattern.match(path: "/users/42/posts"))
    }

    func testSingleWildcard() {
        let pattern = MockPathPattern("/files/*/metadata")
        XCTAssertEqual(pattern.match(path: "/files/report/metadata"), [:])
        XCTAssertNil(pattern.match(path: "/files/report/v2/metadata"))
    }

    func testDoubleWildcardMatchesRemainder() {
        let pattern = MockPathPattern("/files/**")
        XCTAssertEqual(pattern.match(path: "/files/a/b/c.txt"), [:])
        XCTAssertEqual(pattern.match(path: "/files"), [:])
    }

    func testTrailingSlashIsIgnored() {
        let pattern = MockPathPattern("/users/")
        XCTAssertEqual(pattern.match(path: "/users"), [:])
        XCTAssertEqual(pattern.match(path: "/users/"), [:])
    }

    func testRootPattern() {
        let pattern = MockPathPattern("/")
        XCTAssertEqual(pattern.match(path: "/"), [:])
    }
}

final class RequestMatcherTests: XCTestCase {
    private func makeRequest(
        method: HTTPMethod = .get,
        url: String = "https://api.example.com/users/42?expand=true",
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> RecordedRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method.rawValue
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return RecordedRequest(request: request, body: body)
    }

    func testMatchesMethodAndPath() {
        let request = makeRequest()
        XCTAssertTrue(RequestMatcher(method: .get, path: "/users/:id").matches(request))
        XCTAssertFalse(RequestMatcher(method: .post, path: "/users/:id").matches(request))
        XCTAssertFalse(RequestMatcher(method: .get, path: "/users").matches(request))
    }

    func testQueryStringInPathIsParsed() {
        let request = makeRequest()
        let matcher = RequestMatcher(path: "/users/:id?expand=true")
        XCTAssertTrue(matcher.matches(request))
        XCTAssertFalse(RequestMatcher(path: "/users/:id?expand=false").matches(request))
        XCTAssertFalse(RequestMatcher(path: "/users/:id?other").matches(request))
    }

    func testQueryPresenceWithNilValue() {
        let request = makeRequest()
        XCTAssertTrue(RequestMatcher(path: "/users/42", queryItems: ["expand": nil]).matches(request))
        XCTAssertFalse(RequestMatcher(path: "/users/42", queryItems: ["missing": nil]).matches(request))
    }

    func testHeadersAreCaseInsensitive() {
        let request = makeRequest(headers: ["X-Token": "secret"])
        XCTAssertTrue(RequestMatcher(path: "/users/42", headers: ["x-token": "secret"]).matches(request))
        XCTAssertTrue(RequestMatcher(path: "/users/42", headers: ["X-TOKEN": nil]).matches(request))
        XCTAssertFalse(RequestMatcher(path: "/users/42", headers: ["X-Token": "wrong"]).matches(request))
    }

    func testJSONSubsetBodyMatching() throws {
        let body = Data(#"{"name":"Ada","age":36,"active":true}"#.utf8)
        let request = makeRequest(method: .post, body: body)

        XCTAssertTrue(
            RequestMatcher(method: .post, body: .json(["name": "Ada"], subset: true)).matches(request)
        )
        XCTAssertFalse(
            RequestMatcher(method: .post, body: .json(["name": "Ada"], subset: false)).matches(request)
        )
        XCTAssertTrue(
            RequestMatcher(method: .post, body: .json(["name": "Ada", "age": 36, "active": true]))
                .matches(request)
        )
    }

    func testFormBodyMatching() {
        let body = Data("name=Ada&role=admin".utf8)
        let request = makeRequest(method: .post, body: body)
        XCTAssertTrue(RequestMatcher(method: .post, body: .form(["name": "Ada"])).matches(request))
        XCTAssertFalse(RequestMatcher(method: .post, body: .form(["name": "Bob"])).matches(request))
    }

    func testPredicateIsEvaluated() {
        let request = makeRequest()
        let matcher = RequestMatcher(path: "/users/:id") { request in
            request.pathParameters["id"] == "42"
        }
        XCTAssertTrue(matcher.matches(request))
        XCTAssertFalse(RequestMatcher(path: "/users/:id") { _ in false }.matches(request))
    }

    func testHostMatching() {
        let request = makeRequest()
        XCTAssertTrue(RequestMatcher(host: "api.example.com").matches(request))
        XCTAssertTrue(RequestMatcher(host: "API.EXAMPLE.COM").matches(request))
        XCTAssertFalse(RequestMatcher(host: "other.example.com").matches(request))
    }
}

final class MockResponseTests: XCTestCase {
    func testJSONResponseAddsContentTypeAndContentLength() throws {
        let response = MockResponse.json(["ok": true])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers.value(forHeader: "Content-Type"), "application/json")

        let http = try XCTUnwrap(response.makeHTTPResponse(for: URL(string: "https://example.com")!))
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "11")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testTextResponse() {
        let response = MockResponse.text("hello", status: 201)
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "hello")
        XCTAssertEqual(response.headers.value(forHeader: "Content-Type"), "text/plain; charset=utf-8")
    }

    func testStatusAndErrorFactories() {
        XCTAssertEqual(MockResponse.status(404).statusCode, 404)
        XCTAssertEqual(MockResponse.error(.timedOut).error?.code, .timedOut)
        XCTAssertEqual(MockResponse.error(.notConnectedToInternet).delay, 0)
    }

    func testModifiers() {
        let response = MockResponse.status(200)
            .withStatus(503)
            .withHeader("Retry-After", "1")
            .withHeaders(["X-A": "1", "X-B": "2"])
            .withBody(Data("body".utf8))
            .delayed(by: 1.5)

        XCTAssertEqual(response.statusCode, 503)
        XCTAssertEqual(response.headers["Retry-After"], "1")
        XCTAssertEqual(response.headers["X-A"], "1")
        XCTAssertEqual(response.headers["X-B"], "2")
        XCTAssertEqual(response.delay, 1.5)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "body")
    }

    func testInvalidJSONProducesDiagnostic500() throws {
        // The `Any` static type selects the JSON-object overload; with `Date` as the static
        // type Swift would instead pick the `Encodable` overload, which serializes it happily.
        let invalid: Any = Date()
        let response = MockResponse.json(invalid)

        XCTAssertEqual(response.statusCode, 500)
        XCTAssertEqual(
            response.headers.value(forHeader: "X-Alamock-Error"),
            "json-serialization-failed"
        )
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("could not serialize"))
    }

    func testJSONScalarFragmentIsSupported() {
        let scalar: Any = "hello"
        let response = MockResponse.json(scalar)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "\"hello\"")
    }

    func testRedirectFactory() {
        let response = MockResponse.redirect(to: "/new")
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.headers.value(forHeader: "Location"), "/new")
    }
}

final class MockBodyMatcherTests: XCTestCase {
    func testJSONMatchingIsSemantic() {
        let matcher = MockBodyMatcher.json(["a": 1, "b": [true, false]])
        XCTAssertTrue(matcher.matches(Data(#"{"b":[true,false],"a":1}"#.utf8)))
        XCTAssertFalse(matcher.matches(Data(#"{"a":1,"b":[true,false],"c":3}"#.utf8)))
    }

    func testJSONSubsetMatching() {
        let matcher = MockBodyMatcher.json(["a": 1], subset: true)
        XCTAssertTrue(matcher.matches(Data(#"{"a":1,"b":"extra"}"#.utf8)))
        XCTAssertFalse(matcher.matches(Data(#"{"a":2,"b":"extra"}"#.utf8)))
    }

    func testBooleansAreNotNumbers() {
        XCTAssertFalse(MockBodyMatcher.json(["flag": true]).matches(Data(#"{"flag":1}"#.utf8)))
        XCTAssertFalse(MockBodyMatcher.json(["value": 1]).matches(Data(#"{"value":true}"#.utf8)))
    }

    func testInvalidJSONValueNeverMatches() {
        let invalid: Any = Date()
        let matcher = MockBodyMatcher.json(invalid)
        XCTAssertFalse(matcher.matches(Data(#"{"anything":true}"#.utf8)))
        XCTAssertTrue(matcher.description.contains("invalid JSON matcher"))
    }
}
