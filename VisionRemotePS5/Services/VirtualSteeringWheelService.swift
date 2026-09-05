//
//  VirtualSteeringWheelService.swift
//  VisionRemotePS5
//
//  v10.6: Virtual steering wheel using ARKit hand tracking
//  Tracks hand positions to calculate steering angle and pinch gestures for triggers
//

import Foundation
import ARKit
import Combine
import simd

/// Service for tracking hands and converting to steering wheel input
@MainActor
final class VirtualSteeringWheelService: ObservableObject {
    
    // MARK: - Published Values
    
    /// Steering angle from -1.0 (full left) to 1.0 (full right)
    @Published private(set) var steeringValue: Float = 0
    
    /// Left hand trigger (brake) from 0.0 to 1.0
    @Published private(set) var leftTrigger: Float = 0
    
    /// Right hand trigger (accelerator) from 0.0 to 1.0
    @Published private(set) var rightTrigger: Float = 0
    
    /// Whether both hands are being tracked
    @Published private(set) var isTracking: Bool = false
    
    /// Left hand position in world space
    @Published private(set) var leftHandPosition: SIMD3<Float>?
    
    /// Right hand position in world space
    @Published private(set) var rightHandPosition: SIMD3<Float>?
    
    // MARK: - Private Properties
    
    private var handTrackingProvider: HandTrackingProvider?
    private var arkitSession: ARKitSession?
    private var trackingTask: Task<Void, Never>?
    
    /// Maximum steering angle in radians (45° = full lock)
    private let maxSteeringAngle: Float = .pi / 4
    
    // MARK: - Public Interface
    
    /// Start hand tracking
    func startTracking() async throws {
        guard handTrackingProvider == nil else { return }
        
        // Create hand tracking provider
        let provider = HandTrackingProvider()
        handTrackingProvider = provider
        
        // Create and run ARKit session
        let session = ARKitSession()
        arkitSession = session
        
        do {
            try await session.run([provider])
            DebugLog.print("[VirtualSteering] ✅ Hand tracking started successfully!")
            
            // Start processing updates
            startProcessingUpdates()
            DebugLog.print("[VirtualSteering] Update processing task started")
        } catch {
            DebugLog.print("[VirtualSteering] ❌ Failed to start: \(error)")
            DebugLog.print("[VirtualSteering] Error details: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Stop hand tracking
    func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        arkitSession?.stop()
        arkitSession = nil
        handTrackingProvider = nil
        
        isTracking = false
        steeringValue = 0
        leftTrigger = 0
        rightTrigger = 0
        leftHandPosition = nil
        rightHandPosition = nil
        
        DebugLog.print("[VirtualSteering] Hand tracking stopped")
    }
    
    // MARK: - Private Methods
    
    private func startProcessingUpdates() {
        guard let provider = handTrackingProvider else { return }
        
        trackingTask = Task { [weak self] in
            DebugLog.print("[VirtualSteering] 🔄 Starting anchor updates loop...")
            var updateCount = 0
            
            for await update in provider.anchorUpdates {
                guard let self = self else { 
                    DebugLog.print("[VirtualSteering] Self is nil, breaking")
                    break 
                }
                
                updateCount += 1
                if updateCount % 60 == 1 {  // Log every ~1 second at 60Hz
                    DebugLog.print("[VirtualSteering] Received \(updateCount) updates")
                }
                
                self.processHandUpdate(update)
            }
            DebugLog.print("[VirtualSteering] ⚠️ Anchor updates loop ended")
        }
    }
    
    private func processHandUpdate(_ update: AnchorUpdate<HandAnchor>) {
        let anchor = update.anchor
        
        // Update hand positions
        if anchor.chirality == .left {
            if anchor.isTracked {
                leftHandPosition = extractWristPosition(from: anchor)
                leftTrigger = calculatePinchValue(from: anchor)
            } else {
                leftHandPosition = nil
                leftTrigger = 0
            }
        } else {
            if anchor.isTracked {
                rightHandPosition = extractWristPosition(from: anchor)
                rightTrigger = calculatePinchValue(from: anchor)
            } else {
                rightHandPosition = nil
                rightTrigger = 0
            }
        }
        
        // Update tracking state
        let wasTracking = isTracking
        isTracking = leftHandPosition != nil && rightHandPosition != nil
        
        // Log state changes
        if isTracking != wasTracking {
            DebugLog.print("[VirtualSteering] 🖐️ Tracking state: \(isTracking ? "BOTH HANDS" : "INCOMPLETE")")
        }
        
        // Calculate steering if both hands tracked
        if let leftPos = leftHandPosition, let rightPos = rightHandPosition {
            steeringValue = calculateSteering(leftHand: leftPos, rightHand: rightPos)
            
            // Log values periodically
            if abs(steeringValue) > 0.1 || leftTrigger > 0.1 || rightTrigger > 0.1 {
                // Only log when there's significant input
                DebugLog.print("[VirtualSteering] 🎮 Steer: \(String(format: "%+.2f", steeringValue)) L2: \(String(format: "%.2f", leftTrigger)) R2: \(String(format: "%.2f", rightTrigger))")
            }
        } else {
            steeringValue = 0
        }
    }
    
    /// Extract wrist position from hand anchor
    private func extractWristPosition(from anchor: HandAnchor) -> SIMD3<Float> {
        // Get the hand's transform in world space
        let transform = anchor.originFromAnchorTransform
        
        // Try to get wrist joint for more accurate position
        if let skeleton = anchor.handSkeleton {
            let wristJoint = skeleton.joint(.wrist)
            // Combine anchor transform with joint transform
            let worldTransform = transform * wristJoint.anchorFromJointTransform
            return SIMD3<Float>(
                worldTransform.columns.3.x,
                worldTransform.columns.3.y,
                worldTransform.columns.3.z
            )
        }
        
        // Fallback to anchor position
        return SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
    }
    
    /// Calculate pinch value (0.0 to 1.0) based on thumb-index finger distance
    private func calculatePinchValue(from anchor: HandAnchor) -> Float {
        guard let skeleton = anchor.handSkeleton else {
            return 0
        }
        
        let thumbTip = skeleton.joint(.thumbTip)
        let indexTip = skeleton.joint(.indexFingerTip)
        
        guard thumbTip.isTracked && indexTip.isTracked else {
            return 0
        }
        
        // Get positions in anchor space
        let thumbPos = SIMD3<Float>(
            thumbTip.anchorFromJointTransform.columns.3.x,
            thumbTip.anchorFromJointTransform.columns.3.y,
            thumbTip.anchorFromJointTransform.columns.3.z
        )
        let indexPos = SIMD3<Float>(
            indexTip.anchorFromJointTransform.columns.3.x,
            indexTip.anchorFromJointTransform.columns.3.y,
            indexTip.anchorFromJointTransform.columns.3.z
        )
        
        // Calculate distance between fingertips
        let distance = simd_length(thumbPos - indexPos)
        
        // Convert to 0-1 value (closer = higher value)
        // Max distance ~8cm when fingers spread, min ~0 when touching
        let maxDistance: Float = 0.08
        let normalizedDistance = min(distance / maxDistance, 1.0)
        
        // Invert so touching = 1.0
        let pinchValue = 1.0 - normalizedDistance
        
        // Apply threshold to reduce noise
        if pinchValue < 0.3 {
            return 0
        }
        
        // Remap 0.3-1.0 to 0.0-1.0
        return (pinchValue - 0.3) / 0.7
    }
    
    /// Calculate steering value based on hand positions
    private func calculateSteering(leftHand: SIMD3<Float>, rightHand: SIMD3<Float>) -> Float {
        // Calculate vector from left to right hand
        let handVector = SIMD2<Float>(
            rightHand.x - leftHand.x,
            rightHand.y - leftHand.y
        )
        
        // Calculate angle from horizontal
        // When hands are level, angle = 0
        // When right hand is higher, angle > 0 (turning right)
        // When left hand is higher, angle < 0 (turning left)
        let angle = atan2(handVector.y, abs(handVector.x))
        
        // Normalize to -1.0 to 1.0 based on max steering angle
        var normalizedSteering = angle / maxSteeringAngle
        
        // Clamp to valid range
        normalizedSteering = max(-1.0, min(1.0, normalizedSteering))
        
        // Apply small deadzone to center
        if abs(normalizedSteering) < 0.05 {
            return 0
        }
        
        // INVERT: negate to fix left/right direction
        return -normalizedSteering
    }
}
