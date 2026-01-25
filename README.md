# VisionRemotePS5

PlayStation Remote Play client for Apple Vision Pro (VisionOS).

## 📦 Project Structure

```
VisionRemotePS5/
├── VisionRemotePS5App.swift          # App entry point with WindowGroup and ImmersiveSpace
├── Controllers/
│   ├── GameControllerManager.swift       # DualSense/DualShock controller support
│   ├── HighFrequencyInputController.swift # 120Hz dedicated input polling thread
│   └── PS5HapticFeedbackParser.swift     # PS5 rumble/adaptive trigger parser
├── Models/
│   └── Console.swift                     # PlayStation console model
├── Resources/
│   ├── Assets.xcassets/                  # App icons and colors
│   └── Localizable.xcstrings             # Localization (EN, PT-BR)
├── Services/
│   ├── ConsoleDiscoveryService.swift     # UDP broadcast console discovery
│   ├── PSNAuthService.swift              # PlayStation Network OAuth2 authentication
│   └── StreamingSession.swift            # Connection lifecycle & encryption
├── Streaming/
│   ├── AudioDecoder.swift                # Opus audio decoding with spatial audio
│   ├── AudioRingBuffer.swift             # Lock-free SPSC ring buffer for audio
│   ├── AudioVideoSyncController.swift    # PTS-based A/V drift correction
│   ├── LowLatencyAudioPlayer.swift       # Stereo Emitter Array audio player
│   ├── MetalFXUpscaler.swift             # 1080p→4K upscaling with MetalFX
│   └── VideoDecoder.swift                # H.264/H.265 hardware decoding (VideoToolbox)
├── Shaders/
│   └── YUVToRGB.metal                    # GPU color space conversion shader
└── Views/
    ├── ContentView.swift                 # Main navigation with sidebar
    ├── HomeView.swift                    # Console list and connection UI
    ├── LoginView.swift                   # PSN WebView authentication
    ├── PairingView.swift                 # Manual console pairing via PIN
    ├── RealityKitVideoView.swift         # Video rendering with LowLevelTexture
    ├── SettingsView.swift                # App settings
    └── StreamingImmersiveView.swift      # Immersive streaming with RealityKit
```

## 🚀 Features

### Video Pipeline
- **MetalFX Upscaling** - 1080p→4K spatial upscaling with HDR support
- **LowLevelTexture** - Direct GPU texture updates via RealityKit (visionOS 2.0)
- **Zero-Copy Pipeline** - CVPixelBuffer → IOSurface → Metal → RealityKit
- **HDR/EDR Support** - `.bgra10_xr` Extended Range format for values > 1.0
- **MTLEvent Sync** - GPU-GPU synchronization without CPU waits

### Audio Pipeline
- **Spatial Audio** - Stereo Emitter Array with HRTF or Direct Stereo mode
- **Lock-Free Ring Buffer** - SPSC buffer for decoder → player communication
- **A/V Drift Correction** - PTS-based synchronization with 20ms threshold
- **Adaptive Latency** - Emergency drop for buffer overflow (>100ms)

### Input System
- **High-Frequency Polling** - 120Hz dedicated thread (off-MainActor)
- **DualSense Full Support** - Buttons, analog sticks, triggers, touchpad
- **Haptic Feedback** - Rumble motors from PS5 via `GCHaptics`
- **Adaptive Triggers** - L2/R2 resistance effects via `GCDualSenseAdaptiveTrigger`

### Connectivity
- **PSN Authentication** - OAuth2 login via WebView
- **Console Discovery** - UDP broadcast to find PS5 on network
- **Manual Pairing** - 8-digit PIN pairing support
- **Encryption** - AES-GCM session encryption

### VisionOS Integration
- **Immersive Mode** - RealityKit curved display surface
- **VisionOS Native UI** - Full SwiftUI interface
- **Localization** - English and Portuguese-BR

## 🛠️ Requirements

- Xcode 16.0+
- visionOS SDK 2.0+
- Apple Vision Pro
- PlayStation 5 on same local network

## 📱 Build & Run

1. Open `VisionRemotePS5.xcodeproj` in Xcode
2. Select "Apple Vision Pro" device
3. Build and Run (⌘R)

## ⚙️ Configuration

### Info.plist Capabilities
- **Microphone** - Voice chat
- **Local Network** - Console discovery (Bonjour: `_psremoteplay._tcp`)
- **Background Audio** - Streaming audio

### App Transport Security
Exceptions configured for:
- `*.playstation.net`
- `*.sonyentertainmentnetwork.com`

## 🎮 Controller Mapping

| DualSense | VisionOS |
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

## ⚠️ Legal Notice

This project is for **educational purposes only**. PlayStation Remote Play protocol is proprietary to Sony. Use at your own risk.

## 📄 License

MIT License
