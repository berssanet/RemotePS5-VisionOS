//
//  F1SteeringWheel3DModel.swift
//  VisionRemotePS5
//
//  v10.6.2: Realistic Ferrari F1 steering wheel based on Thrustmaster reference
//  Creates a detailed F1 wheel with proper shape, grips, paddles, LCD, and buttons
//

import RealityKit
import SwiftUI
import simd

/// Creates a realistic Ferrari F1 steering wheel 3D model
@MainActor
final class F1SteeringWheel3DModel {
    
    // MARK: - Dimensions (in meters)
    
    private let wheelWidth: Float = 0.28       // 28cm total width
    private let wheelHeight: Float = 0.18      // 18cm body height
    private let wheelDepth: Float = 0.04       // 4cm depth
    
    // MARK: - Materials
    
    private var carbonFiberMaterial: PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0))
        mat.roughness = .init(floatLiteral: 0.2)
        mat.metallic = .init(floatLiteral: 0.1)
        return mat
    }
    
    private var rubberGripMaterial: PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 0.03, green: 0.03, blue: 0.03, alpha: 1.0))
        mat.roughness = .init(floatLiteral: 0.95)
        mat.metallic = .init(floatLiteral: 0.0)
        return mat
    }
    
    private var metalPaddleMaterial: PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 0.7, green: 0.72, blue: 0.75, alpha: 1.0))
        mat.roughness = .init(floatLiteral: 0.15)
        mat.metallic = .init(floatLiteral: 0.9)
        return mat
    }
    
    private var lcdDisplayMaterial: PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 0.0, green: 0.1, blue: 0.15, alpha: 1.0))
        mat.roughness = .init(floatLiteral: 0.05)
        mat.emissiveColor = .init(color: UIColor(red: 0.0, green: 0.4, blue: 0.6, alpha: 1.0))
        mat.emissiveIntensity = 0.8
        return mat
    }
    
    private var ferrariYellowMaterial: PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: UIColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0))
        mat.roughness = .init(floatLiteral: 0.3)
        mat.metallic = .init(floatLiteral: 0.1)
        return mat
    }
    
    private func buttonMaterial(color: UIColor) -> PhysicallyBasedMaterial {
        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: color)
        mat.roughness = .init(floatLiteral: 0.4)
        mat.metallic = .init(floatLiteral: 0.2)
        return mat
    }
    
    // MARK: - Create Wheel Entity
    
    func createWheelEntity() -> Entity {
        let wheelRoot = Entity()
        wheelRoot.name = "F1SteeringWheel"
        
        print("[F1Wheel] Creating 3D steering wheel...")
        
        // 1. MAIN BODY - Carbon fiber rectangular plate
        let mainBody = createMainBody()
        wheelRoot.addChild(mainBody)
        
        // 2. LEFT GRIP - Ergonomic handle with rubber texture
        let leftGrip = createGrip(isLeft: true)
        wheelRoot.addChild(leftGrip)
        
        // 3. RIGHT GRIP - Ergonomic handle
        let rightGrip = createGrip(isLeft: false)
        wheelRoot.addChild(rightGrip)
        
        // 4. LCD DISPLAY - Top center screen
        let display = createLCDDisplay()
        wheelRoot.addChild(display)
        
        // 5. LEFT PADDLE (Clutch/Downshift)
        let leftPaddle = createPaddle(isLeft: true)
        wheelRoot.addChild(leftPaddle)
        
        // 6. RIGHT PADDLE (Clutch/Upshift)
        let rightPaddle = createPaddle(isLeft: false)
        wheelRoot.addChild(rightPaddle)
        
        // 7. FERRARI LOGO - Yellow circle center
        let logo = createFerrariLogo()
        wheelRoot.addChild(logo)
        
        // 8. TOP BUTTONS - N, P, +10, DRINK etc
        addTopButtons(to: wheelRoot)
        
        // 9. CENTER BUTTONS - Colorful F1 buttons (RACE, BOX, FOR, SC, etc)
        addCenterButtons(to: wheelRoot)
        
        // 10. ROTARY DIALS
        addRotaryDials(to: wheelRoot)
        
        // 11. RPM INDICATOR LIGHTS
        addRPMLights(to: wheelRoot)
        
        print("[F1Wheel] ✅ Wheel created with \(wheelRoot.children.count) components")
        
        return wheelRoot
    }
    
    // MARK: - Component Creation
    
    private func createMainBody() -> ModelEntity {
        // Main rectangular carbon fiber body
        let bodyMesh = MeshResource.generateBox(
            width: wheelWidth,
            height: wheelHeight,
            depth: wheelDepth,
            cornerRadius: 0.012
        )
        let body = ModelEntity(mesh: bodyMesh, materials: [carbonFiberMaterial])
        body.name = "MainBody"
        return body
    }
    
    private func createGrip(isLeft: Bool) -> Entity {
        let gripRoot = Entity()
        gripRoot.name = isLeft ? "LeftGrip" : "RightGrip"
        
        // Main grip cylinder (vertical)
        let gripMesh = MeshResource.generateCylinder(height: 0.11, radius: 0.025)
        let grip = ModelEntity(mesh: gripMesh, materials: [rubberGripMaterial])
        gripRoot.addChild(grip)
        
        // Top cap
        let capMesh = MeshResource.generateSphere(radius: 0.025)
        let topCap = ModelEntity(mesh: capMesh, materials: [rubberGripMaterial])
        topCap.position = [0, 0.055, 0]
        gripRoot.addChild(topCap)
        
        // Bottom cap
        let bottomCap = ModelEntity(mesh: capMesh, materials: [rubberGripMaterial])
        bottomCap.position = [0, -0.055, 0]
        gripRoot.addChild(bottomCap)
        
        // Position grip
        let xOffset: Float = isLeft ? -0.15 : 0.15
        gripRoot.position = [xOffset, -0.02, 0]
        
        return gripRoot
    }
    
    private func createLCDDisplay() -> ModelEntity {
        // LCD screen at top center
        let displayMesh = MeshResource.generateBox(
            width: 0.08,
            height: 0.035,
            depth: 0.006,
            cornerRadius: 0.003
        )
        let display = ModelEntity(mesh: displayMesh, materials: [lcdDisplayMaterial])
        display.name = "LCDDisplay"
        display.position = [0, 0.05, wheelDepth / 2 + 0.004]
        return display
    }
    
    private func createPaddle(isLeft: Bool) -> ModelEntity {
        // Large metal paddle behind grips
        let paddleMesh = MeshResource.generateBox(
            width: 0.055,
            height: 0.08,
            depth: 0.005,
            cornerRadius: 0.003
        )
        let paddle = ModelEntity(mesh: paddleMesh, materials: [metalPaddleMaterial])
        paddle.name = isLeft ? "LeftPaddle_L2" : "RightPaddle_R2"
        
        let xOffset: Float = isLeft ? -0.11 : 0.11
        paddle.position = [xOffset, 0.02, -wheelDepth / 2 - 0.015]
        
        // Angle paddle slightly
        let angle: Float = isLeft ? 0.2 : -0.2
        paddle.orientation = simd_quatf(angle: angle, axis: [1, 0, 0])
        
        return paddle
    }
    
    private func createFerrariLogo() -> ModelEntity {
        // Yellow Ferrari circle at center
        let logoMesh = MeshResource.generateCylinder(height: 0.006, radius: 0.022)
        let logo = ModelEntity(mesh: logoMesh, materials: [ferrariYellowMaterial])
        logo.name = "FerrariLogo"
        logo.position = [0, 0, wheelDepth / 2 + 0.004]
        logo.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        return logo
    }
    
    private func addTopButtons(to parent: Entity) {
        // N button (Green, top left)
        let nButton = createButton(color: .systemGreen, label: "N")
        nButton.position = [-0.10, 0.065, wheelDepth / 2 + 0.01]
        parent.addChild(nButton)
        
        // P button (Orange, top right)
        let pButton = createButton(color: .systemOrange, label: "P")
        pButton.position = [0.10, 0.065, wheelDepth / 2 + 0.01]
        parent.addChild(pButton)
        
        // DRINK button (Red, left of N)
        let drinkButton = createButton(color: .systemRed, label: "DRINK", radius: 0.008)
        drinkButton.position = [-0.08, 0.055, wheelDepth / 2 + 0.01]
        parent.addChild(drinkButton)
        
        // +10 button (Yellow, right of P)
        let plus10Button = createButton(color: .systemYellow, label: "+10", radius: 0.008)
        plus10Button.position = [0.08, 0.055, wheelDepth / 2 + 0.01]
        parent.addChild(plus10Button)
    }
    
    private func addCenterButtons(to parent: Entity) {
        // Row of colorful buttons below display
        let buttonColors: [(UIColor, Float)] = [
            (.systemRed, -0.05),      // K1 / FOR
            (.systemBlue, -0.025),    // SC
            (.systemCyan, 0),         // CENTER
            (.systemPurple, 0.025),   // PSH
            (.systemGreen, 0.05)      // OIL / K2
        ]
        
        for (color, xPos) in buttonColors {
            let button = createButton(color: color, label: "", radius: 0.009)
            button.position = [xPos, 0.01, wheelDepth / 2 + 0.015]
            parent.addChild(button)
        }
        
        // Second row
        let row2Colors: [(UIColor, Float)] = [
            (.systemYellow, -0.04),
            (.systemOrange, 0),
            (.systemPink, 0.04)
        ]
        
        for (color, xPos) in row2Colors {
            let button = createButton(color: color, label: "", radius: 0.008)
            button.position = [xPos, -0.015, wheelDepth / 2 + 0.015]
            parent.addChild(button)
        }
    }
    
    private func addRotaryDials(to parent: Entity) {
        // Left rotary dial
        let leftDial = createRotaryDial()
        leftDial.position = [-0.075, -0.045, wheelDepth / 2 + 0.008]
        parent.addChild(leftDial)
        
        // Right rotary dial
        let rightDial = createRotaryDial()
        rightDial.position = [0.075, -0.045, wheelDepth / 2 + 0.008]
        parent.addChild(rightDial)
        
        // Bottom center dials (smaller)
        let bottomLeft = createRotaryDial(radius: 0.012)
        bottomLeft.position = [-0.035, -0.055, wheelDepth / 2 + 0.008]
        parent.addChild(bottomLeft)
        
        let bottomRight = createRotaryDial(radius: 0.012)
        bottomRight.position = [0.035, -0.055, wheelDepth / 2 + 0.008]
        parent.addChild(bottomRight)
    }
    
    private func addRPMLights(to parent: Entity) {
        // Row of RPM indicator LEDs at top
        let lightPositions: [Float] = [-0.05, -0.035, -0.02, -0.005, 0.005, 0.02, 0.035, 0.05]
        let colors: [UIColor] = [
            .systemGreen, .systemGreen, .systemGreen,
            .systemYellow, .systemYellow,
            .systemRed, .systemRed, .systemRed
        ]
        
        for (index, xPos) in lightPositions.enumerated() {
            let lightMesh = MeshResource.generateSphere(radius: 0.005)
            var mat = PhysicallyBasedMaterial()
            mat.baseColor = .init(tint: colors[index])
            mat.emissiveColor = .init(color: colors[index])
            mat.emissiveIntensity = 0.5
            
            let light = ModelEntity(mesh: lightMesh, materials: [mat])
            light.position = [xPos, wheelHeight / 2 - 0.008, wheelDepth / 2 + 0.01]
            parent.addChild(light)
        }
    }
    
    // MARK: - Helper Methods
    
    private func createButton(color: UIColor, label: String, radius: Float = 0.012) -> ModelEntity {
        let buttonMesh = MeshResource.generateCylinder(height: 0.008, radius: radius)
        let button = ModelEntity(mesh: buttonMesh, materials: [buttonMaterial(color: color)])
        button.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        return button
    }
    
    private func createRotaryDial(radius: Float = 0.018) -> Entity {
        let dialRoot = Entity()
        
        // Base cylinder
        let baseMesh = MeshResource.generateCylinder(height: 0.012, radius: radius)
        var baseMat = PhysicallyBasedMaterial()
        baseMat.baseColor = .init(tint: UIColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1.0))
        baseMat.roughness = .init(floatLiteral: 0.3)
        baseMat.metallic = .init(floatLiteral: 0.5)
        
        let base = ModelEntity(mesh: baseMesh, materials: [baseMat])
        base.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        dialRoot.addChild(base)
        
        // Colored ring on dial
        let ringMesh = MeshResource.generateCylinder(height: 0.003, radius: radius - 0.003)
        var ringMat = PhysicallyBasedMaterial()
        ringMat.baseColor = .init(tint: .systemGreen)
        ringMat.roughness = .init(floatLiteral: 0.4)
        
        let ring = ModelEntity(mesh: ringMesh, materials: [ringMat])
        ring.position = [0, 0, 0.007]
        ring.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        dialRoot.addChild(ring)
        
        return dialRoot
    }
}
