//
//  StreamingView.swift
//  VisionRemotePS5
//
//  SwiftUI view for PS5 video streaming display (2D only)
//

import SwiftUI
import RealityKit
import VideoToolbox

// MARK: - Streaming View

struct StreamingView: View {
    @StateObject private var viewModel = StreamingViewModel()
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var isImmersiveActive = false
    @State private var use4KUpscaling = true  // Enabled by default
    
    let console: Console
    
    var body: some View {
        // Main video content area
        GeometryReader { geometry in
            videoContentView
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        // TOP ORNAMENT: Control bar floats above the window (resolves Z-fighting)
        .ornament(visibility: .visible, attachmentAnchor: .scene(.top)) {
            topControlBar
                .frame(height: 50)
                .padding(.horizontal, 16)
                .glassBackgroundEffect()
        }
        // BOTTOM ORNAMENT: Gamepad controls float below the window (resolves Z-fighting)
        .ornament(
            visibility: viewModel.showControls && !isImmersiveActive ? .visible : .hidden,
            attachmentAnchor: .scene(.bottom)
        ) {
            ControllerOverlayView(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(height: 160)
                .glassBackgroundEffect()
        }
        .task {
            // Initialize upscaling pipeline lazily
            upscalingPipeline.initialize()
            await viewModel.startStreaming(console: console)
        }
        .onDisappear {
            viewModel.stopStreaming()
            upscalingPipeline.disable()
        }
        // v10.3: Removed onChange(of: currentFrame) - frames now processed directly
        // in StreamingSession.setupVideoDecoderCallback() via VideoTextureCoordinator
    }
    
    // MARK: - Top Control Bar
    
    private var topControlBar: some View {
        HStack {
            Button(action: {
                viewModel.stopStreaming()
                dismiss()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }
            .padding(.leading, 16)
            
            Spacer()
            
            // VR mode toggle
            Button(action: {
                toggleVRMode()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isImmersiveActive ? "visionpro.fill" : "visionpro")
                    Text(isImmersiveActive ? "Exit VR" : "VR")
                        .font(.caption)
                }
                .foregroundColor(isImmersiveActive ? .blue : .white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            
            // 4K upscaling toggle
            Button(action: {
                use4KUpscaling.toggle()
                if use4KUpscaling {
                    if !upscalingPipeline.isEnabled {
                        upscalingPipeline.enable()
                    }
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: use4KUpscaling ? "4k.tv.fill" : "4k.tv")
                    Text(use4KUpscaling ? "4K" : "1080p")
                        .font(.caption)
                }
                .foregroundColor(use4KUpscaling ? .cyan : .white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            
            // Connection indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .padding(.trailing, 16)
        }
        .background(.ultraThinMaterial.opacity(0.8))
    }
    
    // MARK: - Video Content
    
    /// Simplified video content - mutually exclusive views, NO ZStack
    @ViewBuilder
    private var videoContentView: some View {
        if isImmersiveActive {
            // Minimal window while in immersive mode
            VStack(spacing: 16) {
                Image(systemName: "visionpro.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                
                Text("VR Mode Active")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Look around to see the virtual screen")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    toggleVRMode()
                }) {
                    Label("Exit VR Mode", systemImage: "xmark.circle")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.1).opacity(0.95))
            
        } else if use4KUpscaling,
                  upscalingPipeline.isEnabled,
                  let texture4K = upscalingPipeline.upscaledTexture {
            // 4K PATH: Use MetalTextureView (stable UIViewRepresentable + MTKView)
            // NOTE: RealityKitVideoView was removed because RealityView recreates
            // entities on each SwiftUI update, causing stacked/overlapping layers
            MetalTextureView(texture: texture4K, frameId: upscalingPipeline.textureFrameId)
                .aspectRatio(16/9, contentMode: .fit)
                .cornerRadius(12)
                .overlay(alignment: .topLeading) {
                    // Show resolution - only Spatial Scaler available on visionOS
                    resolutionBadge(
                        text: "4K (\(texture4K.width)x\(texture4K.height))",
                        color: .blue
                    )
                }
            
        } else if viewModel.isConnected {
            // v10.3: Connected but texture not ready yet
            // Video frames are now processed directly via VideoTextureCoordinator
            // This view will update when upscaledTexture becomes available
            VStack(spacing: 10) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Buffering...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(16/9, contentMode: .fit)
            .cornerRadius(12)
            .background(Color.black.opacity(0.3))
            .overlay(alignment: .topLeading) {
                resolutionBadge(text: "1080p", color: .gray)
            }
                
        } else {
            // Loading/connecting state
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(2)
                
                Text(viewModel.statusMessage)
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private func resolutionBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(6)
            .padding(12)
    }
    
    private func toggleVRMode() {
        Task {
            if isImmersiveActive {
                // Close immersive space
                await dismissImmersiveSpace()
                isImmersiveActive = false
            } else {
                // Open immersive space
                appState.selectedConsole = console
                
                let result = await openImmersiveSpace(id: "StreamingSpace")
                switch result {
                case .opened:
                    isImmersiveActive = true
                    print("[StreamingView] Immersive space opened successfully")
                case .userCancelled:
                    print("[StreamingView] User cancelled immersive space")
                case .error:
                    print("[StreamingView] Failed to open immersive space")
                @unknown default:
                    break
                }
            }
        }
    }
}

// MARK: - Video Frame View

struct VideoFrameView: View {
    let pixelBuffer: CVPixelBuffer
    
    var body: some View {
        GeometryReader { geometry in
            if let image = createImage(from: pixelBuffer) {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
    
    private func createImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        return cgImage
    }
}

// MARK: - Controller Overlay

struct ControllerOverlayView: View {
    @ObservedObject var viewModel: StreamingViewModel
    
    var body: some View {
        HStack(spacing: 40) {
            // D-Pad
            VStack(spacing: 0) {
                ControllerButtonView(symbol: "chevron.up", isPressed: viewModel.dpadUp) {
                    viewModel.pressButton(.dpadUp)
                } onRelease: {
                    viewModel.releaseButton(.dpadUp)
                }
                
                HStack(spacing: 0) {
                    ControllerButtonView(symbol: "chevron.left", isPressed: viewModel.dpadLeft) {
                        viewModel.pressButton(.dpadLeft)
                    } onRelease: {
                        viewModel.releaseButton(.dpadLeft)
                    }
                    
                    Spacer().frame(width: 40)
                    
                    ControllerButtonView(symbol: "chevron.right", isPressed: viewModel.dpadRight) {
                        viewModel.pressButton(.dpadRight)
                    } onRelease: {
                        viewModel.releaseButton(.dpadRight)
                    }
                }
                
                ControllerButtonView(symbol: "chevron.down", isPressed: viewModel.dpadDown) {
                    viewModel.pressButton(.dpadDown)
                } onRelease: {
                    viewModel.releaseButton(.dpadDown)
                }
            }
            
            Spacer()
            
            // Action buttons
            VStack(spacing: 0) {
                ControllerButtonView(symbol: "triangle.fill", isPressed: viewModel.triangle) {
                    viewModel.pressButton(.triangle)
                } onRelease: {
                    viewModel.releaseButton(.triangle)
                }
                
                HStack(spacing: 0) {
                    ControllerButtonView(symbol: "square.fill", isPressed: viewModel.square) {
                        viewModel.pressButton(.square)
                    } onRelease: {
                        viewModel.releaseButton(.square)
                    }
                    
                    Spacer().frame(width: 40)
                    
                    ControllerButtonView(symbol: "circle.fill", isPressed: viewModel.circle) {
                        viewModel.pressButton(.circle)
                    } onRelease: {
                        viewModel.releaseButton(.circle)
                    }
                }
                
                ControllerButtonView(symbol: "xmark", isPressed: viewModel.cross) {
                    viewModel.pressButton(.cross)
                } onRelease: {
                    viewModel.releaseButton(.cross)
                }
            }
        }
        .frame(maxWidth: 400)
    }
}

struct ControllerButtonView: View {
    let symbol: String
    let isPressed: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    
    var body: some View {
        Image(systemName: symbol)
            .font(.title2)
            .frame(width: 44, height: 44)
            .background(isPressed ? Color.blue : Color.gray.opacity(0.3))
            .cornerRadius(8)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPress() }
                    .onEnded { _ in onRelease() }
            )
    }
}

// MARK: - Streaming View Model

@MainActor
class StreamingViewModel: ObservableObject, StreamingServiceDelegate {
    // v10.3: Removed @Published currentFrame - frames now go directly to VideoTextureCoordinator
    // This eliminates SwiftUI re-renders for every frame (60fps → 0 updates)
    
    @Published var statusMessage = "Connecting..."
    @Published var isConnected = false
    @Published var showControls = true
    
    // Button states
    @Published var dpadUp = false
    @Published var dpadDown = false
    @Published var dpadLeft = false
    @Published var dpadRight = false
    @Published var cross = false
    @Published var circle = false
    @Published var square = false
    @Published var triangle = false
    
    private let streamingService = StreamingService.shared
    
    init() {
        streamingService.delegate = self
    }
    
    func startStreaming(console: Console) async {
        statusMessage = "Connecting to \(console.name)..."
        
        guard let rpKeyData = console.rpKey, rpKeyData.count == 16 else {
            statusMessage = "Invalid RP-Key. Please re-register the console."
            return
        }
        
        // Get PSN Account ID from console (saved during registration)
        let accountID = console.psnAccountId ?? Data(count: 8)
        
        if console.psnAccountId == nil {
            print("[StreamingView] ⚠️ Warning: No PSN Account ID saved for this console. This may cause connection issues.")
        }
        
        let config = StreamingConfiguration.defaultPS5Config(
            host: console.address,
            rpKey: rpKeyData,
            registKey: console.registKey ?? "",
            psnAccountID: accountID
        )
        
        do {
            try await streamingService.startStreaming(configuration: config)
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    func stopStreaming() {
        streamingService.stopStreaming()
    }
    
    func pressButton(_ button: ControllerButton) {
        streamingService.pressButton(button)
        updateButtonState(button, pressed: true)
    }
    
    func releaseButton(_ button: ControllerButton) {
        streamingService.releaseButton(button)
        updateButtonState(button, pressed: false)
    }
    
    private func updateButtonState(_ button: ControllerButton, pressed: Bool) {
        switch button {
        case .dpadUp: dpadUp = pressed
        case .dpadDown: dpadDown = pressed
        case .dpadLeft: dpadLeft = pressed
        case .dpadRight: dpadRight = pressed
        case .cross: cross = pressed
        case .circle: circle = pressed
        case .square: square = pressed
        case .triangle: triangle = pressed
        default: break
        }
    }
    
    // MARK: - StreamingServiceDelegate
    
    nonisolated func streamingService(_ service: StreamingService, didChangeState state: StreamingState) {
        Task { @MainActor in
            switch state {
            case .connecting:
                statusMessage = "Connecting..."
            case .requestingSession:
                statusMessage = "Requesting session..."
            case .negotiating:
                statusMessage = "Negotiating stream..."
            case .streaming:
                statusMessage = "Streaming"
                isConnected = true
            case .error(let msg):
                statusMessage = "Error: \(msg)"
                isConnected = false
            case .stopped:
                statusMessage = "Stopped"
                isConnected = false
            case .idle:
                statusMessage = "Ready"
            }
        }
    }
    
    nonisolated func streamingService(_ service: StreamingService, didReceiveVideoFrame frame: CVPixelBuffer, timestamp: UInt64) {
        // v10.3: Frames now go directly to VideoTextureCoordinator via StreamingSession
        // This eliminates MainActor dispatch overhead for 60fps video
        // Only post notification for views that need to know about frame availability
        NotificationCenter.default.post(name: .videoFrameReceived, object: nil)
    }
    
    nonisolated func streamingService(_ service: StreamingService, didReceiveAudioData data: Data, sampleRate: Int, channels: Int) {
        // Audio handled by StreamingService internally
    }
    
    nonisolated func streamingService(_ service: StreamingService, didReceiveError error: Error) {
        Task { @MainActor in
            statusMessage = "Error: \(error.localizedDescription)"
            isConnected = false
        }
    }
}
