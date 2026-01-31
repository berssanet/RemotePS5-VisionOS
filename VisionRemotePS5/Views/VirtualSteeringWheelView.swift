//
//  VirtualSteeringWheelView.swift
//  VisionRemotePS5
//
//  v10.6: 3D Virtual steering wheel overlay for hand tracking mode
//  Shows a visual wheel between the user's hands in VR
//

import SwiftUI
import RealityKit

/// 3D overlay showing virtual steering wheel between user's hands
struct VirtualSteeringWheelView: View {
    @ObservedObject var steeringService: VirtualSteeringWheelService
    @ObservedObject var viewModel: StreamingViewModel
    
    /// Timer for sending input updates
    @State private var inputTimer: Timer?
    
    var body: some View {
        ZStack {
            // Status overlay at top
            VStack {
                // Hand tracking status
                HStack(spacing: 20) {
                    // Left hand indicator
                    HandIndicator(
                        isTracked: steeringService.leftHandPosition != nil,
                        label: "L",
                        triggerValue: steeringService.leftTrigger,
                        color: .red
                    )
                    
                    // Steering indicator
                    SteeringIndicator(value: steeringService.steeringValue)
                    
                    // Right hand indicator
                    HandIndicator(
                        isTracked: steeringService.rightHandPosition != nil,
                        label: "R",
                        triggerValue: steeringService.rightTrigger,
                        color: .green
                    )
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
                
                Spacer()
                
                // Instructions when not tracking
                if !steeringService.isTracking {
                    VStack(spacing: 12) {
                        Image(systemName: "hand.raised.fingers.spread")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                        
                        Text("Hold your hands like a steering wheel")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("Rotate to steer • Pinch to accelerate/brake")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
                
                Spacer()
            }
        }
        .onAppear {
            startInputLoop()
        }
        .onDisappear {
            stopInputLoop()
        }
    }
    
    // MARK: - Input Loop
    
    private func startInputLoop() {
        // Send input at 60Hz
        inputTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
            sendInput()
        }
    }
    
    private func stopInputLoop() {
        inputTimer?.invalidate()
        inputTimer = nil
    }
    
    private func sendInput() {
        // Send steering as left stick X
        // Send triggers as throttle/brake via right stick Y
        let steering = CGFloat(steeringService.steeringValue)
        let throttleBrake = CGFloat(steeringService.rightTrigger - steeringService.leftTrigger)
        
        viewModel.sendJoystickInput(
            left: CGPoint(x: steering, y: 0),
            right: CGPoint(x: 0, y: throttleBrake)
        )
    }
}

// MARK: - Hand Indicator

struct HandIndicator: View {
    let isTracked: Bool
    let label: String
    let triggerValue: Float
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            // Hand icon
            ZStack {
                Circle()
                    .fill(isTracked ? color.opacity(0.3) : Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                Image(systemName: label == "L" ? "hand.point.left" : "hand.point.right")
                    .font(.title2)
                    .foregroundColor(isTracked ? .white : .gray)
            }
            
            // Trigger bar
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                    
                    // Fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(height: geo.size.height * CGFloat(triggerValue))
                }
            }
            .frame(width: 20, height: 40)
            
            // Label
            Text(label == "L" ? "Brake" : "Accel")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Steering Indicator

struct SteeringIndicator: View {
    let value: Float
    
    var body: some View {
        VStack(spacing: 8) {
            // Wheel visualization
            ZStack {
                // Wheel circle
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 8)
                    .frame(width: 80, height: 80)
                
                // Center hub
                Circle()
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 30, height: 30)
                
                // Position marker
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 12, height: 12)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(value) * 90)) // ±90° visual rotation
            }
            
            // Steering value
            Text(String(format: "%.0f%%", value * 100))
                .font(.caption)
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }
}

// MARK: - Preview

#Preview {
    VirtualSteeringWheelView(
        steeringService: VirtualSteeringWheelService(),
        viewModel: StreamingViewModel()
    )
    .background(Color.black)
}
