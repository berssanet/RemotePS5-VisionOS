import Foundation
import VideoToolbox
import CoreVideo
import QuartzCore

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

func grayBuffer(_ value: UInt8) -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    check(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        &pixel) == kCVReturnSuccess, "Create IOSurface-backed BGRA fixture")
    let result = pixel!
    CVPixelBufferLockBaseAddress(result, [])
    let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
    for row in 0..<64 {
        for column in 0..<64 {
            let offset = row * CVPixelBufferGetBytesPerRow(result) + column * 4
            bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
}

func checkPixels(_ buffer: CVPixelBuffer, expected: UInt8, tolerance: Int = 0) {
    check(CVPixelBufferGetWidth(buffer) == 64 && CVPixelBufferGetHeight(buffer) == 64,
          "Decoded/mailbox buffer dimensions remain unchanged")
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for (x, y) in [(0, 0), (32, 32), (63, 63)] {
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        for channel in 0..<3 {
            check(abs(Int(bytes[offset + channel]) - Int(expected)) <= tolerance,
                  "Center/border decoded pixel retains the source grayscale")
        }
        check(bytes[offset + 3] == 255, "BGRA output remains opaque")
    }
}

let identities = StreamingMetricsRecorder()
let sessionA = identities.beginSession()
let sessionB = identities.beginSession()
let mailbox = VideoFrameMailbox()
mailbox.beginSession(sessionA)
mailbox.configure(enabled: true, mode: .enhanced, sharpness: 0.7)
let pixels = [grayBuffer(41), grayBuffer(201)]
for sequence in 1...100 {
    mailbox.submit(pixels[sequence % 2], timestamp: UInt64(1_000 + sequence), metrics: nil, session: sessionA)
}
let latest = mailbox.acquireForRendering()
check(latest.enabled && latest.mode == .enhanced && latest.sharpness == 0.7, "Display settings survive producer pressure")
check(latest.frame?.id == 100 && latest.frame?.receivedAt == 1_100 && latest.frame?.session == sessionA &&
      latest.frame?.metrics == nil, "Functional IDs/timestamps/session survive without frame metrics")
checkPixels(latest.frame!.pixelBuffer, expected: 41)
check(mailbox.acquireForRendering().frame?.id == 100, "Repeated acquisition preserves the latest frame")
#if DISABLE_PERFORMANCE_COLLECTION
check(mailbox.diagnostics.published == 0 && mailbox.diagnostics.acquiredFrames == 0 &&
      mailbox.diagnostics.overwrittenBeforeAcquire == 0 && mailbox.diagnostics.retainedPixelBytes == 0,
      "OFF mailbox does not collect counters or pixel-size metadata")
#else
check(mailbox.diagnostics.published == 100 && mailbox.diagnostics.acquiredFrames == 1 &&
      mailbox.diagnostics.overwrittenBeforeAcquire == 99, "ON mailbox counts producer pressure")
#endif
mailbox.configure(enabled: true, mode: .metalFX, sharpness: 0.3)
check(mailbox.acquireForRendering().frame?.id == 100 && mailbox.snapshot().mode == .metalFX,
      "Mode change redraws the same retained frame")
mailbox.beginSession(sessionB)
check(mailbox.snapshot().frame == nil, "Replacement session clears old pixels")
mailbox.submit(pixels[0], timestamp: 2_000, metrics: nil, session: sessionA)
check(mailbox.snapshot().frame == nil, "Late old-session frame rejected even without metrics")
mailbox.submit(pixels[1], timestamp: 2_001, metrics: nil, session: sessionB)
mailbox.endSession(sessionA)
check(mailbox.diagnostics.isActive && mailbox.diagnostics.session == sessionB &&
      mailbox.snapshot().frame?.id == 101, "Late stop preserves replacement identity and frame sequence")
checkPixels(mailbox.acquireForRendering().frame!.pixelBuffer, expected: 201)
mailbox.configure(enabled: false, mode: .native, sharpness: 0.5)
mailbox.submit(pixels[0], timestamp: 2_002, metrics: nil, session: sessionB)
check(mailbox.snapshot().frame == nil, "Disabled delivery clears pixels and rejects new frames")
mailbox.configure(enabled: true, mode: .native, sharpness: 0.5)
mailbox.submit(pixels[0], timestamp: 2_003, metrics: nil, session: sessionB)
check(mailbox.snapshot().frame?.id == 102, "Rejected frames never advance render IDs")
mailbox.endSession(sessionB)
mailbox.submit(pixels[1], timestamp: 2_004, metrics: nil, session: sessionB)
check(!mailbox.diagnostics.isActive && mailbox.snapshot().frame == nil, "Ended session remains closed")
print("PARITY mailbox publishedInputs=100 latestID=100 replacementID=101 resumedID=102 pixelChecks=2 staleSessionGuards=passed")

// Fixture-only encoder. Production decoder source is compiled unchanged by the
// script; no production test assertions are removed or rewritten for OFF.
final class EncodedFixture: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var parameterSets = Data()
    var frames: [Data] = []
}

func encodedFixture(isHEVC: Bool) -> EncodedFixture {
    let fixture = EncodedFixture()
    var session: VTCompressionSession?
    let created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 64, height: 64,
        codecType: isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
        encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    check(created == noErr && session != nil, "Create parity encoder")
    let encoder = session!
    defer { VTCompressionSessionInvalidate(encoder) }
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    let pixel = grayBuffer(128)
    for index in 0..<4 {
        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel,
            presentationTimeStamp: CMTime(value: Int64(index), timescale: 60), duration: CMTime(value: 1, timescale: 60),
            frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: index == 0 || index == 2] as CFDictionary,
            infoFlagsOut: &flags) { status, _, sample in
                defer { fixture.done.signal() }
                check(status == noErr && sample != nil, "Encode parity frame")
                let sample = sample!
                let format = CMSampleBufferGetFormatDescription(sample)!
                if fixture.frames.isEmpty {
                    for parameterIndex in 0..<(isHEVC ? 3 : 2) {
                        var pointer: UnsafePointer<UInt8>?
                        var size = 0
                        let result = isHEVC
                            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: parameterIndex,
                                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: parameterIndex,
                                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                        check(result == noErr && pointer != nil, "Read fixture parameter sets")
                        fixture.parameterSets.append(contentsOf: [0, 0, 0, 1])
                        fixture.parameterSets.append(pointer!, count: size)
                    }
                }
                let block = CMSampleBufferGetDataBuffer(sample)!
                var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr,
                      "Copy fixture compressed bytes")
                var frame = Data()
                var offset = 0
                while offset + 4 <= bytes.count {
                    let length = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
                    offset += 4
                    check(length > 0 && length <= bytes.count - offset, "Validate fixture NAL length")
                    frame.append(contentsOf: [0, 0, 0, 1])
                    frame.append(contentsOf: bytes[offset..<offset + length])
                    offset += length
                }
                check(offset == bytes.count, "Fixture has no trailing partial NAL")
                fixture.frames.append(frame)
            }
        check(status == noErr, "Submit fixture frame")
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        check(fixture.done.wait(timeout: .now() + 5) == .success, "Fixture encoder output deadline")
    }
    return fixture
}

func decoderParity(isHEVC: Bool) {
    let fixture = encodedFixture(isHEVC: isHEVC)
    let dependentTypes = StreamVideoDecoder.nalRanges(fixture.frames[1]).map {
        isHEVC ? (fixture.frames[1][$0.lowerBound] >> 1) & 0x3f : fixture.frames[1][$0.lowerBound] & 0x1f
    }
    check(isHEVC ? dependentTypes.contains(where: { $0 <= 9 }) : dependentTypes.contains(1),
          "Parity fixture must include a dependent P picture")
    let queue = DispatchQueue(label: "video.instrumentation.parity.decoder")
    let decoder = StreamVideoDecoder(width: 64, height: 64, isHEVC: isHEVC, submissionQueue: queue)
    decoder.start()
    func decode(_ data: Data, loss: Int32 = 0, recovered: Bool = false) {
        let done = DispatchSemaphore(value: 0)
        let started = UInt64(CACurrentMediaTime() * 1_000_000)
        let accepted = data.withUnsafeBytes { raw in
            decoder.submit(pointer: raw.baseAddress!, size: raw.count, framesLost: loss, recovered: recovered) { pixel, timestamp in
                checkPixels(pixel, expected: 128, tolerance: 4)
                check(timestamp > 0 && timestamp >= started && timestamp <= UInt64(CACurrentMediaTime() * 1_000_000),
                      "Functional decoder PTS remains a current monotonic timestamp with collection OFF")
                done.signal()
            }
        }
        check(accepted && done.wait(timeout: .now() + 5) == .success, "Admitted frame produces real decoded pixels")
        queue.sync {}
    }
    decode(fixture.parameterSets + fixture.frames[0])
    decode(fixture.frames[1], loss: 2, recovered: true)
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    queue.async { held.signal(); release.wait() }
    check(held.wait(timeout: .now() + 2) == .success, "Hold actual decoder CPU queue")
    for _ in 0..<12 {
        let accepted = fixture.parameterSets.withUnsafeBytes { raw in
            decoder.submit(pointer: raw.baseAddress!, size: raw.count, framesLost: 0, recovered: false) { _, _ in
                fatalError("Parameter-only input cannot output video")
            }
        }
        check(accepted, "Semaphore still admits twelve CPU submissions in both modes")
    }
    let overflow = fixture.frames[2].withUnsafeBytes { raw in
        decoder.submit(pointer: raw.baseAddress!, size: raw.count, framesLost: 0, recovered: false) { _, _ in
            fatalError("Rejected new frame must never execute")
        }
    }
    check(!overflow, "Thirteenth CPU submission is rejected in both modes")
    #if DISABLE_PERFORMANCE_COLLECTION
    check(decoder.queueDiagnostics.admittedSubmissions == 0 && decoder.queueDiagnostics.admittedBytes == 0 &&
          decoder.diagnostics.accepted == 0 && decoder.diagnostics.rejected == 0 && decoder.diagnostics.outputs == 0,
          "OFF decoder leaves diagnostic counters unused while semaphore enforces capacity")
    #else
    check(decoder.queueDiagnostics.admittedSubmissions == 12 &&
          decoder.queueDiagnostics.admittedBytes == 12 * fixture.parameterSets.count && decoder.diagnostics.rejected == 1,
          "ON decoder records the same functional saturation")
    #endif
    release.signal()
    queue.sync {}
    check(decoder.queueDiagnostics.admittedSubmissions == 0 && decoder.queueDiagnostics.admittedBytes == 0,
          "Draining cannot underflow diagnostics in either mode")
    decode(fixture.frames[2], loss: 1)
    decode(fixture.frames[3])
    decoder.stop()
    let stopped = fixture.frames[3].withUnsafeBytes { raw in
        decoder.submit(pointer: raw.baseAddress!, size: raw.count, framesLost: 0, recovered: false) { _, _ in
            fatalError("Stopped decoder cannot output pixels")
        }
    }
    check(!stopped, "Stop still rejects input without collection")
    queue.sync {}
    #if DISABLE_PERFORMANCE_COLLECTION
    check(decoder.queueDiagnostics.peakAdmittedSubmissions == 0 && decoder.queueDiagnostics.rejectStopped == 0 &&
          decoder.diagnostics.outputs == 0 && decoder.diagnostics.errors == 0 && decoder.diagnostics.sessions == 0,
          "OFF decoder remains uncollected after successful decode and stop")
    #else
    check(decoder.diagnostics.outputs == 4 && decoder.diagnostics.errors == 0 && decoder.diagnostics.sessions == 1 &&
          decoder.queueDiagnostics.peakAdmittedSubmissions == 12 && decoder.queueDiagnostics.rejectStopped == 1,
          "ON counters match the observed decode/reference/capacity behavior")
    #endif
    print("PARITY codec=\(isHEVC ? "HEVC" : "H264") acceptedSubmissions=16 decodedFrames=4 pixelChecks=4 capacity=12 rejectedNew=1 stoppedRejections=1")
}

decoderParity(isHEVC: false)
decoderParity(isHEVC: true)
print("PASS: actual mailbox and VideoToolbox decoder preserve functional behavior in this build")
