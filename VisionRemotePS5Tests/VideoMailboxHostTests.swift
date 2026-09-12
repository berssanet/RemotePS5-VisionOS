import Foundation
import CoreVideo
import os

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

let inspection = VideoFrameMailbox()
let inspectionEvents = OSAllocatedUnfairLock(initialState: [Bool]())
inspection.observeInspectionChanges {
    // Reentrant snapshot verifies the callback is outside the mailbox lock.
    let actual = inspection.snapshot().isInspectionFrozen
    inspectionEvents.withLock { $0.append(actual) }
}
let inspectionSession = recorder.beginSession()
inspection.beginSession(inspectionSession)
inspection.configure(enabled: true, mode: .enhanced, sharpness: 0.5)
check(!inspection.setInspectionFrozen(true), "No image means no reported freeze")
let inspectionTiming = VideoFrameMetrics(recorder: recorder, session: inspectionSession,
                                         receivedAt: MetricTimestamp(microseconds: 1))!
inspection.submit(small, timestamp: 1, metrics: inspectionTiming, session: inspectionSession)
let originalInspection = inspection.snapshot().frame!
check(inspection.setInspectionFrozen(true), "Pin the available frame exactly once")
check(inspection.snapshotForRendering().frame?.metrics == nil,
      "Even the first frozen draw cannot record an old delivery timing")
check(inspection.acquireForRendering().frame?.id == originalInspection.id
      && inspection.diagnostics.acquiredFrames == 1,
      "A pinned frame still matching latest can be acquired once")
let firstConsumer = UUID(), nextConsumer = UUID()
inspection.selectConsumer(firstConsumer)
for index in 2...101 {
    inspection.submit(large, timestamp: UInt64(index), session: inspectionSession)
    let liveID = inspection.snapshot().frame!.id
    check(liveID > originalInspection.id, "Live publication continues during image inspection")
    check(inspection.acquireForRendering(consumerID: firstConsumer).frame?.id == originalInspection.id,
          "Rendering continues using only the pinned image")
    check(inspection.diagnostics.acquiredFrames == 1,
          "Frozen redraw cannot consume a distinct latest frame")
    check(inspection.diagnostics.inspectionFrameCount == 1
          && inspection.diagnostics.inspectionPixelBytes == smallBytes
          && inspection.diagnostics.occupancy == 1
          && inspection.diagnostics.retainedPixelBytes == largeBytes,
          "Inspection retains exactly one additional logical buffer as live video advances")
    check(inspection.setInspectionFrozen(true), "Repeated freeze requests never replace the pinned image")
}
inspection.selectConsumer(nextConsumer)
check(inspection.snapshotForRendering(consumerID: firstConsumer).frame == nil,
      "A deselected surface cannot read the inspection frame")
check(inspection.snapshotForRendering(consumerID: nextConsumer).frame?.id == originalInspection.id,
      "The same generation carries one inspection frame across surface handoff")
inspection.configure(enabled: true, mode: .metalFX, sharpness: 0.8,
    comparisonEnabled: true, comparisonPosition: 0.7, inspectionZoom: 4,
    inspectionCenter: SIMD2<Float>(0.8, 0.2))
let inspected = inspection.snapshotForRendering(consumerID: nextConsumer)
check(inspected.frame?.id == originalInspection.id && inspected.isInspectionFrozen
      && inspected.inspectionZoom == 4 && inspected.inspectionCenter == SIMD2<Float>(0.8, 0.2),
      "Mode, split and crop changes preserve the same frozen frame")
check(inspection.setInspectionFrozen(false) == false, "Explicit resume releases inspection ownership")
check(inspection.diagnostics.inspectionFrameCount == 0 && inspection.diagnostics.inspectionPixelBytes == 0,
      "Resume releases all inspection-owned bytes")
_ = inspection.acquireForRendering(consumerID: nextConsumer)
let afterResume = inspection.diagnostics
check(afterResume.published == 101 && afterResume.acquiredFrames == 2
      && afterResume.overwrittenBeforeAcquire == 99,
      "Live publication conservation remains exact across a hundred frozen redraws")
check(inspectionEvents.withLock { $0 } == [true, false],
      "Only actual freeze transitions notify, never frame publication or repeated requests")

check(inspection.setInspectionFrozen(true), "Pin before session invalidation")
let replacementSession = recorder.beginSession()
inspection.beginSession(replacementSession)
check(!inspection.snapshot().isInspectionFrozen && inspection.diagnostics.inspectionFrameCount == 0,
      "Reconnect always clears the frozen old generation")
check(!inspection.permitsRendering(consumerID: nextConsumer, session: inspectionSession),
      "An admitted old frame cannot encode after generation replacement")
inspection.submit(small, timestamp: 102, session: replacementSession)
check(inspection.setInspectionFrozen(true), "Replacement session can pin its own frame")
inspection.endSession(inspectionSession)
check(inspection.snapshot().isInspectionFrozen, "A late end cannot release the new session's frozen image")
inspection.endSession(replacementSession)
check(!inspection.snapshot().isInspectionFrozen && inspection.snapshotForRendering(consumerID: nextConsumer).frame == nil,
      "Matching end clears both live and frozen references")
check(!inspection.permitsRendering(consumerID: nextConsumer, session: replacementSession),
      "Ended generation is no longer valid for encoding")
inspection.beginSession(recorder.beginSession())
let finalSession = inspection.diagnostics.session!
inspection.submit(small, timestamp: 103, session: finalSession)
check(inspection.setInspectionFrozen(true), "Pin before disable")
inspection.configure(enabled: false, mode: .native, sharpness: 0.5)
check(!inspection.snapshot().isInspectionFrozen && inspection.diagnostics.inspectionPixelBytes == 0,
      "Disabling releases the frozen image and notifies real state")

for zoom: Float in [-10, 0, 1, 2, 3, 4, 100, .nan, .infinity, -.infinity] {
    inspection.configure(enabled: true, mode: .native, sharpness: 0.5,
        inspectionZoom: zoom, inspectionCenter: SIMD2<Float>(.nan, .infinity))
    let state = inspection.snapshot()
    check([Float(1), 2, 4].contains(state.inspectionZoom), "Zoom is limited to finite 1×/2×/4×")
    check(state.inspectionCenter == SIMD2<Float>(repeating: 0.5), "Non-finite crop center resets to center")
    inspection.configure(enabled: true, mode: .native, sharpness: 0.5,
        inspectionZoom: zoom, inspectionCenter: SIMD2<Float>(-100, 100))
    let bounded = inspection.snapshot()
    let inset: Float = 0.5 / bounded.inspectionZoom
    check(bounded.inspectionCenter == SIMD2<Float>(inset, 1 - inset),
          "Crop edges always remain inside the source image")
}
print("PASS: one-frame inspection ownership, exact live counters, same-G handoff, lifecycle release and finite crop bounds")
