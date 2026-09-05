// App decoder is extracted by test_video_decoder.sh so this runs without a headset.
import Foundation
import VideoToolbox
import CoreVideo
import QuartzCore
import os

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let mixedNALs = Data([0,0,0,1,0x65,7,8,0,0,1,0x61,9])
check(StreamVideoDecoder.nalRanges(mixedNALs).map { mixedNALs.subdata(in: $0) } == [Data([0x65,7,8]), Data([0x61,9])], "three/four byte start codes and multiple slices")
check(StreamVideoDecoder.nalRanges(Data([0,0,1])).isEmpty, "empty NAL")
check(StreamVideoDecoder.nalRanges(Data([1,2,3])).isEmpty, "invalid Annex-B")

final class Encoded: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var parameterSets = Data()
    var frames: [Data] = []
}
func testCodec(isHEVC: Bool) {
let encoded = Encoded()
var compression: VTCompressionSession?
let created = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: 64, height: 64,
    codecType: isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
    compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &compression)
check(created == noErr, "create test encoder: \(created)")
let encoder = compression!
VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
var pixel: CVPixelBuffer?
check(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, "pixel buffer")
CVPixelBufferLockBaseAddress(pixel!, [])
memset(CVPixelBufferGetBaseAddress(pixel!), 128, CVPixelBufferGetDataSize(pixel!))
CVPixelBufferUnlockBaseAddress(pixel!, [])
for frameIndex in 0..<30 {
var flags: VTEncodeInfoFlags = []
let submitted = VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixel!, presentationTimeStamp: CMTime(value: Int64(frameIndex), timescale: 60),
    duration: CMTime(value: 1, timescale: 60), frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: frameIndex == 0 || frameIndex == 20] as CFDictionary,
    infoFlagsOut: &flags) { status, _, sample in
        defer { encoded.done.signal() }
        check(status == noErr && sample != nil, "encode keyframe")
        var annexB = Data()
        let format = CMSampleBufferGetFormatDescription(sample!)!
        for index in 0..<(isHEVC ? 3 : 2) {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let result: OSStatus
            if isHEVC {
                result = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            } else {
                result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
            }
            check(result == noErr, "parameter set")
            if encoded.frames.isEmpty {
                encoded.parameterSets.append(contentsOf: [0,0,0,1])
                encoded.parameterSets.append(pointer!, count: size)
            }
        }
        let block = CMSampleBufferGetDataBuffer(sample!)!
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        check(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr, "copy encoded sample")
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            check(offset + size <= bytes.count, "NAL length")
            annexB.append(contentsOf: [0,0,0,1])
            annexB.append(contentsOf: bytes[offset..<offset+size])
            offset += size
        }
        encoded.frames.append(annexB)
    }
check(submitted == noErr, "submit test encode")
}
VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
for _ in 0..<30 { check(encoded.done.wait(timeout: .now() + 5) == .success, "encoder timeout") }
VTCompressionSessionInvalidate(encoder)

let submissionQueue = DispatchQueue(label: "decoder.regression.test")
let decoder = StreamVideoDecoder(width: 64, height: 64, isHEVC: isHEVC, submissionQueue: submissionQueue)
decoder.start()
func decode(_ data: Data, loss: Int32, recovered: Bool = false) {
    let done = DispatchSemaphore(value: 0)
    let accepted = data.withUnsafeBytes { bytes in
        decoder.submit(pointer: bytes.baseAddress!, size: bytes.count, framesLost: loss, recovered: recovered) { buffer, timestamp in
            check(CVPixelBufferGetWidth(buffer) == 64, "decoded size")
            check(timestamp > 0, "monotonic timestamp")
            done.signal()
        }
    }
    check(accepted, "frame admitted")
    check(done.wait(timeout: .now() + 5) == .success, "decoder must recover without repeated parameter sets")
}
decode(encoded.parameterSets + encoded.frames[0], loss: 0)
// These must be dependent pictures, not another isolated IDR.
let types = StreamVideoDecoder.nalRanges(encoded.frames[1]).map {
    isHEVC ? (encoded.frames[1][$0.lowerBound] >> 1) & 0x3f : encoded.frames[1][$0.lowerBound] & 0x1f
}
check(isHEVC ? types.contains(where: { $0 <= 9 }) : types.contains(1), "encoder must produce P frames")
decode(encoded.frames[1], loss: 2, recovered: true)
decode(encoded.frames[2], loss: 1)
for index in 3..<20 { decode(encoded.frames[index], loss: 0) }
check(decoder.diagnostics.sessions == 1, "loss/reference repair must NOT invalidate surviving references")

// Deterministically fill the submission queue, reject one frame, then recover.
let held = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
submissionQueue.async { held.signal(); release.wait() }
check(held.wait(timeout: .now() + 2) == .success, "hold submission queue")
for _ in 0..<12 {
    let accepted = encoded.parameterSets.withUnsafeBytes { bytes in
        decoder.submit(pointer: bytes.baseAddress!, size: bytes.count, framesLost: 0, recovered: false) { _, _ in
            fatalError("parameter sets must not output video")
        }
    }
    check(accepted, "admit up to the bounded queue capacity")
}
let rejected = encoded.frames[20].withUnsafeBytes { bytes in
    decoder.submit(pointer: bytes.baseAddress!, size: bytes.count, framesLost: 0, recovered: false) { _, _ in
        fatalError("rejected frame must never execute")
    }
}
check(!rejected, "full queue rejects without enqueueing")
release.signal()
submissionQueue.sync {}
decode(encoded.frames[20], loss: 1)
for index in 21..<30 { decode(encoded.frames[index], loss: 0) }
check(decoder.diagnostics.rejected == 1, "a single rejection must not poison following frames")
check(decoder.diagnostics.sessions == 1, "overload must not destroy references")
check(decoder.diagnostics.errors == 0, "decode errors")
decoder.stop()
let stopped = encoded.frames[29].withUnsafeBytes { bytes in
    decoder.submit(pointer: bytes.baseAddress!, size: bytes.count, framesLost: 0, recovered: false) { _, _ in fatalError("output after stop") }
}
check(!stopped, "stopped decoder rejects input")
print("PASS: \(isHEVC ? "HEVC" : "H.264") dependent frames; reference preservation; bounded overflow recovery; stop gate")
}
testCodec(isHEVC: false)
testCodec(isHEVC: true)
print("PASS: Annex-B parser with multiple slices")
