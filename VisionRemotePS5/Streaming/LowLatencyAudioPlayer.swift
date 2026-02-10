import Foundation
import AVFoundation
import Accelerate

/// v10.0 Low-latency audio player with Stereo Emitter Array
///
/// Features:
/// - Stereo Emitter Array (L/R positioned at screen edges) for proper stereo imaging
/// - Pull-based rendering (AVAudioSourceNode) for minimal latency
/// - vDSP-accelerated Int16→Float32 conversion
/// - Closed-loop A/V sync with measured video latency
/// - Adaptive drift compensation to prevent buffer overflow/underrun
final class LowLatencyAudioPlayer {
    private let sampleRate: Int
    private let channels: Int
    
    private var audioEngine: AVAudioEngine?
    
    // v10.0: Stereo Emitter Array - Two separate nodes for L/R channels
    private var leftSourceNode: AVAudioSourceNode?
    private var rightSourceNode: AVAudioSourceNode?
    private var environmentNode: AVAudioEnvironmentNode?
    private var audioFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    
    /// Ring buffers for L/R channels (v10.0: separate buffers)
    private let leftRingBuffer: AudioRingBuffer
    private let rightRingBuffer: AudioRingBuffer
    
    /// Legacy stereo ring buffer (for interleaved input)
    private let stereoRingBuffer: AudioRingBuffer
    
    /// Temporary buffers for vDSP conversion (reused to avoid allocations)
    private var int16Buffer: UnsafeMutablePointer<Int16>?
    private var floatBuffer: UnsafeMutablePointer<Float>?
    private var conversionBufferSize: Int = 0
    
    private var isRunning = false
    private var totalSamplesProcessed: UInt64 = 0
    private var underrunCount: Int = 0
    
    // MARK: - v10.0 Stereo Emitter Configuration
    
    /// Virtual screen width in meters (for stereo positioning)
    /// Cinema-like screen: 6m wide at 4m distance (~85° FOV)
    var virtualScreenWidth: Float = 6.0
    
    /// Virtual screen distance from listener in meters
    var virtualScreenDistance: Float = 4.0
    
    // MARK: - v10.1 Direct Stereo Mode (Bypass HRTF)
    
    /// v10.1: Enable spatial audio (HRTF processing)
    /// Set to FALSE for "Direct Stereo" when PS5 Tempest Engine already provides binaural audio.
    /// This prevents double-processing that causes metallic/echo artifacts.
    /// Default: false for optimal PS5 Remote Play audio quality.
    var spatialAudioEnabled: Bool = false
    
    // MARK: - v10.0 Closed-Loop A/V Sync
    
    /// Target latency samples (dynamically updated based on measured video latency)
    private var targetSamples: Int = 1920  // Default 40ms @ 48kHz stereo
    
    /// Measured video latency in milliseconds (v10.0: closed-loop)
    private var measuredVideoLatencyMs: Double = 40.0
    
    /// Smoothing factor for latency measurements (EMA)
    private let latencySmoothingFactor: Double = 0.1
    
    /// Current playback rate (1.0 = normal, 1.0001 = slightly faster)
    private var playbackRate: Float = 1.0
    
    /// Maximum rate adjustment (0.1% to be completely imperceptible)
    private let maxRateAdjustment: Float = 0.001
    
    /// PID Controller gains
    private let kP: Float = 0.0005
    private let kI: Float = 0.00002
    private let kD: Float = 0.00005
    
    /// PID state variables
    private var pidIntegral: Float = 0.0
    private var pidPreviousError: Float = 0.0
    
    /// Samples accumulator for sub-sample drift precision
    private var driftAccumulator: Float = 0.0
    
    /// Statistics for debugging
    private var driftAdjustments: Int = 0
    
    /// Last logged target to avoid spamming logs
    private var lastLoggedTarget: Int = 0
    
    // MARK: - v10.2 Audio/Video Sync Controller
    
    /// A/V Sync controller for PTS-based synchronization
    private var syncController: AudioVideoSyncController?
    
    /// Enable PTS-based sync (vs legacy closed-loop)
    var ptsSyncEnabled: Bool = false
    
    /// Drift threshold before correction (ms)
    var driftThresholdMs: Double = 20.0 {
        didSet {
            syncController?.driftCorrector.driftThresholdMs = driftThresholdMs
        }
    }
    
    /// Emergency drop threshold (ms)
    var maxBufferBeforeDropMs: Double = 100.0 {
        didSet {
            syncController?.driftCorrector.maxBufferMs = maxBufferBeforeDropMs
        }
    }
    
    /// Samples to skip on next render (for emergency drop)
    private var pendingSkipSamples: Int = 0
    
    /// Crossfade buffer for smooth sample manipulation
    private var crossfadeLeftBuffer: UnsafeMutablePointer<Int16>?
    private var crossfadeRightBuffer: UnsafeMutablePointer<Int16>?
    private var crossfadeSize: Int = 0
    
    init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        
        // 5 seconds of audio buffer capacity per channel
        let bufferCapacity = sampleRate * 5
        self.leftRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
        self.rightRingBuffer = AudioRingBuffer(capacity: bufferCapacity)
        self.stereoRingBuffer = AudioRingBuffer(capacity: bufferCapacity * 2)
    }
    
    deinit {
        stop()
        int16Buffer?.deallocate()
        floatBuffer?.deallocate()
        crossfadeLeftBuffer?.deallocate()
        crossfadeRightBuffer?.deallocate()
    }
    
    // MARK: - v10.2 Sync Controller Setup
    
    /// Set the A/V sync controller for PTS-based synchronization
    func setSyncController(_ controller: AudioVideoSyncController) {
        self.syncController = controller
        self.ptsSyncEnabled = true
        DebugLog.info("LowLatencyAudio", "🔗 A/V Sync Controller connected (threshold: \(driftThresholdMs)ms)")
    }
    
    /// Update audio PTS when receiving packet (call from enqueue)
    func updateAudioPTS(_ pts: Double) {
        syncController?.onAudioPacketReceived(pts: pts)
    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            try configureAudioSession()
            setupStereoEmitterArray()
            try audioEngine?.start()
            isRunning = true
            let latencyMs = Double(targetSamples) / Double(sampleRate) * 1000
            DebugLog.info("LowLatencyAudio", "✅ Started Stereo Emitter (target: \(String(format: "%.0f", latencyMs))ms, screen: \(virtualScreenWidth)m @ \(virtualScreenDistance)m)")
        } catch {
            DebugLog.error("LowLatencyAudio", "Failed to start: \(error)")
        }
    }
    
    // MARK: - v10.0 Closed-Loop A/V Sync
    
    /// Update audio target based on MEASURED video latency (closed-loop sync)
    /// Call this from the video presentation callback with actual measured latency
    /// - Parameter measuredLatencyMs: Actual video latency = now - frame.captureTimestamp
    func updateDynamicTarget(measuredLatencyMs: Double) {
        // Apply exponential moving average for smoothing
        measuredVideoLatencyMs = measuredVideoLatencyMs * (1 - latencySmoothingFactor) +
                                  measuredLatencyMs * latencySmoothingFactor
        
        // v10.1 FIX: Remove hard cap - audio MUST follow video to maintain causality
        // If video is delayed 200ms, audio must also be delayed 200ms
        // Only enforce minimum (20ms) to avoid buffer underruns
        let adjustedMs = max(20, measuredVideoLatencyMs)
        targetSamples = Int(adjustedMs / 1000.0 * Double(sampleRate))
        
        // Log significant changes
        if abs(measuredLatencyMs - Double(lastLoggedTarget)) > 10 {
            lastLoggedTarget = Int(adjustedMs)
            DebugLog.info("LowLatencyAudio", "🎯 Closed-loop sync: video=\(String(format: "%.0f", measuredLatencyMs))ms → audio target=\(String(format: "%.0f", adjustedMs))ms")
        }
    }
    
    /// Legacy: Set fixed target latency (for initial A/V sync before measurements)
    func setTargetLatency(milliseconds: Double) {
        measuredVideoLatencyMs = milliseconds
        // v10.1: Only enforce minimum, no upper cap
        let adjustedMs = max(20, milliseconds)
        targetSamples = Int(adjustedMs / 1000.0 * Double(sampleRate))
        DebugLog.info("LowLatencyAudio", "🎯 Initial A/V Sync target: \(String(format: "%.0f", adjustedMs))ms (\(targetSamples) samples)")
    }
    
    /// Get current target latency in milliseconds
    var currentTargetLatencyMs: Double {
        return Double(targetSamples) / Double(sampleRate) * 1000
    }
    
    func stop() {
        guard isRunning else { return }
        
        audioEngine?.stop()
        audioEngine = nil
        leftSourceNode = nil
        rightSourceNode = nil
        leftRingBuffer.reset()
        rightRingBuffer.reset()
        stereoRingBuffer.reset()
        isRunning = false
        pendingSkipSamples = 0
        
        let stats = syncController?.driftCorrector.stats
        #if DEBUG
        print("[LowLatencyAudio] Stopped (underruns: \(underrunCount), drift adjustments: \(driftAdjustments))")
        if let stats = stats {
            print("[LowLatencyAudio]   Sync stats: corrections=\(stats.correctionCount), skipped=\(stats.samplesSkipped), dup=\(stats.samplesDuplicated), drops=\(stats.emergencyDrops)")
        }
        #endif
    }
    
    /// Enqueue PCM samples from chiaki callback (producer side)
    /// Input: Interleaved stereo Int16 samples
    func enqueueSamples(_ data: Data, sampleCount: Int) {
        // v10.0: Deinterleave stereo into separate L/R buffers
        data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let int16Ptr = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            
            let frameCount = sampleCount / channels
            
            // Temporary buffers for deinterleaving
            var leftSamples = [Int16](repeating: 0, count: frameCount)
            var rightSamples = [Int16](repeating: 0, count: frameCount)
            
            // Deinterleave: LRLRLR → L L L, R R R
            for i in 0..<frameCount {
                leftSamples[i] = int16Ptr[i * 2]
                rightSamples[i] = int16Ptr[i * 2 + 1]
            }
            
            // Write to separate ring buffers
            leftSamples.withUnsafeBytes { leftRingBuffer.write(Data($0)) }
            rightSamples.withUnsafeBytes { rightRingBuffer.write(Data($0)) }
        }
        
        // Log periodically
        totalSamplesProcessed += UInt64(sampleCount)
        #if DEBUG
        if totalSamplesProcessed % UInt64(sampleRate * 2) < UInt64(sampleCount) {
            let leftMs = Double(leftRingBuffer.availableSamples) / Double(sampleRate) * 1000
            let ratePercent = (playbackRate - 1.0) * 100
            print("[LowLatencyAudio] Buffer L: \(String(format: "%.1f", leftMs))ms, Rate: \(String(format: "%+.2f", ratePercent))%")
        }
        #endif
    }
    
    // MARK: - v10.0 Stereo Emitter Array Setup
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        
        try session.setPreferredSampleRate(Double(sampleRate))
        try session.setPreferredIOBufferDuration(0.005)  // 5ms
        try session.setActive(true)
        
        let actualBuffer = session.ioBufferDuration * 1000
        DebugLog.info("LowLatencyAudio", "IO Buffer: \(String(format: "%.1f", actualBuffer))ms")
    }
    
    /// v10.0: Setup Stereo Emitter Array with L/R positioned at screen edges
    /// v10.1: Supports Direct Stereo mode (bypass HRTF) for PS5 Tempest Engine audio
    /// This preserves stereo imaging instead of collapsing to mono
    private func setupStereoEmitterArray() {
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        // Mono format for each emitter
        monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: 1
        )
        
        guard let format = monoFormat else { return }
        
        // Create LEFT channel source node
        leftSourceNode = AVAudioSourceNode(format: format) { [weak self] (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            return self?.renderChannel(
                isLeft: true,
                isSilence: isSilence,
                frameCount: frameCount,
                audioBufferList: audioBufferList
            ) ?? noErr
        }
        
        // Create RIGHT channel source node
        rightSourceNode = AVAudioSourceNode(format: format) { [weak self] (isSilence, timestamp, frameCount, audioBufferList) -> OSStatus in
            return self?.renderChannel(
                isLeft: false,
                isSilence: isSilence,
                frameCount: frameCount,
                audioBufferList: audioBufferList
            ) ?? noErr
        }
        
        guard let leftSource = leftSourceNode, let rightSource = rightSourceNode else { return }
        
        // Attach source nodes
        engine.attach(leftSource)
        engine.attach(rightSource)
        
        // v10.1: Direct Stereo mode - bypass HRTF for PS5 Tempest Engine audio
        if !spatialAudioEnabled {
            // Direct path: L/R Sources → MainMixerNode (no HRTF processing)
            // This preserves PS5's Tempest Engine binaural audio without double-processing
            engine.connect(leftSource, to: engine.mainMixerNode, format: format)
            engine.connect(rightSource, to: engine.mainMixerNode, format: format)
            
            // Pan L/R to proper stereo positions
            leftSource.pan = -1.0   // Full left
            rightSource.pan = +1.0  // Full right
            
            DebugLog.info("LowLatencyAudio", "🎧 Direct Stereo enabled (HRTF bypassed, Tempest preserved)")
            return
        }
        
        // v10.0: Spatial audio path with HRTF processing
        // Create environment node for 3D positioning
        environmentNode = AVAudioEnvironmentNode()
        guard let envNode = environmentNode else {
            // Fallback: direct to mixer (no spatial audio)
            engine.connect(leftSource, to: engine.mainMixerNode, format: format)
            engine.connect(rightSource, to: engine.mainMixerNode, format: format)
            DebugLog.warning("LowLatencyAudio", "Fallback to non-spatial stereo")
            return
        }
        
        // Configure environment
        envNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        envNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        envNode.renderingAlgorithm = .HRTFHQ
        
        // v10.0: Position emitters at screen edges for proper stereo imaging
        // Left speaker at left edge of virtual screen
        let halfWidth = virtualScreenWidth / 2
        leftSource.position = AVAudio3DPoint(
            x: -halfWidth,   // Left edge
            y: 0,            // Eye level
            z: -virtualScreenDistance  // Screen distance
        )
        leftSource.sourceMode = .pointSource
        leftSource.renderingAlgorithm = .HRTFHQ
        
        // Right speaker at right edge of virtual screen
        rightSource.position = AVAudio3DPoint(
            x: +halfWidth,   // Right edge
            y: 0,            // Eye level
            z: -virtualScreenDistance  // Screen distance
        )
        rightSource.sourceMode = .pointSource
        rightSource.renderingAlgorithm = .HRTFHQ
        
        // Build audio graph: L/R Sources → Environment → Mixer → Output
        engine.attach(envNode)
        engine.connect(leftSource, to: envNode, format: format)
        engine.connect(rightSource, to: envNode, format: format)
        engine.connect(envNode, to: engine.mainMixerNode, format: nil)
        
        DebugLog.info("LowLatencyAudio", "🔊 Stereo Emitter Array enabled (HRTF active, L: -\(halfWidth), R: +\(halfWidth), dist: \(virtualScreenDistance)m)")
    }
    
    /// Render callback for a single channel (L or R)
    private func renderChannel(
        isLeft: Bool,
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        
        // Only update drift compensation on left channel to avoid double-adjustment
        if isLeft {
            updateDriftCompensation()
        }
        
        let ringBuffer = isLeft ? leftRingBuffer : rightRingBuffer
        var samplesNeeded = Int(frameCount)
        
        // v10.2: Handle pending skip samples (emergency drop or catch-up)
        if isLeft && pendingSkipSamples > 0 {
            // Skip samples from buffer (discard without playing)
            let skipCount = min(pendingSkipSamples, ringBuffer.availableSamples - samplesNeeded)
            if skipCount > 0 {
                // Read and discard samples
                ensureConversionBuffers(size: skipCount)
                if let discardBuf = int16Buffer {
                    _ = ringBuffer.read(discardBuf, count: skipCount)
                    pendingSkipSamples -= skipCount
                    
                    // Apply crossfade at boundary to avoid click
                    if samplesNeeded > 0 {
                        // Next read will get the remaining samples with fade-in
                    }
                }
            }
        }
        
        // Apply drift compensation via rate
        if isLeft {
            driftAccumulator += (playbackRate - 1.0) * Float(samplesNeeded)
            let driftSamples = Int(driftAccumulator)
            if abs(driftSamples) >= 1 {
                samplesNeeded += driftSamples
                driftAccumulator -= Float(driftSamples)
                driftAdjustments += 1
            }
        }
        
        // Ensure buffers
        ensureConversionBuffers(size: samplesNeeded)
        
        guard let int16Buf = int16Buffer, let floatBuf = floatBuffer else {
            return noErr
        }
        
        // Read from channel's ring buffer
        let samplesRead = ringBuffer.read(int16Buf, count: samplesNeeded)
        
        if samplesRead == 0 {
            isSilence.pointee = true
            underrunCount += 1
            
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
        
        isSilence.pointee = false
        
        // Convert Int16 → Float32
        vDSP_vflt16(int16Buf, 1, floatBuf, 1, vDSP_Length(samplesRead))
        
        var scale: Float = 1.0 / 32768.0
        vDSP_vsmul(floatBuf, 1, &scale, floatBuf, 1, vDSP_Length(samplesRead))
        
        // Copy to output buffer (mono, so just copy directly)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        if let buffer = buffers.first, let outData = buffer.mData?.assumingMemoryBound(to: Float.self) {
            let copyCount = min(Int(frameCount), samplesRead)
            memcpy(outData, floatBuf, copyCount * MemoryLayout<Float>.size)
            
            // Fill remaining with silence if needed
            if copyCount < Int(frameCount) {
                memset(outData.advanced(by: copyCount), 0, (Int(frameCount) - copyCount) * MemoryLayout<Float>.size)
            }
        }
        
        return noErr
    }
    
    /// v10.2: Update playback rate using sync controller or PID controller
    private func updateDriftCompensation() {
        // Calculate buffer level
        let availableSamples = (leftRingBuffer.availableSamples + rightRingBuffer.availableSamples) / 2
        let bufferMs = Double(availableSamples) / Double(sampleRate) * 1000
        
        // v10.2: Use sync controller if available
        if ptsSyncEnabled, let syncController = syncController {
            let strategy = syncController.getCorrectionStrategy(audioBufferMs: bufferMs)
            
            switch strategy {
            case .none:
                playbackRate = 1.0
                
            case .rateAdjust:
                playbackRate = syncController.getPlaybackRateAdjustment()
                
            case .skipSamples:
                // Calculate samples to skip
                let skipSamples = syncController.driftCorrector.calculateSampleAdjustment()
                pendingSkipSamples = skipSamples
                playbackRate = 1.0
                DebugLog.info("LowLatencyAudio", "⏩ Skip \(skipSamples) samples (\(String(format: "%.0f", Double(skipSamples) / Double(sampleRate) * 1000))ms)")
                
            case .duplicateSamples:
                // Slow down via rate (duplicate is harder in pull model)
                playbackRate = 0.995
                
            case .emergencyDrop:
                // Calculate and schedule drop
                let dropSamples = syncController.getEmergencyDropSamples(currentBufferSamples: availableSamples)
                pendingSkipSamples = dropSamples
                playbackRate = 1.0
            }
            
            // Log status periodically
            syncController.driftCorrector.logStatus(bufferMs: bufferMs)
            return
        }
        
        // Legacy: PID controller fallback
        let error = Float(availableSamples - targetSamples) / Float(max(targetSamples, 1))
        
        pidIntegral += error
        pidIntegral = max(-100, min(100, pidIntegral))
        
        let derivative = error - pidPreviousError
        pidPreviousError = error
        
        let adjustment = kP * error + kI * pidIntegral + kD * derivative
        playbackRate = 1.0 + max(-maxRateAdjustment, min(maxRateAdjustment, adjustment))
    }
    
    private func ensureConversionBuffers(size: Int) {
        guard size > conversionBufferSize else { return }
        
        int16Buffer?.deallocate()
        floatBuffer?.deallocate()
        
        int16Buffer = UnsafeMutablePointer<Int16>.allocate(capacity: size)
        floatBuffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
        conversionBufferSize = size
    }
}
