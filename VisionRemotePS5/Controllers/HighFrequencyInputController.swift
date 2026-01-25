//
//  HighFrequencyInputController.swift
//  VisionRemotePS5
//
//  Dedicated high-frequency input polling loop running off MainActor.
//  Minimizes input-to-network latency for competitive gaming.
//

import Foundation
import GameController
import QuartzCore

// MARK: - Input Packet (Sendable for cross-thread)

/// Compact input state for network transmission
/// Designed for zero-copy serialization
struct InputPacket: Sendable {
    var buttons: UInt32 = 0
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var timestamp: UInt64 = 0  // Monotonic timestamp for latency tracking
    
    /// Serialize to bytes for network transmission (28 bytes fixed size)
    func serialize() -> Data {
        var data = Data(capacity: 28)
        
        withUnsafeBytes(of: buttons.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: leftStickX.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: leftStickY.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: rightStickX.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: rightStickY.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: leftTrigger.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: rightTrigger.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        
        return data
    }
}

// MARK: - High-Frequency Input Controller

/// Dedicated input polling controller running on high-priority thread.
///
/// Features:
/// - **Off-MainActor**: Runs on dedicated thread to avoid UI contention
/// - **High-frequency polling**: 120-240Hz configurable
/// - **Zero-allocation hot path**: Reuses buffers for serialization
/// - **Direct network send**: Bypasses Combine/callback overhead
///
/// Usage:
/// ```swift
/// let inputController = HighFrequencyInputController()
/// inputController.onInputPacket = { packet in
///     streamingSession.sendInputPacket(packet)
/// }
/// inputController.start()
/// ```
final class HighFrequencyInputController: @unchecked Sendable {
    
    // MARK: - Configuration
    
    /// Target polling frequency in Hz (default 120Hz for Vision Pro)
    var pollingFrequencyHz: Int = 120
    
    /// Minimum change threshold for analog values to reduce unnecessary packets
    var analogDeadzone: Float = 0.01
    
    /// Send input even if unchanged (for keep-alive)
    var sendUnchangedInputs: Bool = false
    
    /// Interval for unchanged input sends (if enabled)
    var unchangedSendIntervalMs: Int = 100
    
    // MARK: - Callbacks
    
    /// Called on polling thread when new input is ready
    var onInputPacket: ((InputPacket) -> Void)?
    
    /// Called for raw ControllerInput (MainActor compatible)
    var onControllerInput: ((ControllerInput) -> Void)?
    
    // MARK: - State
    
    private var isRunning = false
    private var pollingThread: Thread?
    private var lastInput = InputPacket()
    private var lastSendTime: UInt64 = 0
    
    // MARK: - Statistics
    
    private(set) var pollCount: UInt64 = 0
    private(set) var sendCount: UInt64 = 0
    private(set) var averagePollTimeNs: UInt64 = 0
    private var pollTimeSamples: [UInt64] = []
    private let maxSamples = 120
    
    // MARK: - Thread Communication
    
    private let shouldStop = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    
    // MARK: - Initialization
    
    init() {
        shouldStop.initialize(to: false)
    }
    
    deinit {
        stop()
        shouldStop.deallocate()
    }
    
    // MARK: - Public API
    
    /// Start the high-frequency polling loop
    func start() {
        guard !isRunning else { return }
        
        shouldStop.pointee = false
        isRunning = true
        
        // Create dedicated thread with high QoS
        pollingThread = Thread { [weak self] in
            self?.pollingLoop()
        }
        
        pollingThread?.name = "com.visionremoteps5.input"
        pollingThread?.qualityOfService = .userInteractive
        pollingThread?.threadPriority = 1.0 // Maximum priority
        pollingThread?.start()
        
        print("[InputController] ✅ Started at \(pollingFrequencyHz)Hz (dedicated thread)")
    }
    
    /// Stop the polling loop
    func stop() {
        guard isRunning else { return }
        
        shouldStop.pointee = true
        isRunning = false
        
        // Wait for thread to exit
        while pollingThread?.isExecuting ?? false {
            Thread.sleep(forTimeInterval: 0.001)
        }
        pollingThread = nil
        
        print("[InputController] Stopped (polls: \(pollCount), sends: \(sendCount), avg: \(averagePollTimeNs/1000)μs)")
    }
    
    // MARK: - Polling Loop
    
    private func pollingLoop() {
        let intervalNs = UInt64(1_000_000_000 / pollingFrequencyHz)
        var nextPollTime = mach_absolute_time()
        
        // Get timebase for nanosecond conversion
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        
        while !shouldStop.pointee {
            let startTime = mach_absolute_time()
            
            // Poll controller input
            if let packet = pollController() {
                pollCount += 1
                
                // Check if input changed
                let changed = inputChanged(packet, from: lastInput)
                
                if changed || shouldSendUnchanged() {
                    onInputPacket?(packet)
                    sendCount += 1
                    lastSendTime = startTime
                }
                
                lastInput = packet
            }
            
            // Measure poll time
            let endTime = mach_absolute_time()
            let pollTimeNs = (endTime - startTime) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
            updatePollStats(pollTimeNs)
            
            // Sleep until next poll time
            nextPollTime += intervalNs * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
            let now = mach_absolute_time()
            
            if nextPollTime > now {
                let sleepTime = nextPollTime - now
                mach_wait_until(nextPollTime)
            } else {
                // Missed deadline, reset
                nextPollTime = now
            }
        }
    }
    
    // MARK: - Controller Polling
    
    private func pollController() -> InputPacket? {
        // GCController access must be on a thread with RunLoop
        // We snapshot the current state directly
        guard let controller = GCController.current,
              let gamepad = controller.extendedGamepad else {
            return nil
        }
        
        var packet = InputPacket()
        packet.timestamp = mach_absolute_time()
        
        // Read analog values
        packet.leftStickX = gamepad.leftThumbstick.xAxis.value
        packet.leftStickY = gamepad.leftThumbstick.yAxis.value
        packet.rightStickX = gamepad.rightThumbstick.xAxis.value
        packet.rightStickY = gamepad.rightThumbstick.yAxis.value
        packet.leftTrigger = gamepad.leftTrigger.value
        packet.rightTrigger = gamepad.rightTrigger.value
        
        // Build button bitmask
        var buttons: UInt32 = 0
        
        if gamepad.buttonA.isPressed { buttons |= 1 << 0 }  // Cross
        if gamepad.buttonB.isPressed { buttons |= 1 << 1 }  // Circle
        if gamepad.buttonX.isPressed { buttons |= 1 << 2 }  // Square
        if gamepad.buttonY.isPressed { buttons |= 1 << 3 }  // Triangle
        if gamepad.leftShoulder.isPressed { buttons |= 1 << 4 }  // L1
        if gamepad.rightShoulder.isPressed { buttons |= 1 << 5 }  // R1
        if gamepad.leftTrigger.isPressed { buttons |= 1 << 6 }  // L2
        if gamepad.rightTrigger.isPressed { buttons |= 1 << 7 }  // R2
        if gamepad.buttonOptions?.isPressed ?? false { buttons |= 1 << 8 }  // Share
        if gamepad.buttonMenu.isPressed { buttons |= 1 << 9 }  // Options
        if gamepad.leftThumbstickButton?.isPressed ?? false { buttons |= 1 << 10 }  // L3
        if gamepad.rightThumbstickButton?.isPressed ?? false { buttons |= 1 << 11 }  // R3
        if gamepad.buttonHome?.isPressed ?? false { buttons |= 1 << 12 }  // PS
        if gamepad.dpad.up.isPressed { buttons |= 1 << 14 }
        if gamepad.dpad.down.isPressed { buttons |= 1 << 15 }
        if gamepad.dpad.left.isPressed { buttons |= 1 << 16 }
        if gamepad.dpad.right.isPressed { buttons |= 1 << 17 }
        
        packet.buttons = buttons
        
        return packet
    }
    
    // MARK: - Change Detection
    
    private func inputChanged(_ new: InputPacket, from old: InputPacket) -> Bool {
        // Buttons changed
        if new.buttons != old.buttons { return true }
        
        // Analog values changed beyond deadzone
        if abs(new.leftStickX - old.leftStickX) > analogDeadzone { return true }
        if abs(new.leftStickY - old.leftStickY) > analogDeadzone { return true }
        if abs(new.rightStickX - old.rightStickX) > analogDeadzone { return true }
        if abs(new.rightStickY - old.rightStickY) > analogDeadzone { return true }
        if abs(new.leftTrigger - old.leftTrigger) > analogDeadzone { return true }
        if abs(new.rightTrigger - old.rightTrigger) > analogDeadzone { return true }
        
        return false
    }
    
    private func shouldSendUnchanged() -> Bool {
        guard sendUnchangedInputs else { return false }
        
        var timebaseInfo = mach_timebase_info()
        mach_timebase_info(&timebaseInfo)
        
        let now = mach_absolute_time()
        let elapsedNs = (now - lastSendTime) * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
        let elapsedMs = elapsedNs / 1_000_000
        
        return elapsedMs >= UInt64(unchangedSendIntervalMs)
    }
    
    // MARK: - Statistics
    
    private func updatePollStats(_ pollTimeNs: UInt64) {
        pollTimeSamples.append(pollTimeNs)
        if pollTimeSamples.count > maxSamples {
            pollTimeSamples.removeFirst()
        }
        
        let sum = pollTimeSamples.reduce(0, +)
        averagePollTimeNs = sum / UInt64(pollTimeSamples.count)
    }
    
    /// Get statistics string
    var statisticsDescription: String {
        let avgUs = averagePollTimeNs / 1000
        let sendRate = pollCount > 0 ? Double(sendCount) / Double(pollCount) * 100 : 0
        return "[InputController] polls: \(pollCount), sends: \(sendCount) (\(String(format: "%.1f", sendRate))%), avg: \(avgUs)μs"
    }
}
