//
//  ContinuationGate.swift
//  VisionRemotePS5
//
//  Lock-protected one-shot flag guarding CheckedContinuation resumption
//  across racing NWConnection callbacks and timeout closures. Swift 6
//  forbids mutating a captured `var` from concurrently-executing code;
//  this gate provides the same exactly-once semantics safely.
//

import Foundation

final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    /// Returns true exactly once; every later call returns false.
    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}
