import Foundation
import VideoToolbox
import CoreMedia
import Combine
import QuartzCore  // v10.1: For CACurrentMediaTime monotonic clock

/// Hardware-accelerated video decoder using VideoToolbox
/// HDR output format configuration
enum VideoOutputFormat {
    case sdr8bit      // kCVPixelFormatType_32BGRA (SDR 8-bit)
    case hdr10bit     // kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange (P010 HDR)
    
    var pixelFormat: OSType {
        switch self {
        case .sdr8bit:
            return kCVPixelFormatType_32BGRA
        case .hdr10bit:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange  // P010
        }
    }
    
    var description: String {
        switch self {
        case .sdr8bit: return "SDR (BGRA 8-bit)"
        case .hdr10bit: return "HDR (P010 10-bit)"
        }
    }
}

/// High-performance video decoder using VideoToolbox.
/// 
/// Frame delivery uses a closure callback instead of @Published to bypass SwiftUI.
/// This allows the render loop (Decoder -> MetalFX -> RealityKit) to run independently
/// of SwiftUI layout updates.
final class VideoDecoder {
    
    // MARK: - Slow State (Observable)
    
    /// Current frame rate (updated once per second)
    private(set) var frameRate: Double = 0
    
    /// Whether decoder session is active
    private(set) var isDecoding = false
    
    /// Last error encountered
    private(set) var lastError: Error?
    
    /// Statistics for frame dropping
    private(set) var droppedFrameCount: Int = 0
    
    // MARK: - High-Performance Frame Callback
    
    /// Called on decoder thread when a frame is ready. NOT on Main Thread.
    /// This is the hot path - do not dispatch to MainActor from here.
    /// - Warning: Called from VideoToolbox callback thread. Must be thread-safe.
    var onFrameDecoded: ((CVPixelBuffer) -> Void)?
    
    // MARK: - Configuration
    
    /// Output format preference for HDR support
    /// v10.4 FIX: Use SDR BGRA for direct Metal texture compatibility
    /// P010 (HDR) requires YUV→RGB color space conversion which is not yet integrated
    var preferredFormat: VideoOutputFormat = .sdr8bit
    
    // MARK: - Private Properties
    
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var codecType: CMVideoCodecType = kCMVideoCodecType_HEVC
    
    private var frameCount = 0
    private var lastFrameTime = CACurrentMediaTime()
    
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    
    // MARK: - Frame Dropping
    
    private let maxPendingFrames = 3
    private var pendingFrameCount: Int32 = 0
    private let pendingFrameLock = NSLock()
    
    // MARK: - Lifecycle
    
    init() {}
    
    deinit {
        stop()
    }
    
    // MARK: - Public Methods
    
    /// Configure decoder for H.264 or H.265
    func configure(codec: VideoCodec, width: Int, height: Int) throws {
        codecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        
        // Wait for parameter sets before creating session
        isDecoding = false
    }
    
    /// Process incoming NAL unit data
    func decode(_ data: Data) throws {
        // Parse NAL units - PS5 sends NALs with Annex-B start codes
        guard data.count > 4 else { return }
        
        // Split data into individual NAL units using start code detection
        let nalUnits = splitNALUnits(data)
        
        // Debug logging every 60 frames
        frameCounter += 1
        if frameCounter % 60 == 1 || frameCounter <= 5 {
            let hexDump = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[VideoDecoder] 🔍 Frame #\(frameCounter) (\(data.count) bytes, \(nalUnits.count) NALs): \(hexDump)...")
        }
        
        for nalData in nalUnits {
            let nalTypeValue = getNALTypeValue(nalData)
            let strippedNal = stripStartCode(nalData)
            
            // Log parameter sets and key frames
            if nalTypeValue >= 32 && nalTypeValue <= 34 || frameCounter <= 5 {
                print("[VideoDecoder] � NAL type \(nalTypeValue), size: \(nalData.count)")
            }
            
            switch nalTypeValue {
            case 32: // VPS
                vps = strippedNal
                print("[VideoDecoder] ✅ Stored VPS (\(vps?.count ?? 0) bytes)")
                try createSessionIfReady()
                
            case 33: // SPS
                sps = strippedNal
                print("[VideoDecoder] ✅ Stored SPS (\(sps?.count ?? 0) bytes)")
                try createSessionIfReady()
                
            case 34: // PPS
                pps = strippedNal
                print("[VideoDecoder] ✅ Stored PPS (\(pps?.count ?? 0) bytes)")
                try createSessionIfReady()
                
            case 19, 20: // IDR frames (CRA, IDR_W_RADL, IDR_N_LP)
                if decompressionSession != nil {
                    let avccData = convertToAVCC(nalData)
                    try decodeFrame(avccData)
                } else {
                    print("[VideoDecoder] ⚠️ IDR but no session (VPS:\(vps != nil), SPS:\(sps != nil), PPS:\(pps != nil))")
                }
                
            case 0, 1: // Non-IDR slice (TRAIL_N, TRAIL_R)
                if decompressionSession != nil {
                    let avccData = convertToAVCC(nalData)
                    try decodeFrame(avccData)
                } else if frameCounter % 60 == 0 {
                    print("[VideoDecoder] ⚠️ No session yet (VPS:\(vps != nil), SPS:\(sps != nil), PPS:\(pps != nil))")
                }
                
            default:
                if frameCounter <= 10 {
                    print("[VideoDecoder] ❓ Unhandled NAL type \(nalTypeValue), size: \(nalData.count)")
                }
            }
        }
    }
    
    private var frameCounter: Int = 0
    
    /// Parse VPS+SPS+PPS from a parameter set packet
    /// PS5 sends these concatenated - we need to scan for NAL type boundaries
    private func parseParameterSets(_ data: Data) {
        let stripped = stripStartCode(data)
        guard stripped.count > 4 else { return }
        
        print("[VideoDecoder] 🔧 Parsing parameter sets from \(stripped.count) bytes")
        
        // Scan through the data looking for HEVC NAL unit headers
        // HEVC NAL header: 2 bytes - (NAL_type << 1) in first byte's bits [6:1]
        var currentPos = 0
        var lastNalStart = 0
        var lastNalType: UInt8 = getHEVCNALType(stripped)
        
        var foundVPS: Data?
        var foundSPS: Data?
        var foundPPS: Data?
        
        // Scan for NAL boundaries by looking for 00 00 01 or 00 00 00 01 patterns
        var i = 0
        while i < stripped.count - 2 {
            let is3ByteCode = stripped[i] == 0x00 && stripped[i+1] == 0x00 && stripped[i+2] == 0x01
            let is4ByteCode = i < stripped.count - 3 && 
                              stripped[i] == 0x00 && stripped[i+1] == 0x00 && 
                              stripped[i+2] == 0x00 && stripped[i+3] == 0x01
            
            if is3ByteCode || is4ByteCode {
                // Found a start code - save the previous NAL
                if i > lastNalStart {
                    let nalData = stripped.subdata(in: lastNalStart..<i)
                    let nalType = getHEVCNALType(nalData)
                    print("[VideoDecoder] 🔧 Found NAL type \(nalType) with \(nalData.count) bytes at offset \(lastNalStart)")
                    
                    switch nalType {
                    case 32: foundVPS = nalData
                    case 33: foundSPS = nalData
                    case 34: foundPPS = nalData
                    default: break
                    }
                }
                
                lastNalStart = i + (is4ByteCode ? 4 : 3)
                i = lastNalStart
            } else {
                i += 1
            }
        }
        
        // Save the last NAL
        if lastNalStart < stripped.count {
            let nalData = stripped.subdata(in: lastNalStart..<stripped.count)
            let nalType = getHEVCNALType(nalData)
            print("[VideoDecoder] 🔧 Found final NAL type \(nalType) with \(nalData.count) bytes")
            
            switch nalType {
            case 32: foundVPS = nalData
            case 33: foundSPS = nalData
            case 34: foundPPS = nalData
            default: break
            }
        }
        
        // If we only found one NAL (no internal start codes), the whole thing is the VPS
        // This is the common case - PS5 sends VPS+SPS+PPS without internal start codes
        if foundVPS == nil && foundSPS == nil && foundPPS == nil {
            let nalType = getHEVCNALType(stripped)
            print("[VideoDecoder] 🔧 No internal start codes found. Entire packet is NAL type \(nalType)")
            
            if nalType == 32 {
                // This is a VPS-only packet. We need to handle this case.
                // The PS5 might be sending VPS, SPS, PPS as separate packets.
                vps = stripped
                print("[VideoDecoder] ✅ Stored VPS (\(stripped.count) bytes)")
            }
            return
        }
        
        // Store the found parameter sets
        if let v = foundVPS {
            vps = v
            print("[VideoDecoder] ✅ Extracted VPS (\(v.count) bytes)")
        }
        if let s = foundSPS {
            sps = s
            print("[VideoDecoder] ✅ Extracted SPS (\(s.count) bytes)")
        }
        if let p = foundPPS {
            pps = p
            print("[VideoDecoder] ✅ Extracted PPS (\(p.count) bytes)")
        }
        
        do {
            try createSessionIfReady()
        } catch {
            print("[VideoDecoder] ❌ Failed to create session: \(error)")
        }
    }
    
    /// Get HEVC NAL unit type from raw NAL data (without start code)
    private func getHEVCNALType(_ data: Data) -> UInt8 {
        guard data.count >= 1 else { return 0 }
        // HEVC NAL header: (nal_unit_type << 1) is in bits [6:1] of first byte
        return (data[0] >> 1) & 0x3F
    }
    
    /// Split data into individual NAL units by scanning for start codes
    private func splitNALUnits(_ data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var startIndices: [Int] = []
        
        // Find all start code positions
        var i = 0
        while i < data.count - 3 {
            // Check for 4-byte start code: 0x00 0x00 0x00 0x01
            if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x00 && data[i+3] == 0x01 {
                startIndices.append(i)
                i += 4
            }
            // Check for 3-byte start code: 0x00 0x00 0x01
            else if data[i] == 0x00 && data[i+1] == 0x00 && data[i+2] == 0x01 {
                startIndices.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        
        // Extract NAL units
        for (index, startPos) in startIndices.enumerated() {
            let endPos = (index + 1 < startIndices.count) ? startIndices[index + 1] : data.count
            let nalData = data.subdata(in: startPos..<endPos)
            nalUnits.append(nalData)
        }
        
        // If no start codes found, treat entire data as single NAL unit
        if nalUnits.isEmpty {
            nalUnits.append(data)
        }
        
        return nalUnits
    }
    
    /// Strip start code from NAL unit data
    private func stripStartCode(_ data: Data) -> Data {
        guard data.count > 4 else { return data }
        
        if data[0] == 0x00 && data[1] == 0x00 {
            if data[2] == 0x00 && data[3] == 0x01 {
                return data.subdata(in: 4..<data.count)
            } else if data[2] == 0x01 {
                return data.subdata(in: 3..<data.count)
            }
        }
        return data
    }
    
    /// Convert Annex-B NAL to AVCC format (length-prefixed)
    private func convertToAVCC(_ data: Data) -> Data {
        let strippedData = stripStartCode(data)
        var length = UInt32(strippedData.count).bigEndian
        var result = Data(bytes: &length, count: 4)
        result.append(strippedData)
        return result
    }
    
    /// Get raw NAL type value for logging
    private func getNALTypeValue(_ data: Data) -> Int {
        guard data.count > 4 else { return -1 }
        
        var offset = 0
        if data[0] == 0x00 && data[1] == 0x00 {
            if data[2] == 0x01 {
                offset = 3
            } else if data[2] == 0x00 && data[3] == 0x01 {
                offset = 4
            }
        }
        
        guard offset < data.count else { return -1 }
        
        if codecType == kCMVideoCodecType_HEVC {
            return Int((data[offset] >> 1) & 0x3F)
        } else {
            return Int(data[offset] & 0x1F)
        }
    }

    
    /// Stop decoding and release resources
    func stop() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        isDecoding = false
        sps = nil
        pps = nil
        vps = nil
    }
    
    // MARK: - Private Methods
    
    private func createSessionIfReady() throws {
        // For H.264: need SPS and PPS
        // For HEVC: need VPS, SPS, and PPS
        
        if codecType == kCMVideoCodecType_H264 {
            guard let sps = sps, let pps = pps else { return }
            try createH264Session(sps: sps, pps: pps)
        } else {
            guard let vps = vps, let sps = sps, let pps = pps else { return }
            try createHEVCSession(vps: vps, sps: sps, pps: pps)
        }
    }
    
    private func createH264Session(sps: Data, pps: Data) throws {
        let parameterSets = [
            [UInt8](sps),
            [UInt8](pps)
        ]
        
        let parameterSetPointers = parameterSets.map { UnsafePointer($0) }
        let parameterSetSizes = parameterSets.map { $0.count }
        
        var formatDesc: CMFormatDescription?
        
        let status = parameterSetPointers.withUnsafeBufferPointer { pointers in
            parameterSetSizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        
        guard status == noErr, let formatDescription = formatDesc else {
            throw VideoDecoderError.formatDescriptionCreationFailed
        }
        
        self.formatDescription = formatDescription
        try createDecompressionSession()
    }
    
    private func createHEVCSession(vps: Data, sps: Data, pps: Data) throws {
        let parameterSets = [
            [UInt8](vps),
            [UInt8](sps),
            [UInt8](pps)
        ]
        
        let parameterSetPointers = parameterSets.map { UnsafePointer($0) }
        let parameterSetSizes = parameterSets.map { $0.count }
        
        var formatDesc: CMFormatDescription?
        
        let status = parameterSetPointers.withUnsafeBufferPointer { pointers in
            parameterSetSizes.withUnsafeBufferPointer { sizes in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointers.baseAddress!,
                    parameterSetSizes: sizes.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        
        guard status == noErr, let formatDescription = formatDesc else {
            throw VideoDecoderError.formatDescriptionCreationFailed
        }
        
        self.formatDescription = formatDescription
        try createDecompressionSession()
    }
    
    private func createDecompressionSession() throws {
        guard let formatDescription = formatDescription else {
            throw VideoDecoderError.noFormatDescription
        }
        
        // Clean up existing session
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        
        // Destination pixel buffer attributes - optimized for zero-copy GPU access
        // HDR: Use P010 (10-bit YUV 4:2:0) for maximum color fidelity on Vision Pro Micro-OLED
        // SDR: Use BGRA 8-bit for legacy compatibility
        let pixelFormat = preferredFormat.pixelFormat
        print("[VideoDecoder] 🎨 Creating session with format: \(preferredFormat.description)")
        
        let destinationAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            // Force IOSurface backing for zero-copy Metal texture access
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        
        // Output callback - runs on VideoToolbox thread, NOT Main Thread
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { outputRefCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr,
                      let imageBuffer = imageBuffer,
                      let decoder = outputRefCon else { return }
                
                let decoderPtr = Unmanaged<VideoDecoder>.fromOpaque(decoder).takeUnretainedValue()
                
                // CRITICAL: Call directly on decoder thread - NO dispatch to MainActor
                // This is the hot path for low-latency video
                decoderPtr.handleDecodedFrame(imageBuffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        var session: VTDecompressionSession?
        
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        
        guard status == noErr, let validSession = session else {
            throw VideoDecoderError.sessionCreationFailed
        }
        
        decompressionSession = validSession
        isDecoding = true
        
        // Configure for low-latency real-time decoding (Doc Chapter 2.2)
        // kVTDecompressionPropertyKey_RealTime: Instructs decoder to prioritize fast delivery
        VTSessionSetProperty(validSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // kVTDecompressionPropertyKey_MaximizePowerEfficiency: Disable power saving for maximum performance
        VTSessionSetProperty(validSession, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
    }
    
    private func decodeFrame(_ data: Data) throws {
        guard let session = decompressionSession,
              let formatDescription = formatDescription else {
            throw VideoDecoderError.noSession
        }
        
        // MARK: - Frame Dropping Logic
        // Check if decode buffer is congested. Drop frames to prioritize latency.
        pendingFrameLock.lock()
        let currentPending = pendingFrameCount
        if currentPending >= maxPendingFrames {
            pendingFrameLock.unlock()
            // Drop this frame to reduce latency
            Task { @MainActor in
                self.droppedFrameCount += 1
            }
            if frameCounter % 30 == 0 {
                print("[VideoDecoder] ⚠️ Dropping frame (pending: \(currentPending)/\(maxPendingFrames)) - prioritizing latency")
            }
            return
        }
        pendingFrameCount += 1
        pendingFrameLock.unlock()
        
        // Create block buffer from data
        var blockBuffer: CMBlockBuffer?
        
        let dataPtr = (data as NSData).bytes
        let dataLength = data.count
        
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer(mutating: dataPtr),
            blockLength: dataLength,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            decrementPendingFrameCount()
            throw VideoDecoderError.blockBufferCreationFailed
        }
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        
        guard status == noErr, let sample = sampleBuffer else {
            decrementPendingFrameCount()
            throw VideoDecoderError.sampleBufferCreationFailed
        }
        
        // Decode
        let decodeFlags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var infoFlags = VTDecodeInfoFlags()
        
        status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: decodeFlags,
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
        
        if status != noErr {
            decrementPendingFrameCount()
            throw VideoDecoderError.decodingFailed
        }
    }
    
    /// Thread-safe decrement of pending frame counter
    private func decrementPendingFrameCount() {
        pendingFrameLock.lock()
        pendingFrameCount = max(0, pendingFrameCount - 1)
        pendingFrameLock.unlock()
    }
    
    /// Handle decoded frame - called on VideoToolbox thread
    private func handleDecodedFrame(_ pixelBuffer: CVPixelBuffer) {
        // Decrement pending frame counter (frame completed decoding)
        decrementPendingFrameCount()
        
        // Invoke callback directly on decoder thread - no MainActor dispatch
        // This is the hot path: Decoder -> MetalFX -> RealityKit
        onFrameDecoded?(pixelBuffer)
        
        // Calculate frame rate (thread-safe, only updates once per second)
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTime
        
        if elapsed >= 1.0 {
            frameRate = Double(frameCount) / elapsed
            frameCount = 0
            lastFrameTime = now
        }
    }
    
    private func parseNALType(_ data: Data) -> NALUnitType {
        guard data.count > 4 else { return .unknown }
        
        // Skip start code (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
        var offset = 0
        if data[0] == 0x00 && data[1] == 0x00 {
            if data[2] == 0x01 {
                offset = 3
            } else if data[2] == 0x00 && data[3] == 0x01 {
                offset = 4
            }
        }
        
        guard offset < data.count else { return .unknown }
        
        let nalHeader = data[offset]
        
        if codecType == kCMVideoCodecType_H264 {
            let nalType = nalHeader & 0x1F
            switch nalType {
            case 7: return .sps
            case 8: return .pps
            case 5: return .idr
            case 1: return .nonIdr
            default: return .unknown
            }
        } else {
            // HEVC NAL unit type
            let nalType = (nalHeader >> 1) & 0x3F
            switch nalType {
            case 32: return .vps
            case 33: return .sps
            case 34: return .pps
            case 19, 20: return .idr
            case 1: return .nonIdr
            default: return .unknown
            }
        }
    }
}

// MARK: - Supporting Types

enum VideoCodec {
    case h264
    case h265
}

enum NALUnitType {
    case sps
    case pps
    case vps
    case idr
    case nonIdr
    case unknown
}

enum VideoDecoderError: LocalizedError {
    case formatDescriptionCreationFailed
    case noFormatDescription
    case sessionCreationFailed
    case noSession
    case blockBufferCreationFailed
    case sampleBufferCreationFailed
    case decodingFailed
    
    var errorDescription: String? {
        switch self {
        case .formatDescriptionCreationFailed:
            return "Failed to create format description"
        case .noFormatDescription:
            return "No format description available"
        case .sessionCreationFailed:
            return "Failed to create decompression session"
        case .noSession:
            return "No decompression session available"
        case .blockBufferCreationFailed:
            return "Failed to create block buffer"
        case .sampleBufferCreationFailed:
            return "Failed to create sample buffer"
        case .decodingFailed:
            return "Video decoding failed"
        }
    }
}
