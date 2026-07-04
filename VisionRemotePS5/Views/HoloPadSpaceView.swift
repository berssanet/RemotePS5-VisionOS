//
//  HoloPadSpaceView.swift
//  VisionRemotePS5
//
//  v12.6: HoloPad in WINDOWED streaming. ARKit hand tracking only exists
//  while an immersive space is open — the Shared Space never delivers the
//  hand skeleton. This view is the content of a `.mixed` immersive space
//  ("HoloPadSpace"): full passthrough, the normal streaming window stays
//  visible, and the only rendered content is the HoloPad feedback anchored
//  to the hands. Opened automatically by StreamingVideoWindow when streaming
//  starts in windowed mode; swapped out when the user enters full VR
//  (visionOS allows one immersive space at a time).
//
//  The input wiring is identical to the full-VR path in
//  StreamingImmersiveView: 120Hz timer → ChiakiFullSession.setControllerState,
//  neutral state while hands are untracked (console latches last state).
//

import SwiftUI

struct HoloPadSpaceView: View {
    @EnvironmentObject var appState: AppState

    @StateObject private var gestureService = HandGestureControllerService()
    @State private var inputTimer: Timer?

    var body: some View {
        Group {
            if #available(visionOS 2.0, *) {
                HoloPadFeedbackView(service: gestureService)
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        DebugLog.info("HoloPadSpace", "🖐️ Mixed-space HoloPad starting")
        Task {
            do {
                try await gestureService.startTracking()
            } catch {
                DebugLog.error("HoloPadSpace", "Hand tracking failed: \(error)")
            }
        }
        inputTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
            // Main-runloop timer fires on the main thread (5.20 pattern).
            MainActor.assumeIsolated {
                guard gestureService.isTracking else {
                    ChiakiFullSession.shared.setControllerState(
                        buttons: 0, leftX: 0, leftY: 0, rightX: 0, rightY: 0, l2: 0, r2: 0
                    )
                    return
                }
                ChiakiFullSession.shared.setControllerState(
                    buttons: gestureService.buttonsBitmask,
                    leftX: Int16(gestureService.leftStick.x * 32767),
                    leftY: Int16(gestureService.leftStick.y * 32767),
                    rightX: Int16(gestureService.rightStick.x * 32767),
                    rightY: Int16(gestureService.rightStick.y * 32767),
                    l2: UInt8(gestureService.leftTrigger * 255),
                    r2: UInt8(gestureService.rightTrigger * 255)
                )
            }
        }
    }

    private func stop() {
        inputTimer?.invalidate()
        inputTimer = nil
        gestureService.stopTracking()
        if #available(visionOS 2.0, *) {
            HoloPadFeedbackCoordinator.shared.reset()
        }
        DebugLog.info("HoloPadSpace", "Mixed-space HoloPad stopped")
    }
}
