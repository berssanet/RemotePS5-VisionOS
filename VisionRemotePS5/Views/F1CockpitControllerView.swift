//
//  F1CockpitControllerView.swift
//  VisionRemotePS5
//
//  v10.6: F1 Cockpit style controller with rotating steering wheel
//  Designed for racing games on PS5
//

import SwiftUI

struct F1CockpitControllerView: View {
    @ObservedObject var viewModel: StreamingViewModel
    
    // Steering wheel state
    @State private var steeringAngle: Double = 0  // -135 to 135 degrees (270° total)
    @State private var isDragging = false
    
    // Trigger states (0.0 to 1.0)
    @State private var l2Value: Double = 0
    @State private var r2Value: Double = 0
    
    private let maxSteeringAngle: Double = 135  // ±135° = 270° total
    
    var body: some View {
        VStack(spacing: 12) {
            // Top row: L2/R2 triggers and bumpers
            HStack(spacing: 20) {
                // Left side: L1/L2
                VStack(spacing: 8) {
                    // L1 (bumper)
                    TriggerButtonView(label: "L1", isPressed: false) {
                        viewModel.sendButtonPress(.l1)
                    } onRelease: {
                        viewModel.sendButtonRelease(.l1)
                    }
                    
                    // L2 (brake) - drag-sensitive
                    TriggerSliderView(label: "L2", value: $l2Value, color: .red) { value in
                        // L2 is brake - send as trigger
                        sendTriggerInput(l2: value, r2: r2Value)
                    }
                }
                
                Spacer()
                
                // Center: Steering wheel
                SteeringWheelView(angle: $steeringAngle, isDragging: $isDragging, maxAngle: maxSteeringAngle) { normalizedValue in
                    // Send steering input: -1.0 (left) to 1.0 (right)
                    viewModel.sendJoystickInput(
                        left: CGPoint(x: normalizedValue, y: 0),
                        right: .zero
                    )
                }
                .frame(width: 180, height: 180)
                
                Spacer()
                
                // Right side: R1/R2
                VStack(spacing: 8) {
                    // R1 (bumper)
                    TriggerButtonView(label: "R1", isPressed: false) {
                        viewModel.sendButtonPress(.r1)
                    } onRelease: {
                        viewModel.sendButtonRelease(.r1)
                    }
                    
                    // R2 (accelerator) - drag-sensitive
                    TriggerSliderView(label: "R2", value: $r2Value, color: .green) { value in
                        // R2 is accelerator
                        sendTriggerInput(l2: l2Value, r2: value)
                    }
                }
            }
            .padding(.horizontal, 16)
            
            // Bottom row: Face buttons and system buttons
            HStack(spacing: 16) {
                // Left: Share/Options/PS
                HStack(spacing: 12) {
                    SmallButtonView(symbol: "square.and.arrow.up") {
                        viewModel.sendButtonPress(.share)
                    } onRelease: {
                        viewModel.sendButtonRelease(.share)
                    }
                    
                    SmallButtonView(symbol: "playstation.logo") {
                        viewModel.sendButtonPress(.ps)
                    } onRelease: {
                        viewModel.sendButtonRelease(.ps)
                    }
                    
                    SmallButtonView(symbol: "line.3.horizontal") {
                        viewModel.sendButtonPress(.options)
                    } onRelease: {
                        viewModel.sendButtonRelease(.options)
                    }
                }
                
                Spacer()
                
                // Right: Face buttons diamond layout
                HStack(spacing: 8) {
                    // Triangle
                    SmallButtonView(symbol: "triangle", color: .green) {
                        viewModel.sendButtonPress(.triangle)
                    } onRelease: {
                        viewModel.sendButtonRelease(.triangle)
                    }
                    
                    // Square
                    SmallButtonView(symbol: "square", color: .pink) {
                        viewModel.sendButtonPress(.square)
                    } onRelease: {
                        viewModel.sendButtonRelease(.square)
                    }
                    
                    // Circle
                    SmallButtonView(symbol: "circle", color: .red) {
                        viewModel.sendButtonPress(.circle)
                    } onRelease: {
                        viewModel.sendButtonRelease(.circle)
                    }
                    
                    // Cross
                    SmallButtonView(symbol: "xmark", color: .blue) {
                        viewModel.sendButtonPress(.cross)
                    } onRelease: {
                        viewModel.sendButtonRelease(.cross)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }
    
    private func sendTriggerInput(l2: Double, r2: Double) {
        // L2/R2 are sent as analog triggers
        // Using right stick Y for gas/brake simulation:
        // R2 (accelerator) pushes Y positive, L2 (brake) pushes Y negative
        let throttleBrake = r2 - l2  // -1.0 (full brake) to 1.0 (full throttle)
        
        viewModel.sendJoystickInput(
            left: CGPoint(x: steeringAngle / maxSteeringAngle, y: 0),
            right: CGPoint(x: 0, y: throttleBrake)
        )
    }
}

// MARK: - Steering Wheel View

struct SteeringWheelView: View {
    @Binding var angle: Double
    @Binding var isDragging: Bool
    let maxAngle: Double
    let onSteeringChange: (Double) -> Void
    
    @State private var startAngle: Double = 0
    
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) / 2
            
            ZStack {
                // Outer ring (wheel rim)
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.gray.opacity(0.8), .gray.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 12
                    )
                    .frame(width: radius * 2 - 20, height: radius * 2 - 20)
                
                // Inner circle (center cap)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.gray.opacity(0.6), .gray.opacity(0.3)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .frame(width: 80, height: 80)
                    .overlay(
                        // F1 logo or indicator
                        Text("F1")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                    )
                
                // Top marker (position indicator)
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 16, height: 16)
                    .offset(y: -(radius - 16))
                
                // Spokes
                ForEach([0, 120, 240], id: \.self) { spokeAngle in
                    Rectangle()
                        .fill(Color.gray.opacity(0.5))
                        .frame(width: 6, height: radius - 50)
                        .offset(y: -(radius - 50) / 2 - 40)
                        .rotationEffect(.degrees(Double(spokeAngle)))
                }
            }
            .rotationEffect(.degrees(angle))
            .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.7), value: angle)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let location = value.location
                        let currentAngle = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
                        
                        if !isDragging {
                            isDragging = true
                            startAngle = currentAngle - angle
                        }
                        
                        var newAngle = currentAngle - startAngle
                        
                        // Clamp to max steering angle
                        newAngle = max(-maxAngle, min(maxAngle, newAngle))
                        angle = newAngle
                        
                        // Normalize to -1.0 to 1.0
                        let normalized = angle / maxAngle
                        onSteeringChange(normalized)
                    }
                    .onEnded { _ in
                        isDragging = false
                        // Optional: return to center when released
                        // withAnimation(.spring()) { angle = 0 }
                        // onSteeringChange(0)
                    }
            )
        }
    }
}

// MARK: - Trigger Slider View

struct TriggerSliderView: View {
    let label: String
    @Binding var value: Double
    var color: Color = .white
    let onChange: (Double) -> Void
    
    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(color)
            
            ZStack(alignment: .bottom) {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 40, height: 60)
                
                // Fill
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.6))
                    .frame(width: 40, height: CGFloat(value) * 60)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let newValue = 1.0 - min(1, max(0, gesture.location.y / 60))
                        value = newValue
                        onChange(newValue)
                    }
                    .onEnded { _ in
                        // Return to zero when released
                        withAnimation(.easeOut(duration: 0.2)) {
                            value = 0
                        }
                        onChange(0)
                    }
            )
        }
    }
}

// MARK: - Trigger Button View

struct TriggerButtonView: View {
    let label: String
    var isPressed: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var pressing = false
    
    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 50, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(pressing ? Color.white.opacity(0.4) : Color.white.opacity(0.15))
            )
            .scaleEffect(pressing ? 0.95 : 1.0)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { isPressing in
                pressing = isPressing
                if isPressing {
                    onPress()
                } else {
                    onRelease()
                }
            }, perform: {})
    }
}

// MARK: - Small Button View

struct SmallButtonView: View {
    let symbol: String
    var color: Color = .white
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundColor(isPressed ? color.opacity(0.5) : color)
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(isPressed ? Color.white.opacity(0.3) : Color.white.opacity(0.1))
            )
            .overlay(
                Circle()
                    .stroke(color.opacity(0.4), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.9 : 1.0)
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
                if pressing {
                    onPress()
                } else {
                    onRelease()
                }
            }, perform: {})
    }
}
