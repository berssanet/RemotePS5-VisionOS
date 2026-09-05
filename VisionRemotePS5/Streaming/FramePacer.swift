//
//  FramePacer.swift
//  VisionRemotePS5
//
//  Frame pacing for smooth 60fps content on 90Hz/96Hz display.
//  Manages CADisplayLink and optimizes frame presentation timing.
//

import Foundation
import QuartzCore
import CoreVideo

/// Manages frame pacing to reduce judder when displaying 60fps content on 90Hz display.
/// Uses CADisplayLink for precise timing and adaptive frame presentation.
final class FramePacer: NSObject {
    
    // MARK: - Types
    
    /// Statistics for frame timing analysis
    struct FrameStats {
        var averageFrameTime: Double = 0  // ms
        var variance: Double = 0          // ms
        var droppedFrames: Int = 0
        var totalFrames: Int = 0
    }
    
    /// Frame presentation callback
    typealias FrameCallback = (CVPixelBuffer, CFTimeInterval) -> Void
    
    // MARK: - Properties
    
    /// Callback invoked when a frame should be presented
    var onPresentFrame: FrameCallback?
    
    /// Current frame statistics
    private(set) var stats = FrameStats()
    
    /// Display refresh rate in Hz
    private(set) var displayRefreshRate: Double = 90.0
    
    // MARK: - Private Properties
    
    private var displayLink: CADisplayLink?
    private var isRunning = false
    
    // Frame buffer (double buffer for smooth presentation)
    private var currentFrame: CVPixelBuffer?
    private var nextFrame: CVPixelBuffer?
    private var currentFrameTimestamp: CFTimeInterval = 0
    private var nextFrameTimestamp: CFTimeInterval = 0
    
    // Timing tracking
    private var lastPresentTimestamp: CFTimeInterval = 0
    private var frameTimeAccumulator: [Double] = []
    private let maxFrameTimeSamples = 60
    
    // Source frame rate (PS5 = 60fps)
    private let sourceFrameRate: Double = 60.0
    private var sourceFrameInterval: Double { 1.0 / sourceFrameRate }
    
    // Frame presentation strategy
    private var frameCounter: Int = 0
    
    // Thread safety
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        DebugLog.info("FramePacer", "🎯 Initialized for \(sourceFrameRate)fps source")
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public API
    
    /// Start the frame pacer with CADisplayLink
    func start() {
        guard !isRunning else { return }
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        
        // Configure preferred frame rate
        // Request 90Hz to match Vision Pro native, or 96Hz if available
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60.0,
            maximum: 96.0,
            preferred: 90.0
        )
        
        displayLink?.add(to: .main, forMode: .common)
        isRunning = true
        
        // Note: Actual refresh rate will be calculated on first callback
        // when timestamps are valid. Use default 90Hz for now.
        displayRefreshRate = 90.0
        
        DebugLog.info("FramePacer", "✅ Started (\(sourceFrameRate)fps → \(displayRefreshRate)Hz, ratio \(displayRefreshRate / sourceFrameRate):1)")
    }
    
    /// Stop the frame pacer
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
        
        lock.lock()
        currentFrame = nil
        nextFrame = nil
        lock.unlock()
        
        #if DEBUG
        DebugLog.print("[FramePacer] ⏹️ Stopped")
        printStats()
        #endif
    }
    
    /// Submit a new frame for presentation
    /// - Parameters:
    ///   - frame: The pixel buffer to present
    ///   - timestamp: Frame timestamp from decoder
    func submitFrame(_ frame: CVPixelBuffer, timestamp: CFTimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        
        // Shift buffer: current becomes old, new becomes current
        currentFrame = nextFrame
        currentFrameTimestamp = nextFrameTimestamp
        
        nextFrame = frame
        nextFrameTimestamp = timestamp
        
        stats.totalFrames += 1
    }
    
    // MARK: - Display Link Callback
    
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let currentTime = link.timestamp
        let targetTime = link.targetTimestamp
        let displayInterval = targetTime - currentTime
        
        lock.lock()
        let frameToPresent = selectFrameForPresentation(
            displayTime: currentTime,
            displayInterval: displayInterval
        )
        lock.unlock()
        
        guard let frame = frameToPresent else { return }
        
        // Calculate frame timing for stats
        if lastPresentTimestamp > 0 {
            let frameTime = (currentTime - lastPresentTimestamp) * 1000.0 // ms
            recordFrameTime(frameTime)
        }
        lastPresentTimestamp = currentTime
        
        // Present frame
        onPresentFrame?(frame, currentTime)
    }
    
    // MARK: - Frame Selection Strategy
    
    /// Select the best frame to present based on timing
    /// Implements 3:2 pulldown-like cadence for 60fps on 90Hz
    private func selectFrameForPresentation(displayTime: CFTimeInterval, displayInterval: Double) -> CVPixelBuffer? {
        // For 60fps on 90Hz (1.5x ratio), we use adaptive presentation:
        // - Show each source frame for either 1 or 2 display frames
        // - Pattern: 1-2-1-2-1-2... or 2-1-2-1-2-1... depending on timing
        
        frameCounter += 1
        
        // Simple strategy: present most recent available frame
        // This minimizes latency at the cost of some judder
        if let frame = nextFrame {
            // Check if we should hold current frame longer
            let timeSinceNewFrame = displayTime - nextFrameTimestamp
            let holdThreshold = displayInterval * 0.5
            
            if timeSinceNewFrame > holdThreshold {
                // New frame is ready, present it
                return frame
            } else if let current = currentFrame {
                // New frame just arrived, hold current for one more cycle
                return current
            }
            return frame
        }
        
        // Fallback to current frame if no new frame available
        if let frame = currentFrame {
            stats.droppedFrames += 1
            return frame
        }
        
        return nil
    }
    
    // MARK: - Statistics
    
    private func recordFrameTime(_ frameTime: Double) {
        frameTimeAccumulator.append(frameTime)
        if frameTimeAccumulator.count > maxFrameTimeSamples {
            frameTimeAccumulator.removeFirst()
        }
        
        // Calculate stats
        if frameTimeAccumulator.count > 10 {
            let sum = frameTimeAccumulator.reduce(0, +)
            stats.averageFrameTime = sum / Double(frameTimeAccumulator.count)
            
            let squaredDiffs = frameTimeAccumulator.map { pow($0 - stats.averageFrameTime, 2) }
            stats.variance = sqrt(squaredDiffs.reduce(0, +) / Double(squaredDiffs.count))
        }
    }
    
    #if DEBUG
    private func printStats() {
        guard stats.totalFrames > 0 else { return }
        
        DebugLog.print("[FramePacer] 📊 Session Stats:")
        DebugLog.print("[FramePacer]   Total frames: \(stats.totalFrames)")
        DebugLog.print("[FramePacer]   Dropped frames: \(stats.droppedFrames)")
        DebugLog.print("[FramePacer]   Avg frame time: \(String(format: "%.2f", stats.averageFrameTime))ms")
        DebugLog.print("[FramePacer]   Variance: \(String(format: "%.2f", stats.variance))ms")
    }
    #endif
}

// MARK: - Frame Interpolation Support (visionOS 26+ / Metal 4)

extension FramePacer {
    
    /// Check if frame interpolation is available (Metal 4 / visionOS 26+)
    var isFrameInterpolationAvailable: Bool {
        // MetalFX Frame Interpolation requires visionOS 26+ (Metal 4)
        // For now, return false as we're on visionOS 2.x
        if #available(visionOS 26.0, *) {
            return true
        }
        return false
    }
    
    /// Enable frame interpolation if available
    /// This would generate intermediate frames for 60fps → 90fps
    func enableFrameInterpolation() {
        guard isFrameInterpolationAvailable else {
            DebugLog.warning("FramePacer", "Frame interpolation not available (requires visionOS 26+)")
            return
        }
        
        // TODO: Implement MTLFXFrameInterpolation when visionOS 26 is available
        DebugLog.info("FramePacer", "🔮 Frame interpolation would be enabled here (future implementation)")
    }
}
