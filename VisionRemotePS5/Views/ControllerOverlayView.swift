//
//  ControllerOverlayView.swift
//  VisionRemotePS5
//
//  Virtual gamepad overlay for touch controls
//

import SwiftUI

struct ControllerOverlayView: View {
    @ObservedObject var viewModel: StreamingViewModel
    
    var body: some View {
        HStack(spacing: 40) {
            // Left side - D-Pad
            VStack(spacing: 0) {
                // Up
                ControllerButtonView(symbol: "chevron.up") {
                    viewModel.sendButtonPress(.dpadUp)
                } onRelease: {
                    viewModel.sendButtonRelease(.dpadUp)
                }
                
                HStack(spacing: 20) {
                    // Left
                    ControllerButtonView(symbol: "chevron.left") {
                        viewModel.sendButtonPress(.dpadLeft)
                    } onRelease: {
                        viewModel.sendButtonRelease(.dpadLeft)
                    }
                    
                    // Right
                    ControllerButtonView(symbol: "chevron.right") {
                        viewModel.sendButtonPress(.dpadRight)
                    } onRelease: {
                        viewModel.sendButtonRelease(.dpadRight)
                    }
                }
                
                // Down
                ControllerButtonView(symbol: "chevron.down") {
                    viewModel.sendButtonPress(.dpadDown)
                } onRelease: {
                    viewModel.sendButtonRelease(.dpadDown)
                }
            }
            
            Spacer()
            
            // Center - Options/Share
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    // Share
                    ControllerButtonView(symbol: "square.and.arrow.up", size: 30) {
                        viewModel.sendButtonPress(.share)
                    } onRelease: {
                        viewModel.sendButtonRelease(.share)
                    }
                    
                    // Touchpad
                    ControllerButtonView(symbol: "rectangle.fill", size: 30) {
                        viewModel.sendButtonPress(.touchpad)
                    } onRelease: {
                        viewModel.sendButtonRelease(.touchpad)
                    }
                    
                    // Options
                    ControllerButtonView(symbol: "line.3.horizontal", size: 30) {
                        viewModel.sendButtonPress(.options)
                    } onRelease: {
                        viewModel.sendButtonRelease(.options)
                    }
                }
                
                // PS Button
                ControllerButtonView(symbol: "playstation.logo", size: 35) {
                    viewModel.sendButtonPress(.ps)
                } onRelease: {
                    viewModel.sendButtonRelease(.ps)
                }
            }
            
            Spacer()
            
            // Right side - Face buttons
            VStack(spacing: 0) {
                // Triangle
                ControllerButtonView(symbol: "triangle", color: .green) {
                    viewModel.sendButtonPress(.triangle)
                } onRelease: {
                    viewModel.sendButtonRelease(.triangle)
                }
                
                HStack(spacing: 20) {
                    // Square
                    ControllerButtonView(symbol: "square", color: .pink) {
                        viewModel.sendButtonPress(.square)
                    } onRelease: {
                        viewModel.sendButtonRelease(.square)
                    }
                    
                    // Circle
                    ControllerButtonView(symbol: "circle", color: .red) {
                        viewModel.sendButtonPress(.circle)
                    } onRelease: {
                        viewModel.sendButtonRelease(.circle)
                    }
                }
                
                // Cross
                ControllerButtonView(symbol: "xmark", color: .blue) {
                    viewModel.sendButtonPress(.cross)
                } onRelease: {
                    viewModel.sendButtonRelease(.cross)
                }
            }
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Controller Button View

struct ControllerButtonView: View {
    let symbol: String
    var color: Color = .white
    var size: CGFloat = 40
    let onPress: () -> Void
    let onRelease: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.6))
            .foregroundColor(isPressed ? color.opacity(0.5) : color)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(isPressed ? Color.white.opacity(0.3) : Color.white.opacity(0.1))
            )
            .overlay(
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}
