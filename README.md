# VisionRemotePS5

PlayStation Remote Play client for Apple Vision Pro (visionOS).

## 📦 Project Structure

```
VisionRemotePS5/
├── VisionRemotePS5App.swift              # App entry point with WindowGroup and ImmersiveSpace
├── Controllers/
│   ├── GameControllerManager.swift       # DualSense/DualShock controller support
│   ├── HighFrequencyInputController.swift # 120Hz dedicated input polling thread
│   └── PS5HapticFeedbackParser.swift     # PS5 rumble/adaptive trigger parser
├── Models/
│   ├── Console.swift                     # PlayStation console model
│   └── WheelButtonHotspots.swift         # 3D wheel button hit zones
├── Resources/
│   ├── Assets.xcassets/                  # App icons and colors
│   ├── MercedesF1Wheel.usdz             # 3D F1 steering wheel model (22MB)
│   └── Localizable.xcstrings            # Localization (EN, PT-BR)
├── Services/
│   ├── ChiakiCrypto.swift               # AES-GCM encryption for RP protocol
│   ├── ChiakiFullSession.swift          # Native bridge to Chiaki streaming core
│   ├── ConsoleDiscoveryService.swift     # UDP broadcast console discovery
│   ├── ConsoleStorageService.swift       # Console persistence (Keychain/UserDefaults)
│   ├── HolepunchService.swift           # NAT traversal for remote connections
│   ├── Logger.swift                     # Centralized logging utility
│   ├── PSNAuthService.swift             # PlayStation Network OAuth2 authentication
│   ├── PSNSessionManager.swift          # PSN session lifecycle management
│   ├── PSNWebSocketService.swift        # WebSocket signaling for holepunch
│   ├── RegistrationService.swift        # Console registration protocol
│   ├── StreamingService.swift           # High-level streaming orchestration
│   ├── StreamingSession.swift           # Connection lifecycle & encryption
│   ├── VirtualSteeringWheelService.swift # Hand tracking → steering/throttle/brake
│   ├── WakeOnLanService.swift           # Wake-on-LAN for sleeping consoles
│   └── WheelButtonMappingService.swift  # PS5 button bitmask mapping for wheel
├── Streaming/
│   ├── AESGCMDecryptor.swift            # Hardware-accelerated AES decryption
│   ├── AudioDecoder.swift               # Opus audio decoding with spatial audio
│   ├── AudioRingBuffer.swift            # Lock-free SPSC ring buffer for audio
│   ├── AudioVideoSyncController.swift   # PTS-based A/V drift correction
│   ├── ColorSpaceConverter.swift        # BT.601/709/2020 color space conversion
│   ├── EnhancedUpscaler.swift           # Advanced upscaling with sharpening
│   ├── FramePacer.swift                 # Frame delivery timing (60/120Hz)
│   ├── LowLatencyAudioPlayer.swift      # Stereo Emitter Array audio player
│   ├── MetalFXUpscaler.swift            # 1080p→4K upscaling with MetalFX + HDR
│   ├── MotionEstimator.swift            # Motion-adaptive processing
│   ├── NetworkBufferPool.swift          # Pre-allocated network buffer management
│   ├── SafeBufferPool.swift             # Thread-safe buffer pool
│   ├── StreamingBufferPool.swift        # Streaming-optimized buffer allocation
│   ├── TripleBufferPool.swift           # Triple buffering for tear-free rendering
│   ├── UpscalingPipeline.swift          # GPU pipeline: decode → upscale → display
│   └── VideoDecoder.swift               # H.264/H.265 hardware decoding (VideoToolbox)
├── Shaders/
│   └── YUVToRGB.metal                   # GPU color space conversion shader
└── Views/
    ├── ContentView.swift                 # Main navigation with sidebar
    ├── ControllerOverlayView.swift       # On-screen controller touch overlay
    ├── ControllerWindow.swift            # Dedicated controller window
    ├── HomeView.swift                    # Console list and connection UI
    ├── LoginView.swift                   # PSN WebView authentication
    ├── MenuBarWindow.swift               # Floating menu bar for immersive mode
    ├── MetalTextureView.swift            # Metal texture rendering view
    ├── PSNConnectionView.swift           # Remote connection via PSN holepunch
    ├── PairingView.swift                 # Manual console pairing via PIN
    ├── RealityKitVideoView.swift         # Video rendering with LowLevelTexture
    ├── SettingsView.swift                # App settings
    ├── StreamingImmersiveView.swift      # Immersive streaming + 3D wheel + HUD
    ├── StreamingVideoWindow.swift        # Windowed streaming mode
    ├── StreamingView.swift               # Streaming session coordinator
    └── WheelConfigurationView.swift      # Wheel sensitivity/position settings
```

## 🚀 Features

### Video Pipeline
- **MetalFX Upscaling** — 1080p→4K spatial upscaling with HDR support
- **LowLevelTexture** — Direct GPU texture updates via RealityKit (visionOS 2.0)
- **Zero-Copy Pipeline** — CVPixelBuffer → IOSurface → Metal → RealityKit
- **HDR/EDR Support** — `.bgra10_xr` Extended Range format for values > 1.0
- **MTLEvent Sync** — GPU-GPU synchronization without CPU waits
- **Frame Pacing** — Adaptive 60/120Hz delivery with triple buffering

### Audio Pipeline
- **Spatial Audio** — Stereo Emitter Array with HRTF or Direct Stereo mode
- **Lock-Free Ring Buffer** — SPSC buffer for decoder → player communication
- **A/V Drift Correction** — PTS-based synchronization with 20ms threshold
- **Adaptive Latency** — Emergency drop for buffer overflow (>100ms)

### Input System
- **High-Frequency Polling** — 120Hz dedicated thread (off-MainActor)
- **DualSense Full Support** — Buttons, analog sticks, triggers, touchpad
- **Haptic Feedback** — Rumble motors from PS5 via `GCHaptics`
- **Adaptive Triggers** — L2/R2 resistance effects via `GCDualSenseAdaptiveTrigger`

### 🏎️ Virtual F1 Steering Wheel (Hand Tracking)
- **3D Mercedes F1 Wheel** — High-fidelity USDZ model rendered in RealityKit
- **Hand Tracking Steering** — Steering via hand position (VirtualSteeringWheelService)
- **Pinch Triggers** — L2 (brake) and R2 (throttle) via pinch gestures
- **120Hz Input Loop** — Steering, throttle, and brake sent at 120Hz to PS5
- **Button Panel** — On-screen face buttons (✕○□△), D-pad, Options, PS button
- **Button Panel as 3D Attachment** — Rendered via RealityView `attachments:` for immersive space
- **Cockpit Tilt** — Wheel angled at 20° for natural ergonomics

### Connectivity
- **PSN Authentication** — OAuth2 login via WebView
- **Console Discovery** — UDP broadcast to find PS5 on network
- **Remote Connection** — PSN holepunch for non-local play
- **Manual Pairing** — 8-digit PIN pairing support
- **Wake-on-LAN** — Wake sleeping consoles remotely
- **Encryption** — AES-GCM session encryption

### visionOS Integration
- **Immersive Mode** — RealityKit cinema-style 6m × 3.375m display at 4m distance
- **Floating Control Panel** — Glass-material panel with session controls
- **Controller Modes** — DualSense, on-screen overlay, or virtual F1 wheel
- **visionOS Native UI** — Full SwiftUI interface
- **Localization** — English and Portuguese-BR

## 🛠️ Requirements

- Xcode 16.0+
- visionOS SDK 2.0+
- Apple Vision Pro
- PlayStation 5 on same local network (or PSN account for remote play)

## 📱 Build & Run

1. Open `VisionRemotePS5.xcodeproj` in Xcode
2. Select "Apple Vision Pro" device
3. Build and Run (⌘R)

## ⚙️ Configuration

### Info.plist Capabilities
- **Microphone** — Voice chat
- **Local Network** — Console discovery (Bonjour: `_psremoteplay._tcp`)
- **Background Audio** — Streaming audio
- **Hand Tracking** — Virtual steering wheel input

### App Transport Security
Exceptions configured for:
- `*.playstation.net`
- `*.sonyentertainmentnetwork.com`

## 🎮 Controller Mapping

### DualSense / On-Screen Controller

| DualSense | visionOS |
|-----------|----------|
| △○✕□ | Face buttons |
| L1/R1 | Shoulders |
| L2/R2 | Triggers (with Adaptive Trigger feedback) |
| D-Pad | Directional |
| L3/R3 | Thumbstick press |
| Options | Menu button |
| Share | Options button |
| PS | Home button |
| Rumble | Haptic feedback (L/R motors) |

### Virtual F1 Wheel (Hand Tracking)

| Gesture | Action |
|---------|--------|
| Hand position (left-right) | Steering (left stick X) |
| Left pinch | L2 Brake |
| Right pinch | R2 Throttle |
| Button panel tap | Face buttons, D-pad, Options, PS |

## 🔧 Architecture Highlights

### Video Rendering (Zero-Copy)

```
CVPixelBuffer (VideoToolbox)
      │ IOSurface-backed
      ▼
CVMetalTexture (Zero-Copy)
      │
      ▼
MetalFX Spatial Upscaler (1080p→4K)
      │ MTLEvent sync
      ▼
UpscalingPipeline (ColorSpace + HDR)
      │
      ▼
LowLevelTexture.replace()
      │
      ▼
RealityKit UnlitMaterial (HDR/EDR)
```

### Audio/Video Sync

```
┌─────────────────────────────────────────┐
│     AudioVideoSyncController            │
│  ├─ VideoMasterClock (PTS-based)       │
│  └─ AudioDriftCorrector                │
│        ├─ < 20ms: No action            │
│        ├─ 20-50ms: Rate adjust (±0.5%) │
│        ├─ > 50ms: Skip/duplicate       │
│        └─ > 100ms: Emergency drop      │
└─────────────────────────────────────────┘
```

### Input Pipeline (120Hz)

```
HighFrequencyInputController (Thread dedicada)
      │ QoS: .userInteractive
      │ threadPriority: 1.0
      ▼
InputPacket (28 bytes)
      │
      ▼
StreamingSession → UDP → PS5
```

### Virtual Steering Wheel Pipeline

```
VirtualSteeringWheelService (ARKit Hand Tracking)
      │ 120Hz Timer
      ├─ steeringValue (-1.0 ... +1.0)
      ├─ leftTrigger (0.0 ... 1.0) → L2 brake
      └─ rightTrigger (0.0 ... 1.0) → R2 throttle
      │
      ▼
ChiakiFullSession.setControllerState()
      │ buttons | leftX | l2 | r2
      ▼
PS5 (via Remote Play protocol)
```

## ⚠️ Legal Notice

This project is for **educational purposes only**. PlayStation Remote Play protocol is proprietary to Sony. Use at your own risk.

## 📄 License

MIT License
