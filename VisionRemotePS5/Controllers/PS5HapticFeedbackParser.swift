//
//  PS5HapticFeedbackParser.swift
//  VisionRemotePS5
//
//  Parser for PS5 haptic feedback packets.
//  Decodes rumble, adaptive triggers, and lightbar data from Remote Play stream.
//

import Foundation

// MARK: - PS5 Haptic Feedback Data

/// Parsed haptic feedback from PS5
struct PS5HapticFeedback: Sendable {
    /// Left motor intensity (0-255) - low frequency rumble
    var leftMotor: UInt8 = 0
    
    /// Right motor intensity (0-255) - high frequency rumble
    var rightMotor: UInt8 = 0
    
    /// L2 trigger effect
    var leftTrigger: AdaptiveTriggerEffect = .off
    
    /// R2 trigger effect
    var rightTrigger: AdaptiveTriggerEffect = .off
    
    /// Lightbar color (RGB)
    var lightbarRed: UInt8 = 0
    var lightbarGreen: UInt8 = 0
    var lightbarBlue: UInt8 = 0
    
    /// Player indicator LEDs (bitmask)
    var playerIndicator: UInt8 = 0
    
    /// Whether any haptic feedback is active
    var isActive: Bool {
        return leftMotor > 0 || rightMotor > 0 ||
               leftTrigger != .off || rightTrigger != .off
    }
    
    /// Lightbar as tuple
    var lightbarRGB: (UInt8, UInt8, UInt8) {
        return (lightbarRed, lightbarGreen, lightbarBlue)
    }
}

// MARK: - Adaptive Trigger Effects

/// DualSense adaptive trigger effect types
enum AdaptiveTriggerEffect: Equatable, Sendable {
    /// No effect
    case off
    
    /// Resistance at a specific point (like a button click)
    /// - Parameters:
    ///   - startPosition: Where resistance begins (0.0-1.0)
    ///   - strength: How strong the resistance (0.0-1.0)
    case feedback(startPosition: Float, strength: Float)
    
    /// Weapon-like resistance (resistance through a range)
    /// - Parameters:
    ///   - startPosition: Where resistance begins
    ///   - endPosition: Where resistance ends
    ///   - strength: Resistance strength
    case weapon(startPosition: Float, endPosition: Float, strength: Float)
    
    /// Vibrating resistance
    /// - Parameters:
    ///   - startPosition: Where vibration begins
    ///   - amplitude: Vibration strength
    ///   - frequency: Vibration frequency (0.0-1.0)
    case vibration(startPosition: Float, amplitude: Float, frequency: Float)
    
    /// Continuous resistance throughout travel
    case continuous(strength: Float)
    
    /// Compare for equality
    static func == (lhs: AdaptiveTriggerEffect, rhs: AdaptiveTriggerEffect) -> Bool {
        switch (lhs, rhs) {
        case (.off, .off):
            return true
        case let (.feedback(s1, str1), .feedback(s2, str2)):
            return s1 == s2 && str1 == str2
        case let (.weapon(s1, e1, str1), .weapon(s2, e2, str2)):
            return s1 == s2 && e1 == e2 && str1 == str2
        case let (.vibration(s1, a1, f1), .vibration(s2, a2, f2)):
            return s1 == s2 && a1 == a2 && f1 == f2
        case let (.continuous(str1), .continuous(str2)):
            return str1 == str2
        default:
            return false
        }
    }
}

// MARK: - PS5 Feedback Packet Parser

/// Parser for PS5 haptic feedback packets from Remote Play stream
final class PS5HapticFeedbackParser {
    
    // MARK: - Packet Types
    
    /// PS5 feedback packet type identifiers
    private enum PacketType: UInt8 {
        case rumble = 0x05           // Rumble motors
        case adaptiveTriggers = 0x0A // Adaptive trigger effects
        case lightbar = 0x0B         // Lightbar RGB
        case combined = 0x15         // Combined feedback packet
    }
    
    // MARK: - Adaptive Trigger Mode Bytes
    
    private enum TriggerMode: UInt8 {
        case off = 0x00
        case feedback = 0x01
        case weapon = 0x02
        case vibration = 0x03
        case continuous = 0x04
    }
    
    // MARK: - State
    
    /// Last parsed feedback (for change detection)
    private(set) var lastFeedback = PS5HapticFeedback()
    
    /// Callback when feedback changes
    var onFeedbackChanged: ((PS5HapticFeedback) -> Void)?
    
    /// Statistics
    private(set) var packetsProcessed: UInt64 = 0
    private(set) var parseErrors: UInt64 = 0
    
    // MARK: - Public API
    
    /// Parse a feedback packet from the PS5 stream
    /// - Parameter data: Raw packet data
    /// - Returns: Parsed feedback or nil if invalid
    @discardableResult
    func parsePacket(_ data: Data) -> PS5HapticFeedback? {
        guard data.count >= 1 else {
            parseErrors += 1
            return nil
        }
        
        packetsProcessed += 1
        
        let packetType = data[0]
        
        var feedback = PS5HapticFeedback()
        
        switch packetType {
        case PacketType.rumble.rawValue:
            guard parseRumblePacket(data, into: &feedback) else {
                parseErrors += 1
                return nil
            }
            
        case PacketType.adaptiveTriggers.rawValue:
            guard parseAdaptiveTriggersPacket(data, into: &feedback) else {
                parseErrors += 1
                return nil
            }
            
        case PacketType.lightbar.rawValue:
            guard parseLightbarPacket(data, into: &feedback) else {
                parseErrors += 1
                return nil
            }
            
        case PacketType.combined.rawValue:
            guard parseCombinedPacket(data, into: &feedback) else {
                parseErrors += 1
                return nil
            }
            
        default:
            // Unknown packet type - try to parse as combined
            if data.count >= 10 {
                _ = parseCombinedPacket(data, into: &feedback)
            } else {
                return nil
            }
        }
        
        // Notify if feedback changed
        if feedbackChanged(feedback, from: lastFeedback) {
            onFeedbackChanged?(feedback)
        }
        
        lastFeedback = feedback
        return feedback
    }
    
    /// Parse Chiaki/Remote Play style feedback packet
    /// Format used by Chiaki library for PS5 streaming
    func parseChiakiPacket(_ data: Data) -> PS5HapticFeedback? {
        guard data.count >= 8 else { return nil }
        
        var feedback = PS5HapticFeedback()
        
        // Chiaki packet format:
        // [0]: Left motor (0-255)
        // [1]: Right motor (0-255)
        // [2]: L2 trigger mode
        // [3-4]: L2 parameters
        // [5]: R2 trigger mode
        // [6-7]: R2 parameters
        
        feedback.leftMotor = data[0]
        feedback.rightMotor = data[1]
        
        // Parse L2 trigger
        feedback.leftTrigger = parseTriggerEffect(
            mode: data[2],
            param1: data[3],
            param2: data.count > 4 ? data[4] : 0
        )
        
        // Parse R2 trigger
        if data.count >= 8 {
            feedback.rightTrigger = parseTriggerEffect(
                mode: data[5],
                param1: data[6],
                param2: data[7]
            )
        }
        
        // Lightbar if present
        if data.count >= 11 {
            feedback.lightbarRed = data[8]
            feedback.lightbarGreen = data[9]
            feedback.lightbarBlue = data[10]
        }
        
        // Notify
        if feedbackChanged(feedback, from: lastFeedback) {
            onFeedbackChanged?(feedback)
        }
        
        lastFeedback = feedback
        return feedback
    }
    
    // MARK: - Private Parsing Methods
    
    private func parseRumblePacket(_ data: Data, into feedback: inout PS5HapticFeedback) -> Bool {
        guard data.count >= 3 else { return false }
        
        feedback.leftMotor = data[1]
        feedback.rightMotor = data[2]
        
        return true
    }
    
    private func parseAdaptiveTriggersPacket(_ data: Data, into feedback: inout PS5HapticFeedback) -> Bool {
        guard data.count >= 7 else { return false }
        
        // L2: bytes 1-3
        feedback.leftTrigger = parseTriggerEffect(
            mode: data[1],
            param1: data[2],
            param2: data[3]
        )
        
        // R2: bytes 4-6
        feedback.rightTrigger = parseTriggerEffect(
            mode: data[4],
            param1: data[5],
            param2: data[6]
        )
        
        return true
    }
    
    private func parseLightbarPacket(_ data: Data, into feedback: inout PS5HapticFeedback) -> Bool {
        guard data.count >= 4 else { return false }
        
        feedback.lightbarRed = data[1]
        feedback.lightbarGreen = data[2]
        feedback.lightbarBlue = data[3]
        
        return true
    }
    
    private func parseCombinedPacket(_ data: Data, into feedback: inout PS5HapticFeedback) -> Bool {
        guard data.count >= 10 else { return false }
        
        // Combined format:
        // [0]: Packet type
        // [1]: Left motor
        // [2]: Right motor
        // [3]: L2 mode
        // [4]: L2 param
        // [5]: R2 mode
        // [6]: R2 param
        // [7-9]: Lightbar RGB
        
        feedback.leftMotor = data[1]
        feedback.rightMotor = data[2]
        
        feedback.leftTrigger = parseTriggerEffect(
            mode: data[3],
            param1: data[4],
            param2: 0
        )
        
        feedback.rightTrigger = parseTriggerEffect(
            mode: data[5],
            param1: data[6],
            param2: 0
        )
        
        feedback.lightbarRed = data[7]
        feedback.lightbarGreen = data[8]
        feedback.lightbarBlue = data[9]
        
        return true
    }
    
    private func parseTriggerEffect(mode: UInt8, param1: UInt8, param2: UInt8) -> AdaptiveTriggerEffect {
        let startPosition = Float(param1) / 255.0
        let strength = Float(param2) / 255.0
        
        switch mode {
        case TriggerMode.off.rawValue:
            return .off
            
        case TriggerMode.feedback.rawValue:
            return .feedback(startPosition: startPosition, strength: max(0.3, strength))
            
        case TriggerMode.weapon.rawValue:
            // Weapon mode uses param1 as start, param2 as end
            let endPosition = Float(param2) / 255.0
            return .weapon(startPosition: startPosition, endPosition: endPosition, strength: 0.5)
            
        case TriggerMode.vibration.rawValue:
            return .vibration(startPosition: startPosition, amplitude: strength, frequency: 0.5)
            
        case TriggerMode.continuous.rawValue:
            return .continuous(strength: startPosition)
            
        default:
            return .off
        }
    }
    
    // MARK: - Change Detection
    
    private func feedbackChanged(_ new: PS5HapticFeedback, from old: PS5HapticFeedback) -> Bool {
        if new.leftMotor != old.leftMotor { return true }
        if new.rightMotor != old.rightMotor { return true }
        if new.leftTrigger != old.leftTrigger { return true }
        if new.rightTrigger != old.rightTrigger { return true }
        if new.lightbarRed != old.lightbarRed { return true }
        if new.lightbarGreen != old.lightbarGreen { return true }
        if new.lightbarBlue != old.lightbarBlue { return true }
        return false
    }
    
    // MARK: - Statistics
    
    var statisticsDescription: String {
        return "[HapticParser] packets: \(packetsProcessed), errors: \(parseErrors)"
    }
}
