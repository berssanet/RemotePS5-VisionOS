//
//  Logger.swift
//  VisionRemotePS5
//
//  Centralized debug logging that compiles away in Release builds.
//  Use DebugLog for all non-critical prints to eliminate hot-path overhead.
//

import Foundation

/// Lightweight debug logging utility.
/// All methods are no-ops in Release builds (compiled out via `#if DEBUG`).
enum DebugLog {
    
    /// Standard info log — only prints in Debug builds.
    @inline(__always)
    static func info(_ tag: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(tag)] \(message())")
        #endif
    }
    
    /// Error log — always prints (errors should be visible in all builds).
    @inline(__always)
    static func error(_ tag: String, _ message: @autoclosure () -> String) {
        print("[\(tag)] ❌ \(message())")
    }
    
    /// Warning log — only prints in Debug builds.
    @inline(__always)
    static func warning(_ tag: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        print("[\(tag)] ⚠️ \(message())")
        #endif
    }
    
    /// Drop-in replacement for bare `print` in app code (Phase 4.1 / 5.24):
    /// identical call syntax, but the console I/O compiles out of Release
    /// builds. Prefer `info`/`warning`/`error` with a tag for new code.
    @inline(__always)
    static func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        #if DEBUG
        Swift.print(items.map { String(describing: $0) }.joined(separator: separator),
                    terminator: terminator)
        #endif
    }

    /// Throttled log — only prints every `n` calls. Useful for per-frame stats.
    /// - Parameters:
    ///   - counter: The current frame/call counter value.
    ///   - interval: Print every `interval` calls (e.g., 120 = every 2 seconds at 60fps).
    @inline(__always)
    static func every(_ counter: UInt64, interval: UInt64, _ tag: String, _ message: @autoclosure () -> String) {
        #if DEBUG
        if counter % interval == 0 {
            print("[\(tag)] \(message())")
        }
        #endif
    }
}
