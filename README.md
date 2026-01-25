# VisionRemotePS5

PlayStation Remote Play client for Apple Vision Pro (VisionOS).

## 📦 Project Structure

```
VisionRemotePS5/
├── VisionRemotePS5App.swift      # App entry point with WindowGroup and ImmersiveSpace
├── Controllers/
│   └── GameControllerManager.swift   # DualSense/DualShock controller support
├── Models/
│   └── Console.swift                 # PlayStation console model
├── Resources/
│   ├── Assets.xcassets/              # App icons and colors
│   └── Localizable.xcstrings         # Localization (EN, PT-BR)
├── Services/
│   ├── ConsoleDiscoveryService.swift # UDP broadcast console discovery
│   ├── PSNAuthService.swift          # PlayStation Network OAuth2 authentication
│   └── StreamingSession.swift        # Connection lifecycle & encryption
├── Streaming/
│   ├── AudioDecoder.swift            # Opus audio decoding with spatial audio
│   └── VideoDecoder.swift            # H.264/H.265 hardware decoding (VideoToolbox)
└── Views/
    ├── ContentView.swift             # Main navigation with sidebar
    ├── HomeView.swift                # Console list and connection UI
    ├── LoginView.swift               # PSN WebView authentication
    ├── PairingView.swift             # Manual console pairing via PIN
    ├── SettingsView.swift            # App settings
    └── StreamingImmersiveView.swift  # Immersive streaming with RealityKit
```

## 🚀 Features

- **VisionOS Native UI** - Full SwiftUI + RealityKit interface
- **PSN Authentication** - OAuth2 login via WebView
- **Console Discovery** - UDP broadcast to find PS5 on network
- **Manual Pairing** - 8-digit PIN pairing support
- **Video Streaming** - H.264/H.265 hardware decoding (VideoToolbox)
- **Audio Streaming** - Opus decoder with spatial audio
- **Voice Chat** - Microphone capture and encoding
- **DualSense Support** - Full controller mapping via GameController.framework
- **Immersive Mode** - RealityKit curved display surface
- **Localization** - English and Portuguese-BR

## 🛠️ Requirements

- Xcode 15.4+
- VisionOS SDK 1.0+
- Apple Vision Pro or VisionOS Simulator
- PlayStation 5 on same local network

## 📱 Build & Run

1. Open `VisionRemotePS5.xcodeproj` in Xcode
2. Select "Apple Vision Pro" simulator or device
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
| L2/R2 | Triggers |
| D-Pad | Directional |
| L3/R3 | Thumbstick press |
| Options | Menu button |
| Share | Options button |
| PS | Home button |

## ⚠️ Legal Notice

This project is for **educational purposes only**. PlayStation Remote Play protocol is proprietary to Sony. Use at your own risk.

## 📄 License

MIT License
