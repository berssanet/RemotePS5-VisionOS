//
//  HighFrequencyInputController.swift
//  VisionRemotePS5
//
//  Dedicated 120 Hz input thread. It stays off the main actor on purpose: the tick
//  ends in chiaki_session_set_controller_state. The patched native sender holds
//  its input mutex only to copy state; UDP sends happen outside it. Poll cadence
//  stays independent of display refresh and complements immediate input events.
//

import Foundation
import os

final class HighFrequencyInputController {
    static let tickInterval: TimeInterval = 1.0 / 120.0

    /// Called on the input thread every tick. Must only touch lock-guarded state.
    var onInputReady: (() -> Void)? {
        get { state.withLockUnchecked { $0.tick } }
        set { state.withLockUnchecked { $0.tick = newValue } }
    }

    var isRunning: Bool { state.withLockUnchecked { $0.running } }

    private struct State {
        var running: Bool = false
        /// Bumped per start(); a thread whose generation is stale exits on its next tick.
        var generation: UInt64 = 0
        var tick: (() -> Void)?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private var inputThread: Thread?

    func start() {
        let generation: UInt64? = state.withLockUnchecked { current -> UInt64? in
            if current.running { return nil }
            current.running = true
            current.generation &+= 1
            return current.generation
        }
        guard let generation else { return }
        let thread = Thread { [weak self] in
            self?.runLoop(generation: generation)
        }
        thread.name = "VisionRemotePS5.input.120hz"
        thread.qualityOfService = .userInteractive
        thread.threadPriority = 1.0
        inputThread = thread
        thread.start()
    }

    func stop() {
        state.withLockUnchecked { $0.running = false }
        inputThread = nil
    }

    /// stop() never joins (a tick may be parked behind a UDP send in libchiaki), so a
    /// stop()/start() pair can briefly overlap two threads; the stale one exits here.
    private func runLoop(generation: UInt64) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let tickNanos = UInt64(Self.tickInterval * 1_000_000_000)
        let tickTicks = tickNanos * UInt64(timebase.denom) / UInt64(timebase.numer)
        var deadline = mach_absolute_time()
        while true {
            let snapshot = state.withLockUnchecked { current in
                (current.running && current.generation == generation, current.tick)
            }
            guard snapshot.0 else { return }
            snapshot.1?()
            deadline &+= tickTicks
            let now = mach_absolute_time()
            if deadline > now {
                mach_wait_until(deadline)
            } else {
                deadline = now // fell behind: resync instead of bursting
            }
        }
    }
}
