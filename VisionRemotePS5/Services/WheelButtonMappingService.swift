//
//  WheelButtonMappingService.swift
//  VisionRemotePS5
//
//  Service for managing F1 wheel button mappings
//  Allows users to customize which wheel buttons map to which controller actions
//

import SwiftUI
import Combine

// MARK: - PS5 Controller Actions

enum PS5ControllerAction: String, Codable, CaseIterable {
    // Triggers & Bumpers
    case r2 = "R2"
    case l2 = "L2"
    case r1 = "R1"
    case l1 = "L1"
    
    // Face buttons
    case cross = "X"
    case circle = "○"
    case triangle = "△"
    case square = "□"
    
    // D-Pad
    case dpadUp = "D-Up"
    case dpadDown = "D-Down"
    case dpadLeft = "D-Left"
    case dpadRight = "D-Right"
    
    // System
    case options = "Options"
    case share = "Share"
    case ps = "PS"
    case touchpad = "Touchpad"
    
    // Sticks
    case l3 = "L3"
    case r3 = "R3"
    
    // None
    case none = "None"
    
    var displayName: String {
        switch self {
        case .r2: return "R2 (Acelerador)"
        case .l2: return "L2 (Freio)"
        case .r1: return "R1"
        case .l1: return "L1"
        case .cross: return "✕ (X)"
        case .circle: return "○ (Circle)"
        case .triangle: return "△ (Triangle)"
        case .square: return "□ (Square)"
        case .dpadUp: return "D-Pad ↑"
        case .dpadDown: return "D-Pad ↓"
        case .dpadLeft: return "D-Pad ←"
        case .dpadRight: return "D-Pad →"
        case .options: return "Options"
        case .share: return "Share"
        case .ps: return "PS Button"
        case .touchpad: return "Touchpad"
        case .l3: return "L3 (Stick Press)"
        case .r3: return "R3 (Stick Press)"
        case .none: return "Não mapeado"
        }
    }
    
    var icon: String {
        switch self {
        case .r2, .l2: return "arrow.up.circle.fill"
        case .r1, .l1: return "arrow.up.circle"
        case .cross: return "xmark.circle"
        case .circle: return "circle"
        case .triangle: return "triangle"
        case .square: return "square"
        case .dpadUp: return "chevron.up"
        case .dpadDown: return "chevron.down"
        case .dpadLeft: return "chevron.left"
        case .dpadRight: return "chevron.right"
        case .options: return "line.3.horizontal"
        case .share: return "square.and.arrow.up"
        case .ps: return "playstation.logo"
        case .touchpad: return "hand.tap"
        case .l3, .r3: return "l.joystick.press.down"
        case .none: return "nosign"
        }
    }
}

// MARK: - Wheel Button Definition

enum WheelButtonID: String, Codable, CaseIterable {
    // Paddles (back of wheel)
    case paddleLeftTop = "paddle_left_top"      // Left upper paddle
    case paddleLeftBottom = "paddle_left_bottom" // Left lower paddle
    case paddleRightTop = "paddle_right_top"    // Right upper paddle
    case paddleRightBottom = "paddle_right_bottom" // Right lower paddle
    
    // Top rotary/buttons
    case rotaryLeft = "rotary_left"
    case rotaryRight = "rotary_right"
    
    // Center display buttons
    case buttonTopLeft = "button_top_left"
    case buttonTopRight = "button_top_right"
    case buttonMidLeft = "button_mid_left"
    case buttonMidRight = "button_mid_right"
    case buttonBottomLeft = "button_bottom_left"
    case buttonBottomRight = "button_bottom_right"
    
    // Thumb buttons (on grips)
    case thumbLeft = "thumb_left"
    case thumbRight = "thumb_right"
    
    var displayName: String {
        switch self {
        case .paddleLeftTop: return "Paddle Esq. Superior"
        case .paddleLeftBottom: return "Paddle Esq. Inferior"
        case .paddleRightTop: return "Paddle Dir. Superior"
        case .paddleRightBottom: return "Paddle Dir. Inferior"
        case .rotaryLeft: return "Rotativo Esquerdo"
        case .rotaryRight: return "Rotativo Direito"
        case .buttonTopLeft: return "Botão Topo Esq."
        case .buttonTopRight: return "Botão Topo Dir."
        case .buttonMidLeft: return "Botão Meio Esq."
        case .buttonMidRight: return "Botão Meio Dir."
        case .buttonBottomLeft: return "Botão Baixo Esq."
        case .buttonBottomRight: return "Botão Baixo Dir."
        case .thumbLeft: return "Polegar Esquerdo"
        case .thumbRight: return "Polegar Direito"
        }
    }
    
    var defaultAction: PS5ControllerAction {
        switch self {
        case .paddleLeftTop: return .l2        // Brake
        case .paddleLeftBottom: return .l1     // Clutch/Downshift
        case .paddleRightTop: return .r2       // Throttle
        case .paddleRightBottom: return .r1    // Upshift
        case .rotaryLeft: return .dpadLeft
        case .rotaryRight: return .dpadRight
        case .buttonTopLeft: return .triangle
        case .buttonTopRight: return .circle
        case .buttonMidLeft: return .square
        case .buttonMidRight: return .cross
        case .buttonBottomLeft: return .options
        case .buttonBottomRight: return .share
        case .thumbLeft: return .l3
        case .thumbRight: return .r3
        }
    }
    
    var position: SIMD3<Float> {
        // Positions relative to wheel center (in meters)
        // IMPORTANT: The USDZ model has -90° X rotation applied, so LOCAL coordinates are:
        // X = left(-)/right(+)  - horizontal
        // Y = depth: negative = towards user (front of wheel), positive = away (back)
        // Z = vertical: positive = UP, negative = DOWN
        //
        // The wheel is ~28cm wide. Hotspots must be positioned ON the visible wheel face.
        // Based on testing: Z needs to be around 0.08-0.15 to be on the wheel body
        switch self {
        // Paddles: Behind the wheel grips (positive Y = back, away from user)
        case .paddleLeftTop: return [-0.12, 0.02, 0.12]      // Left grip, upper paddle
        case .paddleLeftBottom: return [-0.12, 0.02, 0.08]   // Left grip, lower paddle  
        case .paddleRightTop: return [0.12, 0.02, 0.12]      // Right grip, upper paddle
        case .paddleRightBottom: return [0.12, 0.02, 0.08]   // Right grip, lower paddle
        
        // Rotary encoders: Top corners of wheel face (towards user)
        case .rotaryLeft: return [-0.08, -0.02, 0.16]        // Top left corner
        case .rotaryRight: return [0.08, -0.02, 0.16]        // Top right corner
        
        // Center buttons (on display area): Arranged in 3 rows, on front face
        case .buttonTopLeft: return [-0.03, -0.02, 0.14]     // Row 1: Top
        case .buttonTopRight: return [0.03, -0.02, 0.14]
        case .buttonMidLeft: return [-0.03, -0.02, 0.10]     // Row 2: Middle  
        case .buttonMidRight: return [0.03, -0.02, 0.10]
        case .buttonBottomLeft: return [-0.03, -0.02, 0.06]  // Row 3: Bottom
        case .buttonBottomRight: return [0.03, -0.02, 0.06]
        
        // Thumb buttons: On the grip handles, lower position
        case .thumbLeft: return [-0.12, -0.01, 0.04]         // Left grip, thumb area
        case .thumbRight: return [0.12, -0.01, 0.04]         // Right grip, thumb area
        }
    }
    
    var hotspotSize: SIMD3<Float> {
        // Size of the touch area (in meters) - larger for easier targeting
        switch self {
        case .paddleLeftTop, .paddleLeftBottom, .paddleRightTop, .paddleRightBottom:
            return [0.05, 0.04, 0.03]  // Large paddles: 5cm x 4cm
        case .rotaryLeft, .rotaryRight:
            return [0.04, 0.04, 0.03]  // Medium rotaries: 4cm x 4cm
        default:
            return [0.03, 0.03, 0.025]  // Buttons: 3cm x 3cm
        }
    }
}

// MARK: - Button Mapping Configuration

struct WheelButtonMapping: Codable, Identifiable {
    var id: String { buttonId.rawValue }
    var buttonId: WheelButtonID
    var action: PS5ControllerAction
    
    static func defaultMappings() -> [WheelButtonMapping] {
        WheelButtonID.allCases.map { buttonId in
            WheelButtonMapping(buttonId: buttonId, action: buttonId.defaultAction)
        }
    }
}

// MARK: - Wheel Button Mapping Service

@MainActor
class WheelButtonMappingService: ObservableObject {
    static let shared = WheelButtonMappingService()
    
    // MARK: - Published Properties
    
    @Published var mappings: [WheelButtonMapping] = []
    @Published var isConfigured: Bool = false
    @Published var isConfiguring: Bool = false
    @Published var currentlyEditingButton: WheelButtonID?
    @Published var showConfigurationOverlay: Bool = false
    
    // MARK: - Active Button States
    
    @Published var activeButtons: Set<WheelButtonID> = []
    
    // MARK: - Private
    
    private let userDefaultsKey = "WheelButtonMappings"
    private let configuredKey = "WheelButtonsConfigured"
    
    // MARK: - Initialization
    
    private init() {
        loadConfiguration()
    }
    
    // MARK: - Configuration Management
    
    func loadConfiguration() {
        isConfigured = UserDefaults.standard.bool(forKey: configuredKey)
        
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([WheelButtonMapping].self, from: data) {
            mappings = saved
            print("[WheelButtonMapping] ✅ Loaded \(mappings.count) button mappings")
        } else {
            // Use defaults
            mappings = WheelButtonMapping.defaultMappings()
            print("[WheelButtonMapping] 📝 Using default mappings")
        }
    }
    
    func saveConfiguration() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            UserDefaults.standard.set(true, forKey: configuredKey)
            isConfigured = true
            isConfiguring = false
            showConfigurationOverlay = false
            print("[WheelButtonMapping] 💾 Saved \(mappings.count) button mappings")
        }
    }
    
    func resetToDefaults() {
        mappings = WheelButtonMapping.defaultMappings()
        print("[WheelButtonMapping] 🔄 Reset to default mappings")
    }
    
    func startConfiguration() {
        isConfiguring = true
        showConfigurationOverlay = true
        print("[WheelButtonMapping] ⚙️ Starting button configuration")
    }
    
    func cancelConfiguration() {
        loadConfiguration()  // Reload saved config
        isConfiguring = false
        showConfigurationOverlay = false
        currentlyEditingButton = nil
    }
    
    // MARK: - Mapping Operations
    
    func getAction(for buttonId: WheelButtonID) -> PS5ControllerAction {
        mappings.first { $0.buttonId == buttonId }?.action ?? buttonId.defaultAction
    }
    
    func setAction(_ action: PS5ControllerAction, for buttonId: WheelButtonID) {
        if let index = mappings.firstIndex(where: { $0.buttonId == buttonId }) {
            mappings[index].action = action
        } else {
            mappings.append(WheelButtonMapping(buttonId: buttonId, action: action))
        }
        print("[WheelButtonMapping] 🔧 Mapped \(buttonId.displayName) → \(action.displayName)")
    }
    
    // MARK: - Button Press Handling
    
    func buttonPressed(_ buttonId: WheelButtonID) {
        activeButtons.insert(buttonId)
        let action = getAction(for: buttonId)
        print("[WheelButtonMapping] 🔘 Button pressed: \(buttonId.displayName) → \(action.displayName)")
        
        // If in configuration mode, select this button for editing
        if isConfiguring {
            currentlyEditingButton = buttonId
        }
    }
    
    func buttonReleased(_ buttonId: WheelButtonID) {
        activeButtons.remove(buttonId)
        print("[WheelButtonMapping] ⚪ Button released: \(buttonId.displayName)")
    }
    
    func isButtonActive(_ buttonId: WheelButtonID) -> Bool {
        activeButtons.contains(buttonId)
    }
}
