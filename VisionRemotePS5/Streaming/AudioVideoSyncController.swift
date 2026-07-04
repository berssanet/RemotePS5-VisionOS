//
//  AudioVideoSyncController.swift
//  VisionRemotePS5
//
//  Audio/Video synchronization controller using PTS comparison.
//  Implements drift correction with smooth sample skip/duplicate.
//

import Foundation
import Accelerate

// MARK: - Video Master Clock

/// Master clock based on video presentation timestamps.
/// Audio synchronizes to this clock for lip-sync accuracy.
final class VideoMasterClock: @unchecked Sendable {
    
    /// Current video PTS in seconds
    private var currentPTS: Double = 0
    
    /// System time when PTS was last updated
    private var lastUpdateTime: UInt64 = 0
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    /// Whether the clock has been initialized
    private(set) var isRunning = false
    
    /// Get mach timebase for nanosecond conversion
    private static let timebaseInfo: mach_timebase_info = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()
    
    /// Update master clock with new video PTS
    /// Call this when a video frame is presented
    func update(pts: Double) {
        lock.lock()
        currentPTS = pts
        lastUpdateTime = mach_absolute_time()
        isRunning = true
        lock.unlock()
    }
    
    /// Get interpolated current time based on PTS + elapsed time
    /// Returns time in seconds
    var currentTime: Double {
        lock.lock()
        defer { lock.unlock() }
        
        guard isRunning else { return 0 }
        
        // Calculate elapsed time since last PTS update
        let now = mach_absolute_time()
        let elapsed = now - lastUpdateTime
        let elapsedNanos = elapsed * UInt64(Self.timebaseInfo.numer) / UInt64(Self.timebaseInfo.denom)
        let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000.0
        
        return currentPTS + elapsedSeconds
    }
    
    /// Reset clock
    func reset() {
        lock.lock()
        currentPTS = 0
        lastUpdateTime = 0
        isRunning = false
        lock.unlock()
    }
}

// MARK: - Audio Drift Corrector

/// Drift correction strategies
enum DriftCorrectionStrategy {
    case none           // No correction needed
    case rateAdjust     // Small adjustment via playback rate
    case skipSamples    // Audio is behind - skip samples
    case duplicateSamples // Audio is ahead - duplicate samples
    case emergencyDrop  // Buffer overflow - aggressive drop
}

/// Statistics for drift correction
struct DriftCorrectionStats {
    var totalDriftMs: Double = 0
    var correctionCount: Int = 0
    var samplesSkipped: Int = 0
    var samplesDuplicated: Int = 0
    var emergencyDrops: Int = 0
    var lastCorrectionTime: Double = 0
}

/// Audio drift corrector with smooth sample manipulation.
final class AudioDriftCorrector: @unchecked Sendable {
    
    // MARK: - Configuration
    
    /// Threshold in milliseconds before correction kicks in
    var driftThresholdMs: Double = 20.0
    
    /// Threshold for aggressive correction (skip/duplicate samples)
    var aggressiveThresholdMs: Double = 50.0
    
    /// Maximum buffer before emergency drop (latency accumulation)
    var maxBufferMs: Double = 100.0
    
    /// Target buffer after emergency drop (gives headroom)
    var targetBufferMs: Double = 40.0
    
    /// Crossfade duration for smooth sample manipulation (ms)
    var crossfadeMs: Double = 2.0
    
    // MARK: - State
    
    /// Current audio PTS in seconds
    private var audioPTS: Double = 0
    
    /// Reference to master clock
    private weak var masterClock: VideoMasterClock?
    
    /// Statistics
    private(set) var stats = DriftCorrectionStats()
    
    /// Sample rate for calculations
    private let sampleRate: Int
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    // MARK: - Crossfade Buffers
    
    /// Buffer for crossfade operations
    private var crossfadeBuffer: UnsafeMutablePointer<Int16>?
    private var crossfadeBufferSize: Int = 0
    
    // MARK: - Initialization
    
    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        
        // Pre-allocate crossfade buffer (2ms @ sample rate, stereo)
        let crossfadeSamples = Int(Double(sampleRate) * 0.002) * 2
        crossfadeBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: crossfadeSamples)
        crossfadeBufferSize = crossfadeSamples
    }
    
    deinit {
        crossfadeBuffer?.deallocate()
    }
    
    /// Set reference to master clock
    func setMasterClock(_ clock: VideoMasterClock) {
        lock.lock()
        masterClock = clock
        lock.unlock()
    }
    
    /// Update audio PTS when receiving new audio packet
    func updateAudioPTS(_ pts: Double) {
        lock.lock()
        audioPTS = pts
        lock.unlock()
    }
    
    // MARK: - Drift Calculation
    
    /// Calculate current drift in milliseconds
    /// Positive = audio ahead, Negative = audio behind
    func calculateDriftMs() -> Double {
        lock.lock()
        let localAudioPTS = audioPTS
        lock.unlock()
        
        guard let clock = masterClock, clock.isRunning else {
            return 0
        }
        
        let videoPTS = clock.currentTime
        let driftSeconds = localAudioPTS - videoPTS
        let driftMs = driftSeconds * 1000.0
        
        stats.totalDriftMs = driftMs
        
        return driftMs
    }
    
    /// Determine correction strategy based on current drift
    func determineStrategy(bufferMs: Double) -> DriftCorrectionStrategy {
        let driftMs = calculateDriftMs()
        
        // Check for latency accumulation (buffer overflow)
        if bufferMs > maxBufferMs {
            stats.emergencyDrops += 1
            DebugLog.print("[AudioSync] ⚠️ Emergency drop: buffer=\(String(format: "%.0f", bufferMs))ms > max=\(maxBufferMs)ms")
            return .emergencyDrop
        }
        
        let absDrift = abs(driftMs)
        
        // Within threshold - no correction
        if absDrift < driftThresholdMs {
            return .none
        }
        
        stats.correctionCount += 1
        
        // Moderate drift - use rate adjustment
        if absDrift < aggressiveThresholdMs {
            return .rateAdjust
        }
        
        // Large drift - skip or duplicate samples
        if driftMs < 0 {
            // Audio behind video - skip samples to catch up
            return .skipSamples
        } else {
            // Audio ahead of video - duplicate samples to slow down
            return .duplicateSamples
        }
    }
    
    /// Calculate playback rate adjustment for moderate drift
    /// Returns rate (1.0 = normal, <1.0 = slower, >1.0 = faster)
    func calculateRateAdjustment() -> Float {
        let driftMs = calculateDriftMs()
        
        // Rate adjustment proportional to drift
        // Max adjustment: ±0.5% for imperceptible change
        let maxAdjustment: Float = 0.005
        let adjustmentPerMs: Float = maxAdjustment / Float(aggressiveThresholdMs)
        
        var adjustment = Float(driftMs) * adjustmentPerMs
        adjustment = max(-maxAdjustment, min(maxAdjustment, adjustment))
        
        // Negative drift (audio behind) = speed up (rate > 1.0)
        // Positive drift (audio ahead) = slow down (rate < 1.0)
        return 1.0 - adjustment
    }
    
    // MARK: - Sample Manipulation
    
    /// Calculate number of samples to skip/duplicate
    func calculateSampleAdjustment() -> Int {
        let driftMs = calculateDriftMs()
        let driftSamples = Int(abs(driftMs) / 1000.0 * Double(sampleRate))
        
        // Limit to avoid large jumps
        let maxSamples = sampleRate / 10 // Max 100ms jump
        return min(driftSamples, maxSamples)
    }
    
    /// Calculate samples to drop for emergency recovery
    func calculateEmergencyDropSamples(currentBufferSamples: Int) -> Int {
        let targetSamples = Int(targetBufferMs / 1000.0 * Double(sampleRate))
        let dropSamples = currentBufferSamples - targetSamples
        
        if dropSamples > 0 {
            stats.samplesSkipped += dropSamples
            DebugLog.print("[AudioSync] 🗑️ Dropping \(dropSamples) samples (\(String(format: "%.0f", Double(dropSamples) / Double(sampleRate) * 1000))ms)")
        }
        
        return max(0, dropSamples)
    }
    
    /// Apply crossfade to avoid clicks when skipping/duplicating
    /// - Parameters:
    ///   - buffer: Audio buffer to modify
    ///   - count: Number of samples in buffer
    ///   - skipCount: Samples to skip (or negative for duplicate)
    func applyCrossfade(
        buffer: UnsafeMutablePointer<Int16>,
        count: Int,
        isStart: Bool
    ) {
        let crossfadeSamples = min(Int(crossfadeMs / 1000.0 * Double(sampleRate)), count / 2)
        guard crossfadeSamples > 0 else { return }
        
        if isStart {
            // Fade in at start
            for i in 0..<crossfadeSamples {
                let factor = Float(i) / Float(crossfadeSamples)
                buffer[i] = Int16(Float(buffer[i]) * factor)
            }
        } else {
            // Fade out at end
            for i in 0..<crossfadeSamples {
                let idx = count - crossfadeSamples + i
                let factor = Float(crossfadeSamples - i) / Float(crossfadeSamples)
                buffer[idx] = Int16(Float(buffer[idx]) * factor)
            }
        }
    }
    
    // MARK: - Smooth Resampling (v10.3)
    
    /// Perform smooth linear interpolation resampling to adjust effective sample rate.
    /// This allows imperceptible speed adjustment (±0.5%) without audible artifacts.
    ///
    /// - Parameters:
    ///   - input: Input buffer (Int16 samples)
    ///   - inputCount: Number of input samples
    ///   - output: Output buffer (must have capacity for outputCount samples)
    ///   - outputCount: Desired number of output samples
    /// - Returns: Actual number of samples written to output
    func resampleLinear(
        input: UnsafePointer<Int16>,
        inputCount: Int,
        output: UnsafeMutablePointer<Int16>,
        outputCount: Int
    ) -> Int {
        guard inputCount > 1 && outputCount > 0 else { return 0 }
        
        // Rate ratio (< 1.0 = stretch audio = slow down, > 1.0 = compress = speed up)
        let ratio = Float(inputCount - 1) / Float(outputCount - 1)
        
        for i in 0..<outputCount {
            let srcPos = Float(i) * ratio
            let srcIndex = Int(srcPos)
            let frac = srcPos - Float(srcIndex)
            
            if srcIndex + 1 < inputCount {
                // Linear interpolation between samples
                let sample0 = Float(input[srcIndex])
                let sample1 = Float(input[srcIndex + 1])
                let interpolated = sample0 + frac * (sample1 - sample0)
                output[i] = Int16(clamping: Int(interpolated))
            } else {
                // Edge case: use last sample
                output[i] = input[inputCount - 1]
            }
        }
        
        return outputCount
    }
    
    /// Calculate output sample count for smooth rate adjustment.
    /// Adjusts by ±0.5% max for imperceptible speed change.
    ///
    /// - Parameters:
    ///   - inputCount: Original sample count
    ///   - driftMs: Current drift in milliseconds (positive = audio ahead)
    /// - Returns: Target output sample count
    func calculateResampledCount(inputCount: Int, driftMs: Double) -> Int {
        // Max rate adjustment ±0.5% (imperceptible)
        let maxAdjustment: Double = 0.005
        
        // Scale adjustment based on drift
        let adjustmentScale = min(abs(driftMs) / aggressiveThresholdMs, 1.0)
        var adjustment = adjustmentScale * maxAdjustment
        
        if driftMs < 0 {
            // Audio behind: need fewer samples (speed up) → outputCount < inputCount
            adjustment = -adjustment
        }
        // else: Audio ahead → keep positive adjustment (slow down)
        
        return Int(Double(inputCount) * (1.0 + adjustment))
    }
    
    /// Insert silence microscopically to slow down audio playback.
    /// Used when audio is ahead of video.
    ///
    /// - Parameters:
    ///   - buffer: Buffer to modify (with extra capacity)
    ///   - count: Current sample count
    ///   - silenceSamples: Number of silence samples to insert
    ///   - capacity: Total buffer capacity
    /// - Returns: New total sample count
    func insertMicroSilence(
        buffer: UnsafeMutablePointer<Int16>,
        count: Int,
        silenceSamples: Int,
        capacity: Int
    ) -> Int {
        let insertCount = min(silenceSamples, capacity - count)
        guard insertCount > 0 else { return count }
        
        // Find optimal insertion point (near center to minimize perception)
        let insertPoint = count / 2
        
        // Shift samples after insertion point
        memmove(
            buffer.advanced(by: insertPoint + insertCount),
            buffer.advanced(by: insertPoint),
            (count - insertPoint) * MemoryLayout<Int16>.stride
        )
        
        // Insert zero samples (silence) with slight crossfade
        let fadeLen = min(4, insertCount / 2)
        for i in 0..<insertCount {
            var value: Int16 = 0
            
            // Crossfade at edges
            if i < fadeLen && insertPoint > 0 {
                let factor = Float(fadeLen - i) / Float(fadeLen)
                value = Int16(Float(buffer[insertPoint - 1]) * factor)
            } else if i >= insertCount - fadeLen && insertPoint + insertCount < count + insertCount {
                let factor = Float(i - (insertCount - fadeLen)) / Float(fadeLen)
                value = Int16(Float(buffer[insertPoint + insertCount]) * factor)
            }
            
            buffer[insertPoint + i] = value
        }
        
        stats.samplesDuplicated += insertCount
        return count + insertCount
    }
    
    // MARK: - Diagnostics
    
    /// Log current sync status
    func logStatus(bufferMs: Double) {
        let driftMs = calculateDriftMs()
        let strategy = determineStrategy(bufferMs: bufferMs)
        
        let strategyName: String
        switch strategy {
        case .none: strategyName = "OK"
        case .rateAdjust: strategyName = "RATE"
        case .skipSamples: strategyName = "SKIP"
        case .duplicateSamples: strategyName = "DUP"
        case .emergencyDrop: strategyName = "DROP"
        }
        
        if abs(driftMs) > driftThresholdMs || strategy == .emergencyDrop {
            DebugLog.print("[AudioSync] Drift: \(String(format: "%+.1f", driftMs))ms | Buffer: \(String(format: "%.0f", bufferMs))ms | Strategy: \(strategyName)")
        }
    }
    
    /// Reset statistics
    func resetStats() {
        lock.lock()
        stats = DriftCorrectionStats()
        lock.unlock()
    }
}

// MARK: - Audio/Video Sync Controller

/// Main controller that coordinates audio/video synchronization.
final class AudioVideoSyncController: @unchecked Sendable {
    
    /// Master clock for video timing
    let masterClock = VideoMasterClock()
    
    /// Drift corrector for audio
    let driftCorrector: AudioDriftCorrector
    
    /// Sample rate
    let sampleRate: Int
    
    /// Enable/disable sync (for debugging)
    var syncEnabled = true
    
    init(sampleRate: Int = 48000) {
        self.sampleRate = sampleRate
        self.driftCorrector = AudioDriftCorrector(sampleRate: sampleRate)
        self.driftCorrector.setMasterClock(masterClock)
    }
    
    /// Update video PTS when frame is presented
    func onVideoFramePresented(pts: Double) {
        masterClock.update(pts: pts)
    }
    
    /// Update audio PTS when packet is received
    func onAudioPacketReceived(pts: Double) {
        driftCorrector.updateAudioPTS(pts)
    }
    
    /// Get correction strategy for current state
    func getCorrectionStrategy(audioBufferMs: Double) -> DriftCorrectionStrategy {
        guard syncEnabled else { return .none }
        return driftCorrector.determineStrategy(bufferMs: audioBufferMs)
    }
    
    /// Get rate adjustment for audio playback
    func getPlaybackRateAdjustment() -> Float {
        guard syncEnabled else { return 1.0 }
        return driftCorrector.calculateRateAdjustment()
    }
    
    /// Calculate samples to drop for emergency recovery
    func getEmergencyDropSamples(currentBufferSamples: Int) -> Int {
        return driftCorrector.calculateEmergencyDropSamples(currentBufferSamples: currentBufferSamples)
    }
    
    /// Reset synchronization state
    func reset() {
        masterClock.reset()
        driftCorrector.resetStats()
    }
}
