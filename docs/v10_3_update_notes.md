# VisionRemotePS5 v10.3 Update Notes
## High-Frequency Input, Haptic Feedback, and A/V Sync Improvements

**Date**: January 25, 2026

---

## New Features in v10.3

### 1. High-Frequency Input Controller

**File**: `Controllers/HighFrequencyInputController.swift` (NEW)

Dedicated input polling loop running on separate high-priority thread:

```
┌─────────────────────────────────────────────────────────────┐
│   HighFrequencyInputController (Dedicated Thread)           │
│   ├─ QoS: .userInteractive                                 │
│   ├─ threadPriority: 1.0 (maximum)                         │
│   ├─ Polling: 120Hz (mach_wait_until precision)            │
│   └─ Zero allocations in hot path                          │
└──────────────────────────┬──────────────────────────────────┘
                           │ InputPacket (28 bytes)
                           ▼
             StreamingSession.sendInputPacket()
                           │
                           ▼
                       UDP → PS5
```

**Key Improvements**:
- **Off-MainActor**: No longer blocks UI or contends with SwiftUI
- **Precise Timing**: Uses `mach_wait_until` for nanosecond precision
- **Change Detection**: Only sends packets when input changes (reduces bandwidth)
- **Statistics**: Tracks poll count, send count, average poll time

**Usage**:
```swift
let inputController = HighFrequencyInputController()
inputController.pollingFrequencyHz = 120
inputController.onInputPacket = { packet in
    streamingSession.sendInputPacket(packet)
}
inputController.start()
```

---

### 2. PS5 Haptic Feedback Parser

**File**: `Controllers/PS5HapticFeedbackParser.swift` (NEW)

Parser for PS5 haptic feedback packets including:
- **Rumble Motors**: Left (low frequency) and Right (high frequency)
- **Adaptive Triggers**: L2/R2 resistance effects
- **Lightbar RGB**: Color information (if supported)

**Packet Format (Chiaki)**:
```
Offset  Size  Description
0       1     Left motor (0-255)
1       1     Right motor (0-255)
2       1     L2 trigger mode
3-4     2     L2 parameters
5       1     R2 trigger mode
6-7     2     R2 parameters
8-10    3     Lightbar RGB (optional)
```

**Adaptive Trigger Effects**:
```swift
enum AdaptiveTriggerEffect {
    case off                                    // No resistance
    case feedback(startPosition, strength)      // Point resistance
    case weapon(start, end, strength)           // Range resistance
    case vibration(start, amplitude, frequency) // Vibrating
    case continuous(strength)                   // Full travel
}
```

---

### 3. Continuous Haptics Integration

**File**: `Controllers/GameControllerManager.swift` (MODIFIED)

New methods for PS5 feedback integration:

```swift
/// Apply parsed PS5 feedback to DualSense
func applyPS5Feedback(_ feedback: PS5HapticFeedback)

/// Smooth continuous rumble (avoids sudden changes)
func updateContinuousRumble(left: Float, right: Float)

/// Stop all haptic effects
func stopAllHaptics()
```

**Integration Flow**:
```
PS5 → UDP Feedback Packet
        │
        ▼
PS5HapticFeedbackParser.parseChiakiPacket()
        │
        ▼
GameControllerManager.applyPS5Feedback()
        │
        ├─────────────────┐
        ▼                 ▼
triggerRumble()   applyAdaptiveTriggerEffect()
   (L/R motors)      (L2/R2 resistance)
        │                 │
        ▼                 ▼
GCHaptics        GCDualSenseAdaptiveTrigger
```

---

### 4. Audio/Video Sync Controller

**File**: `Streaming/AudioVideoSyncController.swift` (NEW)

PTS-based drift correction system:

```
┌─────────────────────────────────────────────────────────────┐
│              AudioVideoSyncController                        │
│                                                              │
│  ┌─────────────────────┐    ┌─────────────────────────────┐ │
│  │   VideoMasterClock  │    │    AudioDriftCorrector      │ │
│  │   ├─ currentPTS     │    │    ├─ driftThresholdMs: 20  │ │
│  │   ├─ lastUpdateTime │    │    ├─ aggressiveMs: 50      │ │
│  │   └─ isRunning      │    │    └─ maxBufferMs: 100      │ │
│  └─────────────────────┘    └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Drift Correction Strategies**:

| Drift | Strategy | Action |
|-------|----------|--------|
| < 20ms | `.none` | No correction needed |
| 20-50ms | `.rateAdjust` | Adjust playback rate ±0.5% |
| > 50ms behind | `.skipSamples` | Skip samples with crossfade |
| > 50ms ahead | `.duplicateSamples` | Slow down rate |
| Buffer > 100ms | `.emergencyDrop` | Drop to target + 20ms margin |

---

## Updated Files Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `HighFrequencyInputController.swift` | NEW | 120Hz input polling thread |
| `PS5HapticFeedbackParser.swift` | NEW | PS5 haptic packet parser |
| `AudioVideoSyncController.swift` | NEW | PTS-based A/V sync |
| `GameControllerManager.swift` | MODIFIED | `applyPS5Feedback()`, continuous haptics |
| `LowLatencyAudioPlayer.swift` | MODIFIED | Drift correction integration |
| `StreamingSession.swift` | MODIFIED | Input controller, haptic routing |

---

## Performance Metrics (v10.3)

| Metric | Value | Notes |
|--------|-------|-------|
| Input Polling | 120Hz | Dedicated thread |
| Input-to-Send Latency | < 100μs | Zero-copy path |
| A/V Drift Threshold | 20ms | Before correction |
| Emergency Drop Threshold | 100ms | Buffer overflow |
| Crossfade Duration | 2ms | Smooth sample skip |

---

## Architecture Diagram (v10.3 Complete)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PlayStation 5                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │ HEVC/H.265  │  │    Opus     │  │ Controller  │  │   Haptic Output     │ │
│  │  Encoder    │  │   Encoder   │  │    RX       │  │ (Rumble/Triggers)   │ │
│  └──────┬──────┘  └──────┬──────┘  └──────▲──────┘  └──────────┬──────────┘ │
└─────────┼────────────────┼────────────────┼────────────────────┼────────────┘
          │ Video          │ Audio          │ Input              │ Feedback
          ▼                ▼                │                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Network (UDP/TCP)                                  │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │
┌────────────────────────────────┼────────────────────────────────────────────┐
│                          Apple Vision Pro                                    │
│                                │                                             │
│  ┌─────────────────────────────▼─────────────────────────────────────────┐  │
│  │                     StreamingSession                                   │  │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐│  │
│  │  │ VideoDecoder    │  │LowLatencyAudio  │  │HighFrequencyInput      ││  │
│  │  │ (VideoToolbox)  │  │   Player        │  │  Controller (120Hz)    ││  │
│  │  └────────┬────────┘  └────────┬────────┘  └───────────────────────┬┘│  │
│  │           │                    │                                   │ │  │
│  │  ┌────────▼────────┐  ┌────────▼────────┐                          │ │  │
│  │  │MetalFXUpscaler  │  │AudioVideoSync   │                          │ │  │
│  │  │ (1080p→4K)      │  │  Controller     │                          │ │  │
│  │  └────────┬────────┘  └─────────────────┘                          │ │  │
│  │           │                                                        │ │  │
│  │  ┌────────▼────────────────────────────────────────────────────────┴┐│  │
│  │  │                       Output Layer                               ││  │
│  │  │  ┌────────────────┐  ┌──────────────────┐  ┌──────────────────┐ ││  │
│  │  │  │RealityKit      │  │ Spatial Audio    │  │GameController    │ ││  │
│  │  │  │LowLevelTexture │  │ Stereo Emitter   │  │Manager (Haptics) │ ││  │
│  │  │  └────────────────┘  └──────────────────┘  └──────────────────┘ ││  │
│  │  └─────────────────────────────────────────────────────────────────┘│  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                    PS5HapticFeedbackParser                           │  │
│  │  ← Feedback packets ─────────────────────────────────────────────────│  │
│  └─────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Changelog

### v10.3 (January 25, 2026)
- **NEW**: `HighFrequencyInputController` - 120Hz dedicated input thread
- **NEW**: `PS5HapticFeedbackParser` - Rumble and adaptive trigger parsing
- **NEW**: `AudioVideoSyncController` - PTS-based drift correction
- **IMPROVED**: `GameControllerManager.applyPS5Feedback()` integration
- **IMPROVED**: `LowLatencyAudioPlayer` drift correction with threshold 20ms
- **IMPROVED**: Emergency drop for buffer overflow > 100ms

### v10.2 (Previous)
- MetalFX upscaling with MTLEvent sync
- LowLevelTexture integration for RealityKit
- HDR/EDR support with `.bgra10_xr` format

### v10.1 (Previous)
- Direct Stereo mode (HRTF bypass for PS5 Tempest)
- Closed-loop A/V sync
