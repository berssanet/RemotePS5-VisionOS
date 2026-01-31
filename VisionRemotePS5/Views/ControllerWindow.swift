//
//  ControllerWindow.swift
//  VisionRemotePS5
//
//  v10.5: Floating controller window - movable independently
//  v10.6: Supports Standard, F1 Cockpit, and Virtual Wheel modes
//

import SwiftUI

struct ControllerWindow: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            switch appState.controllerMode {
            case .standard:
                ControllerOverlayView(viewModel: appState.streamingViewModel)
            case .f1Cockpit:
                F1CockpitControllerView(viewModel: appState.streamingViewModel)
            case .virtualWheel:
                // Virtual wheel requires VR mode for hand tracking
                VirtualWheelPlaceholderView()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassBackgroundEffect()
    }
}

// MARK: - Virtual Wheel Placeholder (for windowed mode)

struct VirtualWheelPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.raised.fingers.spread")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text("Virtual Wheel")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Enter VR mode to use hand tracking")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(20)
    }
}
