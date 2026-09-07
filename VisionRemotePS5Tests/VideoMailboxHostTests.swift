import Foundation
import CoreVideo

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                             nil, &buffer) == kCVReturnSuccess, "Create test pixel buffer")
    return buffer!
}

let small = pixelBuffer(width: 16, height: 16)
let large = pixelBuffer(width: 64, height: 32)
let smallBytes = CVPixelBufferGetDataSize(small)
let largeBytes = CVPixelBufferGetDataSize(large)
check(smallBytes > 0 && largeBytes > smallBytes, "Known nonzero buffer sizes")

let mailbox = VideoFrameMailbox()
check(mailbox.diagnostics.session == nil && mailbox.diagnostics.occupancy == 0,
      "Legacy mailbox starts empty without a session")
mailbox.submit(small, timestamp: 1)
check(mailbox.diagnostics.disabledSubmissions == 1, "Disabled submission accounted")
mailbox.configure(enabled: true, mode: .native, sharpness: 0.5)
for timestamp in 1...100 { mailbox.submit(small, timestamp: UInt64(timestamp)) }
for _ in 0..<100 { check(mailbox.snapshot().frame?.receivedAt == 100, "Read latest frame") }
let delayed = mailbox.diagnostics
check(delayed.published == 100 && delayed.overwrittenBeforeAcquire == 99,
      "Producer faster than consumer replaces the 99 unseen frames")
check(delayed.acquiredFrames == 0, "Read-only snapshots must not consume frames")
check(delayed.occupancy == 1 && delayed.peakOccupancy == 1,
      "A hundred submissions retain exactly one frame")
check(delayed.retainedPixelBytes == smallBytes && delayed.peakRetainedPixelBytes == smallBytes,
      "Retained bytes describe one pixel buffer, not all publications")

let rendered = mailbox.acquireForRendering().frame!
check(rendered.id == 100 && rendered.receivedAt == 100, "Acquire the latest exact frame")
for _ in 0..<100 {
    check(mailbox.acquireForRendering().frame?.id == rendered.id, "Stable frame can redraw")
}
check(mailbox.diagnostics.acquiredFrames == 1, "Repeated redraw counts one distinct frame")
check(mailbox.diagnostics.occupancy == 1, "Acquisition retains the latest frame for redraw")
mailbox.submit(large, timestamp: 101)
check(mailbox.diagnostics.overwrittenBeforeAcquire == 99,
      "Replacing an acquired frame is not an overwrite before acquisition")
let merelyObserved = mailbox.snapshot().frame!
mailbox.submit(small, timestamp: 102)
check(mailbox.diagnostics.overwrittenBeforeAcquire == 100,
      "A read-only observation does not prevent overwrite accounting")
check(rendered.id == 100 && CVPixelBufferGetWidth(rendered.pixelBuffer) == 16
      && merelyObserved.receivedAt == 101 && CVPixelBufferGetWidth(merelyObserved.pixelBuffer) == 64,
      "A renderer or observer can retain its original frame after replacement")
check(mailbox.diagnostics.retainedPixelBytes == smallBytes
      && mailbox.diagnostics.peakRetainedPixelBytes == largeBytes,
      "Current bytes follow the latest buffer while high water retains the maximum")
mailbox.configure(enabled: false, mode: .enhanced, sharpness: 0.7)
mailbox.configure(enabled: false, mode: .enhanced, sharpness: 0.7)
check(mailbox.diagnostics.clearedBeforeAcquire == 1
      && mailbox.diagnostics.overwrittenBeforeAcquire == 100,
      "Disabling clears one unseen frame without counting replacement or duplicate clear")
check(mailbox.snapshot().frame == nil && mailbox.diagnostics.occupancy == 0
      && mailbox.diagnostics.retainedPixelBytes == 0
      && mailbox.diagnostics.peakRetainedPixelBytes == largeBytes,
      "Disabling releases the mailbox reference and preserves its high water")
check(mailbox.acquireForRendering().frame == nil && mailbox.diagnostics.acquiredFrames == 1,
      "Empty acquisition does not increment the counter")
print("PASS: bounded latest-frame storage, read-only snapshots, atomic distinct acquisition, byte high water and clear accounting")

let recorder = StreamingMetricsRecorder()
let sessionA = recorder.beginSession()
let timingA = VideoFrameMetrics(recorder: recorder, session: sessionA,
                               receivedAt: MetricTimestamp(microseconds: 1))!
mailbox.beginSession(sessionA)
check(!mailbox.snapshot().enabled && mailbox.snapshot().mode == .enhanced
      && mailbox.snapshot().sharpness == 0.7 && mailbox.snapshot().nextID == 102,
      "Session begin preserves settings and monotonic rendering IDs")
check(mailbox.diagnostics.isActive && mailbox.diagnostics.published == 0
      && mailbox.diagnostics.disabledSubmissions == 0
      && mailbox.diagnostics.overwrittenBeforeAcquire == 0
      && mailbox.diagnostics.clearedBeforeAcquire == 0
      && mailbox.diagnostics.acquiredFrames == 0
      && mailbox.diagnostics.peakOccupancy == 0
      && mailbox.diagnostics.peakRetainedPixelBytes == 0,
      "Session begin resets counters and retained buffer")
mailbox.submit(small, timestamp: 103, session: sessionA)
check(mailbox.diagnostics.disabledSubmissions == 1 && mailbox.diagnostics.occupancy == 0,
      "A current-session publication is counted and dropped while disabled")
mailbox.configure(enabled: true, mode: .enhanced, sharpness: 0.7)
mailbox.submit(small, timestamp: 103, session: sessionA)
check(mailbox.snapshot().frame?.id == 103 && mailbox.diagnostics.published == 1
      && mailbox.snapshot().frame?.session == sessionA && mailbox.snapshot().frame?.metrics == nil,
      "Unavailable timing still publishes with an explicit session")
mailbox.submit(large, timestamp: 104)
check(mailbox.diagnostics.staleSubmissions == 1 && mailbox.snapshot().frame?.id == 103,
      "A session-scoped mailbox cannot accept an unscoped callback")
mailbox.submit(large, timestamp: 105, metrics: timingA)
check(mailbox.snapshot().frame?.metrics?.frame == timingA.frame,
      "Timing context can provide the submission session")

// Hold an actual decoded callback while a new session replaces the old one.
let callbackReady = DispatchSemaphore(value: 0)
let releaseCallback = DispatchSemaphore(value: 0)
let callbackDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    callbackReady.signal()
    releaseCallback.wait()
    mailbox.submit(large, timestamp: 999, metrics: timingA, session: sessionA)
    mailbox.submit(large, timestamp: 998, session: sessionA)
    mailbox.endSession(sessionA)
    callbackDone.signal()
}
check(callbackReady.wait(timeout: .now() + 5) == .success, "Old callback is waiting")
let sessionB = recorder.beginSession()
let timingB = VideoFrameMetrics(recorder: recorder, session: sessionB,
                               receivedAt: MetricTimestamp(microseconds: 1))!
let previousID = mailbox.snapshot().nextID
mailbox.beginSession(sessionB)
check(mailbox.snapshot().frame == nil && mailbox.diagnostics.clearedBeforeAcquire == 0,
      "Previous session's unseen frame is released outside the new counters")
mailbox.submit(small, timestamp: 200, metrics: timingB, session: sessionB)
let newFrame = mailbox.snapshot().frame!
check(newFrame.id == previousID + 1, "IDs stay monotonic across reconnect")
releaseCallback.signal()
check(callbackDone.wait(timeout: .now() + 5) == .success, "Old callback completed")
check(mailbox.diagnostics.session == sessionB && mailbox.diagnostics.isActive
      && mailbox.snapshot().frame?.id == newFrame.id && mailbox.diagnostics.staleSubmissions == 2,
      "Old callback with or without timing and late stop cannot replace or end a new session")
mailbox.submit(large, timestamp: 201, metrics: timingA, session: sessionB)
mailbox.submit(large, timestamp: 202, metrics: timingB, session: sessionA)
check(mailbox.diagnostics.staleSubmissions == 4 && mailbox.diagnostics.published == 1,
      "Explicit and timing identities must both match the active session")
mailbox.endSession(sessionB)
mailbox.endSession(sessionB)
check(!mailbox.diagnostics.isActive && mailbox.diagnostics.occupancy == 0
      && mailbox.diagnostics.retainedPixelBytes == 0
      && mailbox.diagnostics.clearedBeforeAcquire == 1,
      "Matching end releases the last unseen frame exactly once")
mailbox.configure(enabled: true, mode: .native, sharpness: 0.5)
mailbox.submit(small, timestamp: 203, session: sessionB)
check(mailbox.diagnostics.staleSubmissions == 5 && mailbox.snapshot().frame == nil,
      "Changing display settings cannot reactivate an ended session")
print("PASS: scoped resets, missing timestamp fallback, reconnect protection, mismatched identities and ended-session rejection")

let stress = VideoFrameMailbox()
let stressSession = recorder.beginSession()
stress.beginSession(stressSession)
stress.configure(enabled: true, mode: .native, sharpness: 0.5)
let work = DispatchGroup()
for producer in 0..<4 {
    work.enter()
    DispatchQueue.global().async {
        for index in 1...2_500 {
            stress.submit(index.isMultiple(of: 2) ? small : large,
                          timestamp: UInt64(producer * 2_500 + index), session: stressSession)
        }
        work.leave()
    }
}
for _ in 0..<2 {
    work.enter()
    DispatchQueue.global().async {
        for _ in 0..<10_000 {
            _ = stress.acquireForRendering()
            _ = stress.snapshot()
            let sample = stress.diagnostics
            check(sample.occupancy <= 1 && sample.peakOccupancy <= 1,
                  "Concurrent observation preserves the single-slot bound")
            check(sample.retainedPixelBytes <= largeBytes && sample.peakRetainedPixelBytes <= largeBytes,
                  "Concurrent observation never accumulates buffer bytes")
        }
        work.leave()
    }
}
check(work.wait(timeout: .now() + 15) == .success, "Concurrent producers and consumers completed")
_ = stress.acquireForRendering()
let concurrent = stress.diagnostics
check(concurrent.published == 10_000 && concurrent.acquiredFrames > 0,
      "All concurrent publications are accounted")
check(concurrent.published == concurrent.acquiredFrames + concurrent.overwrittenBeforeAcquire,
      "Each published frame is acquired exactly once or overwritten before acquisition")
check(concurrent.disabledSubmissions == 0 && concurrent.staleSubmissions == 0
      && concurrent.clearedBeforeAcquire == 0 && concurrent.occupancy == 1
      && concurrent.peakOccupancy == 1 && concurrent.peakRetainedPixelBytes == largeBytes,
      "Concurrent counts and high water remain consistent")
stress.endSession(stressSession)
check(stress.diagnostics.retainedPixelBytes == 0 && stress.diagnostics.clearedBeforeAcquire == 0,
      "Clearing an already acquired frame adds no unseen drop")
print("PASS: four concurrent producers, two consumers, exact publication conservation and bounded logical memory")
