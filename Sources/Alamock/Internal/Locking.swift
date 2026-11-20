//
//  Internal/Locking.swift
//  Alamock
//

import Foundation

extension NSLock {
    /// Runs `body` while holding the lock and returns its result.
    @discardableResult
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
