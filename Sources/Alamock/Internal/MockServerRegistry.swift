//
//  Internal/MockServerRegistry.swift
//  Alamock
//

import Foundation

/// Process-wide mapping from the identifier carried in the private routing header to the
/// live ``MockServer`` that owns it.
///
/// Servers are registered on initialization and removed on deinitialization. Entries are
/// weak: a request that outlives its server fails closed instead of reaching the network.
final class MockServerRegistry: @unchecked Sendable {
    static let shared = MockServerRegistry()

    private struct WeakEntry {
        weak var server: MockServer?
    }

    private let lock = NSLock()
    private var entries: [String: WeakEntry] = [:]

    private init() {}

    func register(_ server: MockServer) {
        lock.sync {
            entries[server.identifier] = WeakEntry(server: server)
        }
    }

    func unregister(identifier: String) {
        lock.sync {
            entries.removeValue(forKey: identifier)
        }
    }

    func server(forIdentifier identifier: String) -> MockServer? {
        lock.sync {
            entries[identifier]?.server
        }
    }

    var registeredServers: [MockServer] {
        lock.sync {
            entries.values.compactMap(\.server)
        }
    }
}
