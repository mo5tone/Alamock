//
//  MatcherTests.swift
//  AlamockTests
//

import Foundation
import Testing
@testable import Alamock

@Suite("MockPathPattern")
struct MockPathPatternTests {
    @Test func exactPath() {
        let pattern = MockPathPattern("/users/42")
        #expect(pattern.captures(in: "/users/42") == [:])
        #expect(pattern.captures(in: "/users/43") == nil)
    }

    @Test func namedSegmentCapture() {
        let pattern = MockPathPattern("/users/:id/posts/:postID")
        #expect(
            pattern.captures(in: "/users/42/posts/7")
                == ["id": "42", "postID": "7"]
        )
        #expect(pattern.captures(in: "/users/42/posts") == nil)
    }

    @Test func singleWildcard() {
        let pattern = MockPathPattern("/files/*/metadata")
        #expect(pattern.captures(in: "/files/report/metadata") == [:])
        #expect(pattern.captures(in: "/files/report/v2/metadata") == nil)
    }

    @Test func doubleWildcardMatchesRemainder() {
        let pattern = MockPathPattern("/files/**")
        #expect(pattern.captures(in: "/files/a/b/c.txt") == [:])
        #expect(pattern.captures(in: "/files") == [:])
    }

    @Test func trailingSlashIsIgnored() {
        let pattern = MockPathPattern("/users/")
        #expect(pattern.captures(in: "/users") == [:])
        #expect(pattern.captures(in: "/users/") == [:])
    }

    @Test func rootPattern() {
        let pattern = MockPathPattern("/")
        #expect(pattern.captures(in: "/") == [:])
    }
}

@Suite("RequestMatcher")
struct RequestMatcherTests {
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

    @Test func matchesMethodAndPath() {
        let request = makeRequest()
        #expect(RequestMatcher(method: .get, path: "/users/:id").matches(request))
        #expect(!RequestMatcher(method: .post, path: "/users/:id").matches(request))
        #expect(!RequestMatcher(method: .get, path: "/users").matches(request))
    }

    @Test func queryStringInPathIsParsed() {
        let request = makeRequest()
        let matcher = RequestMatcher(path: "/users/:id?expand=true")
        #expect(matcher.matches(request))
        #expect(!RequestMatcher(path: "/users/:id?expand=false").matches(request))
        #expect(!RequestMatcher(path: "/users/:id?other").matches(request))
    }

    @Test func queryPresenceWithNilValue() {
        let request = makeRequest()
        #expect(RequestMatcher(path: "/users/42", queryItems: ["expand": nil]).matches(request))
        #expect(!RequestMatcher(path: "/users/42", queryItems: ["missing": nil]).matches(request))
    }

    @Test func headersAreCaseInsensitive() {
        let request = makeRequest(headers: ["X-Token": "secret"])
        #expect(RequestMatcher(path: "/users/42", headers: ["x-token": "secret"]).matches(request))
        #expect(RequestMatcher(path: "/users/42", headers: ["X-TOKEN": nil]).matches(request))
        #expect(!RequestMatcher(path: "/users/42", headers: ["X-Token": "wrong"]).matches(request))
    }

    @Test func jsonSubsetBodyMatching() {
        let body = Data(#"{"name":"Ada","age":36,"active":true}"#.utf8)
        let request = makeRequest(method: .post, body: body)

        #expect(
            RequestMatcher(method: .post, body: .json(["name": "Ada"], subset: true)).matches(request)
        )
        #expect(
            !RequestMatcher(method: .post, body: .json(["name": "Ada"], subset: false)).matches(request)
        )
        #expect(
            RequestMatcher(method: .post, body: .json(["name": "Ada", "age": 36, "active": true]))
                .matches(request)
        )
    }

    @Test func formBodyMatching() {
        let body = Data("name=Ada&role=admin".utf8)
        let request = makeRequest(method: .post, body: body)
        #expect(RequestMatcher(method: .post, body: .form(["name": "Ada"])).matches(request))
        #expect(!RequestMatcher(method: .post, body: .form(["name": "Bob"])).matches(request))
    }

    @Test func predicateIsEvaluated() {
        let request = makeRequest()
        let matcher = RequestMatcher(path: "/users/:id") { request in
            request.pathParameters["id"] == "42"
        }
        #expect(matcher.matches(request))
        #expect(!RequestMatcher(path: "/users/:id") { _ in false }.matches(request))
    }

    @Test func hostMatching() {
        let request = makeRequest()
        #expect(RequestMatcher(host: "api.example.com").matches(request))
        #expect(RequestMatcher(host: "API.EXAMPLE.COM").matches(request))
        #expect(!RequestMatcher(host: "other.example.com").matches(request))
    }
}

@Suite("MockResponse")
struct MockResponseTests {
    @Test func jsonResponseAddsContentTypeAndContentLength() throws {
        let response = MockResponse.json(["ok": true])
        #expect(response.statusCode == 200)
        #expect(response.headers.value(forHeader: "Content-Type") == "application/json")

        let http = try #require(response.makeHTTPResponse(for: URL(string: "https://example.com")!))
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "11")
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func textResponse() {
        let response = MockResponse.text("hello", status: 201)
        #expect(response.statusCode == 201)
        #expect(String(decoding: response.body, as: UTF8.self) == "hello")
        #expect(response.headers.value(forHeader: "Content-Type") == "text/plain; charset=utf-8")
    }

    @Test func statusAndErrorFactories() {
        #expect(MockResponse.status(404).statusCode == 404)
        #expect(MockResponse.error(.timedOut).error?.code == .timedOut)
        #expect(MockResponse.error(.notConnectedToInternet).delay == 0)
    }

    @Test func modifiers() {
        let response = MockResponse.status(200)
            .with(status: 503)
            .with(header: "Retry-After", "1")
            .with(headers: ["Retry-After": "2", "X-A": "1", "X-B": "2"])
            .with(body: Data("body".utf8))
            .delayed(by: 1.5)

        #expect(response.statusCode == 503)
        #expect(response.headers["Retry-After"] == "2")
        #expect(response.headers["X-A"] == "1")
        #expect(response.headers["X-B"] == "2")
        #expect(response.delay == 1.5)
        #expect(String(decoding: response.body, as: UTF8.self) == "body")
    }

    @Test func invalidJSONProducesDiagnostic500() {
        // The `Any` static type selects the JSON-object overload; with `Date` as the static
        // type Swift would instead pick the `Encodable` overload, which serializes it happily.
        let invalid: Any = Date()
        let response = MockResponse.json(invalid)

        #expect(response.statusCode == 500)
        #expect(
            response.headers.value(forHeader: "X-Alamock-Error")
                == "json-serialization-failed"
        )
        #expect(String(decoding: response.body, as: UTF8.self).contains("could not serialize"))
    }

    @Test func jsonScalarFragmentIsSupported() {
        let scalar: Any = "hello"
        let response = MockResponse.json(scalar)

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "\"hello\"")
    }

    @Test func redirectFactory() {
        let response = MockResponse.redirect(to: "/new")
        #expect(response.statusCode == 302)
        #expect(response.headers.value(forHeader: "Location") == "/new")
    }
}

@Suite("MockBodyMatcher")
struct MockBodyMatcherTests {
    @Test func jsonMatchingIsSemantic() {
        let matcher = MockBodyMatcher.json(["a": 1, "b": [true, false]])
        #expect(matcher.matches(Data(#"{"b":[true,false],"a":1}"#.utf8)))
        #expect(!matcher.matches(Data(#"{"a":1,"b":[true,false],"c":3}"#.utf8)))
    }

    @Test func jsonSubsetMatching() {
        let matcher = MockBodyMatcher.json(["a": 1], subset: true)
        #expect(matcher.matches(Data(#"{"a":1,"b":"extra"}"#.utf8)))
        #expect(!matcher.matches(Data(#"{"a":2,"b":"extra"}"#.utf8)))
    }

    @Test func booleansAreNotNumbers() {
        #expect(!MockBodyMatcher.json(["flag": true]).matches(Data(#"{"flag":1}"#.utf8)))
        #expect(!MockBodyMatcher.json(["value": 1]).matches(Data(#"{"value":true}"#.utf8)))
    }

    @Test func invalidJSONValueNeverMatches() {
        let invalid: Any = Date()
        let matcher = MockBodyMatcher.json(invalid)
        #expect(!matcher.matches(Data(#"{"anything":true}"#.utf8)))
        #expect(matcher.description.contains("invalid JSON matcher"))
    }
}
