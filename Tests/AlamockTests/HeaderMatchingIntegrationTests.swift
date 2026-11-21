//
//  HeaderMatchingIntegrationTests.swift
//  AlamockTests
//

import Alamofire
import Foundation
import Testing
@testable import Alamock

/// End-to-end tests for header matching through a real Alamofire `Session`.
@Suite("Header matching")
final class HeaderMatchingIntegrationTests {
    private let server: MockServer
    private let session: Session

    init() {
        server = MockServer(name: "HeaderMatchingIntegrationTests")
        session = server.af.session()
    }

    deinit {
        session.session.invalidateAndCancel()
        server.reset()
    }

    @Test func singleHeader() async throws {
        server.on(.get("/private"))
            .match(header: "Authorization", "Bearer token")
            .respond(.text("ok"))

        let value = try await session.request(
            "https://api.example.com/private",
            headers: ["Authorization": "Bearer token"]
        )
        .serializingString()
        .value

        #expect(value == "ok")
    }

    @Test func everyHeaderInPluralFormIsRequired() async throws {
        server.on(.get("/batch"))
            .match(headers: [
                "Authorization": "Bearer token",
                "Accept": "application/json",
            ])
            .respond(.text("ok"))

        let matched = await session.request(
            "https://api.example.com/batch",
            headers: ["Authorization": "Bearer token", "Accept": "application/json"]
        )
        .serializingString()
        .response
        let missing = await session.request(
            "https://api.example.com/batch",
            headers: ["Authorization": "Bearer token"]
        )
        .serializingString()
        .response

        #expect(matched.response?.statusCode == 200)
        #expect(missing.response?.statusCode == 500)
        #expect(server.unmatchedRequests.count == 1)
    }

    @Test func laterHeaderRequirementReplacesEarlier() async throws {
        server.on(.get("/merged"))
            .match(header: "Authorization", "Bearer old")
            .match(headers: ["Authorization": "Bearer new"])
            .respond(.text("merged"))

        let value = try await session.request(
            "https://api.example.com/merged",
            headers: ["Authorization": "Bearer new"]
        )
        .serializingString()
        .value

        #expect(value == "merged")
    }
}
