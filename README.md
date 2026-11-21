# Alamock

[![CI](https://github.com/mo5tone/Alamock/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mo5tone/Alamock/actions/workflows/ci.yml)

A pluggable networking mock for [Alamofire](https://github.com/Alamofire/Alamofire) unit tests.

`Alamock` plugs into `URLSession` through its public `URLProtocol` seam, so it works
with the **unmodified** Alamofire stack: `Session`, parameter encoding, response
serializers, `.validate()`, `RetryPolicy`, request interceptors, event monitors, and
`redirectHandler` all run exactly as they do against a real server. Nothing in Alamofire
is subclassed, forked, or patched — mock only the transport.

```swift
mock.onGet("/users/42").respond(.json(["id": 42, "name": "Ada"]))
```

- Routes with method, path patterns, query items, headers, JSON/form bodies, and predicates.
- Canned responses, ordered response sequences (for retries/pagination), and dynamic responders.
- Artificial delays, transport errors, redirects, and arbitrary status codes/headers.
- Full request recording with verification helpers.
- Hermetic by default: unmatched requests fail fast and never reach the network.
- Multiple isolated servers can run concurrently, including in parallel tests.

---

## Requirements

| | |
|---|---|
| Swift | 6.0+ (package `swift-tools-version: 6.0`, Swift 6 language mode) |
| Xcode | 16+ |
| Alamofire | 5.10+ (built and tested against 5.12.2) |
| Platforms | macOS 10.15+, iOS 13+, tvOS 13+, watchOS 6+ |

## Installation

Add the package to your project and link `Alamock` from your **test target**:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.10.2"),
    .package(path: "../Alamock"), // or the package's published URL
],
targets: [
    .testTarget(
        name: "MyAppTests",
        dependencies: ["MyApp", "Alamock"]
    ),
]
```

---

## Quick start

```swift
import Alamofire
import Alamock
import Foundation
import Testing

private struct User: Decodable {
    let id: Int
    let name: String
}

@Suite("UserService")
final class UserServiceTests {
    private let mock: MockServer
    private let session: Session

    init() {
        mock = MockServer(name: "UserServiceTests")
        session = mock.makeSession()
    }

    deinit {
        session.session.invalidateAndCancel()
        mock.reset()
    }

    @Test func loadsUser() async throws {
        mock.onGet("/users/42").respond(.json(["id": 42, "name": "Ada"]))

        let user = try await session
            .request("https://api.example.com/users/42")
            .validate()
            .serializingDecodable(User.self)
            .value

        #expect(user.name == "Ada")

        let verification = mock.verify(.get, "/users/42")
        #expect(verification.isSatisfied, "\(verification.failureMessage)")
    }
}
```

Completion-handler APIs work the same way — the mock is transport-level, not
concurrency-level:

```swift
let response = await withCheckedContinuation { continuation in
    session.request("https://api.example.com/users/42")
        .responseDecodable(of: User.self) { response in
            continuation.resume(returning: response)
        }
}
#expect(response.value?.name == "Ada")
```

## How it plugs in

`MockServer` returns a `URLSessionConfiguration` with three changes:

1. `MockURLProtocol` is inserted at the front of `URLSessionConfiguration.protocolClasses`.
2. The configuration's additional headers carry a private routing header containing the
   server's identifier.
3. The URL cache is disabled and cache policy is forced to reload-ignoring-cache.

```swift
let session = mock.makeSession()            // new ephemeral session wired to the mock
let configuration = mock.makeURLSessionConfiguration(base: .default) // or customize a base
mock.configure(existingConfiguration)       // or wire an existing configuration in place
```

Request flow:

```
test code
  → Alamofire Session  (encoding, validation, retry, serializers, interceptors)
    → URLSession
      → MockURLProtocol                      ← installed via protocolClasses
        → MockServer.resolve(recorded)       ← routes evaluated LIFO
          → MockResponse                     ← delivered to the URLProtocol client
        ← URLSession                         ← redirects are followed through the mock too
      ← Alamofire Session
  ← test code
```

Because the response goes back through URLSession, everything downstream of the transport
behaves normally: status-code validation, `RetryPolicy` retries (each attempt is recorded),
response serializers, redirect handling, and event monitors.

---

## Routing

### Path patterns

| Pattern | Matches | Captures |
|---|---|---|
| `/users` | exactly `/users` | — |
| `/users/:id` | `/users/42`, `/users/ada` | `id` |
| `/files/*/metadata` | `/files/report/metadata` | — |
| `/files/**` | `/files`, `/files/a/b/c.txt` | — |
| `**` (default) | every path | — |

Trailing slashes are ignored. `:name` captures are available as
`RecordedRequest.pathParameters` and inside predicates and responders.

A query string embedded in the path adds required query items:

```swift
mock.onGet("/search?q=swift").respond(.json(["results": []]))
```

### Matching constraints

All constraints are optional and combined with AND. Routes are created with
`on(_:_:)` (explicit method or `nil` for any) and the convenience `onGet`, `onPost`,
`onPut`, `onPatch`, `onDelete`, `onHead`, `onOptions`, `onAnyRequest`.

```swift
mock.onPost("/users/:id")
    .matchingHost("api.example.com")
    .matchingQuery(["notify": "true"])
    .matchingHeader("Authorization", "Bearer token")   // nil value = header must exist
    .matchingJSONBody(["name": "Ada"], subset: true)   // extra fields allowed
    .respond(.json(["id": 1], status: 201))
```

Body matchers:

```swift
.matchingBody(.data(exactBytes))                       // byte-for-byte
.matchingTextBody("hello")                            // exact UTF-8 body
.matchingFormBody(["username": "ada", "password": "secret"]) // form-urlencoded, subset
.matchingJSONBody(["a": 1])                           // semantic JSON equality
.matchingJSONBody(["a": 1], subset: true)             // expected fields must match
.matchingBody(.predicate { $0?.count == 16 })         // arbitrary predicate
.matchingBody(.decodable(LoginRequest.self) { $0.username == "ada" })
```

Predicates run last and see the path parameters captured by the route's pattern:

```swift
mock.onGet("/users/:id").matching { request in
    request.pathParameters["id"] == "42"
}
```

### Route order

Routes are evaluated in **reverse registration order**: the most recently registered
matching route wins. This makes it easy for a test to override a route registered in
`setUp()`:

```swift
mock.onGet("/ping").respond(.text("default"))
// later in a test:
let override = mock.onGet("/ping").respond(.text("override")) // wins
override.remove()                                             // back to "default"
```

---

## Responding

### Canned responses

```swift
.respond(.json(["ok": true]))                          // 200, application/json
.respond(.json(user))                                  // 200, any Encodable value
.respond(.text("hello"))                               // 200, text/plain; charset=utf-8
.respond(.data(bytes))                                 // 200, raw bytes
.respond(.empty(status: 204))                          // no body
.respond(.status(503))                                 // status only
.respond(.error(.notConnectedToInternet))              // transport failure (URLError)
.respond(.redirect(to: "/new-location"))               // 302 + Location
```

Modifiers return a copy:

```swift
.respond(
    .json(["error": "rate limited"])
        .withStatus(429)
        .withHeader("Retry-After", "1")
        .delayed(by: 0.2)
)
```

### Response sequences

For retry, pagination, and token-refresh scenarios:

```swift
mock.onGet("/flaky").respond(sequence: [.status(500), .text("ok")])

mock.onGet("/paged").respond(
    sequence: [.json(["page": 1]), .json(["page": 2])],
    repeatingLast: false // further requests fail with .responseSequenceExhausted
)
```

### Dynamic responders

```swift
mock.onGet("/users/:id").respond { request in
    let id = request.pathParameters["id"] ?? "unknown"
    return .json(["id": id])
}

mock.onPost("/login").respond { request in
    request.jsonBody()?["password"] as? String == "secret"
        ? .json(["token": "abc"])
        : .status(401)
}
```

Throwing from a responder fails the request with the thrown error. Responders run on
URLSession's protocol thread, so keep them fast and thread-safe.

---

## Recording and verifying

Every request that reaches a server is recorded, matched or not:

```swift
mock.recordedRequests                 // [RecordedRequest] in arrival order
mock.unmatchedRequests                // requests no route matched
mock.hasUnmatchedRequests             // convenience flag
mock.recordedRequests(matching: RequestMatcher(method: .post, path: "/login"))
mock.resetRecordings()                // keep routes, drop recordings
mock.reset()                          // drop routes, recordings, and restore defaults
```

`RecordedRequest` exposes `method`, `url`, `headers`, `body`, `bodyString`,
`path`, `query`, `queryItems`, `host`, `header(_:)`, `jsonBody()`,
`decodeBody(_:)`, `pathParameters`, `matchedRoute`, and `wasMatched`.

Verification is deliberately framework-agnostic; assert on `isSatisfied` or `actualCount`:

```swift
let verification = mock.verify(.post, "/login", times: 2)
#expect(verification.isSatisfied, "\(verification.failureMessage)")

// Or with full matcher control:
let matcher = RequestMatcher(method: .get, path: "/users/:id", headers: ["X-Env": "test"])
#expect(mock.verify(matcher, times: 1).actualCount == 1)
```

`MockVerification` also provides `matchingRequests`, `wasCalled`, and `failureMessage`
(which lists the recorded matching requests).

## Unmatched requests

The default behavior is **reject**: the request fails fast with a `500` response whose
JSON body lists the registered routes and whose header
`X-Alamock-Error: unmatched-request` marks the mistake. It never hits the network,
so a missing stub fails the test instead of silently making a real request.

Alternatives:

```swift
mock.unmatchedRequestBehavior = .respond(.status(404))
// or
mock.unmatchedRequestBehavior = .failWith(URLError(.notConnectedToInternet))
```

## Multiple servers, existing sessions, and shared setups

Each `MockServer` has a unique identifier injected into its session's routing header, so
several servers can be active at once without interfering:

```swift
let publicAPI = MockServer(name: "PublicAPI")
let authAPI = MockServer(name: "AuthAPI")

let publicSession = publicAPI.makeSession()
let authSession = authAPI.makeSession()
```

For a process-wide default server, use `MockServer.shared` and reset it between tests.

To keep production-like session settings, build on top of an existing configuration:

```swift
let base = URLSessionConfiguration.ephemeral
base.timeoutIntervalForRequest = 5
let retry = RetryPolicy(retryLimit: 3, exponentialBackoffScale: 0)
let session = mock.makeSession(configuration: base, interceptor: retry)
```

Raw `URLSession` works too — no Alamofire required for the mock itself:

```swift
let urlSession = URLSession(configuration: mock.makeURLSessionConfiguration())
```

Keep the server referenced for as long as its sessions are used. The registry holds
servers weakly; a request whose server has been deallocated fails closed with
`MockError.serverUnavailable` rather than reaching the network.

## Thread safety

All public mock types are `Sendable`; route, recording, and behavior state is protected by
locks. Concurrent requests against one server, and parallel test execution with separate
servers, are safe. `swift test --parallel` passes.

The package is built in **Swift 6 language mode**, so strict concurrency is checked at every
call site rather than opt-in. Public value types (`MockResponse`, `RequestMatcher`,
`MockBodyMatcher`, `RecordedRequest`, …) conform to checked `Sendable`; the `@unchecked`
conformances are limited to the lock-protected reference types (`MockServer`, `MockRoute`,
`MockServerRegistry`, and the internal response sequence).

## Limitations

- **Hermetic by design.** Configured sessions never contact a real server.
- **Background sessions are not supported.** Custom `URLProtocol` classes are not used for
  background `URLSession` configurations; use a foreground session in tests.
- **WebSocket tasks are not intercepted.** `URLSessionWebSocketTask` bypasses `URLProtocol`.
- **No streaming fidelity.** Request bodies are read fully (including upload task bodies
  delivered through `httpBodyStream`), and each response body is delivered in one
  `didLoad` chunk; `URLSession.bytes()`-style incremental delivery is not emulated.
- **Metrics are not synthesized.** Don't assert on `URLSessionTaskMetrics` timings or
  connection information.
- **No real authentication challenges.** TLS/server-trust, client certificates, and
  challenge-based auth never occur because there is no connection.
- **Reserved header.** `X-Alamock-Server-ID` is an implementation detail; it is
  stripped from recorded requests.
- **Timeouts are URLSession's.** A delayed mock response beyond
  `timeoutIntervalForRequest` fails with `NSURLErrorTimedOut`.
- **Redirects** are handed to URLSession and followed through the mock, so both hops are
  recorded; set `mock.followsRedirects = false` to receive the raw `3xx`. Sensitive headers
  (`Authorization`, `Cookie`, `Proxy-Authorization`) are dropped on cross-host redirects,
  matching normal URLSession behavior.

## Development

The repository pins its non-Xcode tooling with [mise](https://mise.jdx.dev/):
[`.mise.toml`](.mise.toml) installs SwiftLint and defines the tasks below. Swift and
swift-format come from Xcode. Install the pins once, then `mise tasks` lists every task.

```bash
mise install           # install SwiftLint 0.65.1
mise run format        # rewrite Sources, Tests and Package.swift with swift-format
mise run format-check  # fail if anything is not formatted
mise run lint          # SwiftLint --strict + the swift-format check
mise run test          # swift test --parallel
mise run verify        # everything CI enforces: lint + tests
mise run hooks         # install the commit-msg hook (Conventional Commits)
mise run setup         # install tools and hooks in one step
```

Formatting and linting are CI gates, so run `mise run format` before pushing and
`mise run verify` before opening a pull request. Commit messages and pull request titles
follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/); see
[CONTRIBUTING.md](CONTRIBUTING.md) for the type/scope vocabulary, the hook setup and
the squash-merge policy.

Test coverage includes routing and matching, response types, sequences, delays,
cancellation, timeouts, retries, uploads (data/file/multipart), downloads, redirects,
raw `URLSession` interception, configuration preservation, fail-closed behavior,
concurrent requests, and multi-server isolation.

Source layout:

```
Sources/Alamock/
├── MockServer.swift          # server, configuration wiring, routing, recordings, verification
├── MockRoute.swift           # route matching + responders
├── MockURLProtocol.swift     # URLProtocol bridge (transport replacement)
├── MockResponse.swift        # response descriptions, builders, modifiers
├── MockBodyMatcher.swift     # request body matchers
├── MockPathPattern.swift     # :param / * / ** path patterns
├── RequestMatcher.swift      # composable matcher (routes + verification)
├── RecordedRequest.swift     # recorded request snapshot
├── MockVerification.swift    # verification result
├── MockError.swift           # mock transport errors (NSError domain)
└── Internal/                 # locking + weak server registry
```

## Continuous integration and releases

Every push to `main` and every pull request runs the workflows in
[`.github/workflows`](.github/workflows):

| Workflow | Job | What it enforces |
|---|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | **Build & test** | `swift build` (debug), `swift build -c release`, then `swift test --parallel`; runs only after the static checks pass. |
| [`ci.yml`](.github/workflows/ci.yml) | **Lint & format** | `mise run lint`: SwiftLint `--strict` plus the swift-format check. |
| [`ci.yml`](.github/workflows/ci.yml) | **Conventional Commits** | Every non-merge commit the push or pull request adds, via `scripts/validate-conventional-commits.sh`. |
| [`pr-title.yml`](.github/workflows/pr-title.yml) | **Validate PR title** | The pull request title, which becomes the squash commit subject on `main`. |
| [`release.yml`](.github/workflows/release.yml) | **Test & publish** | Static checks, a release build and release-mode tests, then a GitHub Release for a `vX.Y.Z` tag. |

The toolchain is pinned so that a local `mise run verify` and CI agree: Xcode 27.2
(Swift 6.4.2, swift-format 6.4.4) on the GitHub-hosted `xcode-27` image, and SwiftLint
0.65.1 from [`.mise.toml`](.mise.toml) installed by `jdx/mise-action` with mise 2026.9.6.
Each job prints the resolved versions and fails with an explicit error when the image
drifts — bump the `PINNED_*` values in the workflow, the SwiftLint pin in `.mise.toml`
and the version table in [CONTRIBUTING.md](CONTRIBUTING.md#requirements) together.
`xcode-27` is a public preview image: if it ever stops providing the pinned Xcode, move
the jobs to `macos-26` and drop the format gate for that pass, rather than letting CI
format with a different toolchain.

Releasing is a tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

`release.yml` accepts `vMAJOR.MINOR.PATCH` (optionally `-prerelease`/`+build`), runs
`swift test -c release`, and then publishes a GitHub Release with generated notes for
that tag. A tag that is not semver, or a failing suite, publishes nothing; no binaries are
attached, because SwiftPM resolves the package by tag. The version in `Package.swift` is
not rewritten by the workflow.

Pull requests land as a single squashed commit titled by the pull request title and
described by its body, so `main` stays a linear list of Conventional Commits. See
[CONTRIBUTING.md](CONTRIBUTING.md#pull-requests) for the branch, title, and review rules.

## License

MIT. See [LICENSE](LICENSE).
