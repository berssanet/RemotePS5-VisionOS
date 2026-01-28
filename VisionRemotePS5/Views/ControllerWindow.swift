//
//  ControllerWindow.swift
//  VisionRemotePS5
//
//  v10.5: Floating controller window - movable independently
//  Contains gamepad virtual controls
//

import SwiftUI

struct ControllerWindow: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ControllerOverlayView(viewModel: appState.streamingViewModel)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassBackgroundEffect()
    }
}
