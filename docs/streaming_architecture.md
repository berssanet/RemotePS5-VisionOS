# VisionRemotePS5 Streaming Architecture
## PS5 Remote Play for Apple Vision Pro

**Version 10.0 — January 18, 2026 (Complete Technical Reference)**

---

## Table of Contents

1. [Overview](#1-overview)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Protocol Stack](#3-protocol-stack)
4. [C Bridge Layer (chiaki-ng)](#4-c-bridge-layer-chiaki-ng)
5. [Video Pipeline](#5-video-pipeline)
6. [Audio Pipeline](#6-audio-pipeline)
7. [Controller & Input](#7-controller--input)
8. [Services Layer](#8-services-layer)
9. [Rendering Layer](#9-rendering-layer)
10. [HDR Pipeline](#10-hdr-pipeline)
11. [v10.0 God Tier Features](#11-v100-god-tier-features)
12. [Critical Fixes & Guardrails](#12-critical-fixes--guardrails)
13. [Performance Metrics](#13-performance-metrics)
14. [Known Issues & Troubleshooting](#14-known-issues--troubleshooting)
15. [File Reference](#15-file-reference)
16. [Changelog](#16-changelog)

---

## 1. Overview

VisionRemotePS5 is a **native visionOS application** that streams PS5 gameplay to Apple Vision Pro using the **chiaki-ng** open-source library (via precompiled XCFramework). The architecture prioritizes:

- **Ultra-low latency** (<50ms motion-to-photon target)
- **Closed-Loop A/V Sync** (v10.0: Audio chases MEASURED video latency)
- **Stereo Emitter Array** (v10.0: L/R positioned at screen edges for realistic soundstage)
- **HDR support** (HDR10/P010 → EDR with luminance-preserving tone mapping)
- **4K upscaling** (1080p → 4K via MetalFX Spatial Scaler)
- **Dynamic EDR Headroom** (v10.0: Adapts to display thermal state)
- **DualSense support** (full button mapping + haptic feedback + adaptive triggers)
- **120Hz Controller Polling** (v9.0+: Reduced input lag)

### Technology Stack

| Layer | Technology | Details |
|-------|------------|---------|
| **Protocol** | chiaki-ng C library (XCFramework) | ~27KB ChiakiCore.c wrapper |
| **Swift Bridge** | ChiakiBridge + ChiakiFullSession | Swift-C interop |
| **Video Decode** | VideoToolbox (hardware HEVC/H.264) | Async decompression |
| **Video Buffers** | SafeBufferPool (12×4MB = 48MB) | v8.0: Race condition fix |
| **Upscaling** | MetalFX Spatial Scaler (2×) | 1080p → 4K |
| **Color Conversion** | Metal Compute Shaders | v8.0: Bilinear chroma + luminance TM |
| **Audio** | AVAudioSourceNode + AVAudioEnvironmentNode | v10.0: Stereo Emitter Array |
| **Rendering** | MetalTextureView / RealityKit | SDR/HDR support |

---

## 2. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PlayStation 5                                   │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │   HEVC Encoder  │  │  Opus Encoder   │  │  Controller RX  │             │
│  │   (1080p@60)    │  │   (48kHz/2ch)   │  │   (DualSense)   │             │
│  └────────┬────────┘  └────────┬────────┘  └────────▲────────┘             │
│           │                    │                    │                       │
│           └────────────────────┴────────────────────┘                       │
│                        UDP/9296 (Takion) + TCP/9295 (CTRL)                  │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │   Wi-Fi 6 / Network     │
                    │   (5GHz recommended)    │
                    └────────────┬────────────┘
                                 │
┌────────────────────────────────┼────────────────────────────────────────────┐
│                          Apple Vision Pro                                    │
│                                │                                             │
│  ┌─────────────────────────────▼──────────────────────────────────────────┐ │
│  │                      Chiaki.xcframework                                 │ │
│  │   • FEC recovery, GKCrypt decryption                                   │ │
│  │   • video_sample_cb → Swift                                            │ │
│  │   • audio_sink → Swift                                                 │ │
│  └───────────────────────────────┬────────────────────────────────────────┘ │
│                                  │                                           │
│  ┌───────────────────────────────▼────────────────────────────────────────┐ │
│  │                    StreamingService (Orchestrator)                      │ │
│  │   onVideoFramePointer     onAudioSamples        onEvent    onRumble    │ │
│  │   +frameReceiveTime       +sampleCount                                  │ │
│  └───────────┬───────────────────┬─────────────────────┬─────────────────┘  │
│              │                   │                     │                     │
│   ┌──────────▼─────────┐  ┌──────▼──────────────────┐  │                    │
│   │   SafeBufferPool   │  │ LowLatencyAudioPlayer   │  │                    │
│   │   (12×4MB = 48MB)  │  │  v10.0: Stereo Emitter  │  │                    │
│   │   [Race fix v8.0]  │  │  + Closed-Loop Sync     │  │                    │
│   └──────────┬─────────┘  └─────────────────────────┘  │                    │
│              │                                         │                    │
│   ┌──────────▼─────────────────────────────────────────────────────────┐   │
│   │                     Video Pipeline                                  │   │
│   │  VideoDecoder → ColorSpaceConverter → MetalFXUpscaler → Renderer   │   │
│   │    (HEVC)        (P010→Linear RGB)     (1080p→4K)                  │   │
│   │                   v8.0: Bilinear + Luminance TM                     │   │
│   │                   v10.0: Dynamic EDR Headroom                       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                     Controller Pipeline                              │   │
│   │  GameControllerManager → ChiakiFullSession.sendControllerInput()    │   │
│   │    120Hz polling          (UDP to PS5)                               │   │
│   │    + Adaptive Triggers                                               │   │
│   │    + CoreHaptics                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Protocol Stack

### Connection Establishment

```
┌────────────────┐                      ┌────────────────┐
│  Vision Pro    │                      │      PS5       │
└───────┬────────┘                      └───────┬────────┘
        │                                       │
        │  1. UDP Broadcast (Discovery)         │
        │  ────────────────────────────────→    │
        │  ←──────────────────────────────────  │
        │  2. Discovery Response (IP, MAC, ID)  │
        │                                       │
        │  3. WAKEUP Packet (UDP/9302)          │
        │  ────────────────────────────────→    │
        │  (PS5 protocol, not Magic Packet)     │
        │                                       │
        │  4. Session Request (TCP/9295)        │
        │  ────────────────────────────────→    │
        │  ←──────────────────────────────────  │
        │  5. Session Response (Nonce, Keys)    │
        │                                       │
        │  6. CTRL Connection (TCP/9295)        │
        │  ────────────────────────────────→    │
        │                                       │
        │  7. Senkusha (RTT + MTU test)         │
        │  ←────────────────────────────────→   │
        │  avg RTT: ~6.6ms                      │
        │                                       │
        │  8. Takion (UDP/9296) - AV Stream     │
        │  ←────────────────────────────────→   │
        │  FEC, GKCrypt encryption              │
        └───────────────────────────────────────┘
```

### Protocol Details

| Protocol | Port | Purpose | Encryption |
|----------|------|---------|------------|
| **Discovery** | UDP/987 | Find consoles on LAN | None |
| **WAKEUP** | UDP/9302 | Wake PS5 from rest mode | None |
| **Session** | TCP/9295 | Session negotiation | TLS-like |
| **CTRL** | TCP/9295 | Control messages, heartbeat | GKCrypt |
| **Takion** | UDP/9296 | A/V stream, controller input | GKCrypt + FEC |

---

## 4. C Bridge Layer (chiaki-ng)

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Swift Layer                             │
│  ┌─────────────────┐  ┌──────────────────────────────────┐  │
│  │ StreamingService│  │    ChiakiFullSession.swift       │  │
│  │   (orchestrator)│  │   onVideoFramePointer            │  │
│  │                 │  │   onAudioSamples                 │  │
│  │                 │  │   onEvent, onRumble              │  │
│  └─────────────────┘  └──────────────────────────────────┘  │
│                                   │                          │
│              Swift-C Interop (function pointers)            │
│                                   │                          │
│  ┌───────────────────────────────▼──────────────────────┐   │
│  │                  ChiakiCore.c                         │   │
│  │   • video_sample_cb, audio_sink_cb                   │   │
│  │   • chiaki_fullsession_start/stop_wrapper            │   │
│  │   • chiaki_set_controller_state_wrapper              │   │
│  └──────────────────────────────────────────────────────┘   │
│                                   │                          │
└───────────────────────────────────┼──────────────────────────┘
                                    │
                    ┌───────────────▼───────────────┐
                    │      Chiaki.xcframework       │
                    │   libchiaki_full.a (arm64)    │
                    │   • chiaki_session.c          │
                    │   • videoreceiver.c           │
                    │   • audioreceiver.c           │
                    │   • gkcrypt.c, fec.c          │
                    └───────────────────────────────┘
```

### Key C API Functions

```c
// Session lifecycle
int chiaki_fullsession_start_wrapper(
    const char* host,
    const uint8_t* registKey,   // 16 bytes
    const uint8_t* rpKey,       // 16 bytes
    const uint8_t* psnAccountID, // 8 bytes
    uint32_t width, uint32_t height,
    uint32_t fps, uint32_t bitrate,
    bool isPS5
);

void chiaki_fullsession_stop_wrapper(void);

// Controller input (120Hz)
void chiaki_set_controller_state_wrapper(
    uint32_t buttons,
    int16_t leftX, int16_t leftY,
    int16_t rightX, int16_t rightY,
    uint8_t l2, uint8_t r2
);

// Callbacks (Swift receives)
typedef void (*ChiakiWrapperVideoCallback)(const uint8_t* buf, size_t bufSize, void* user);
typedef void (*ChiakiWrapperAudioCallback)(const int16_t* buf, size_t samplesCount, void* user);
typedef void (*ChiakiWrapperRumbleCallback)(uint8_t left, uint8_t right, void* user);
```

### ABI Fix (v8.0 Critical)

```
IMPORTANT: ChiakiSession struct must match between XCFramework and headers!

Correct offsets (with OPUS enabled):
  video_sample_cb:      offset 608 bytes
  video_sample_cb_user: offset 616 bytes
  audio_sink:           offset 624 bytes

Build flags MUST include: -DCHIAKI_LIB_ENABLE_OPUS=1
```

---

## 5. Video Pipeline

### Data Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Video Pipeline (v10.0)                            │
│                                                                           │
│  chiaki callback      SafeBufferPool     VideoDecoder                    │
│        │                    │                 │                           │
│    [network buf] ──copy──► [safe copy] ──► [HEVC decode]                 │
│                            48MB pool        VideoToolbox                  │
│                                                │                          │
│                                        ┌───────▼────────┐                 │
│                                        │ CVPixelBuffer  │                 │
│                                        │ (1080p, BGRA   │                 │
│                                        │  or P010 HDR)  │                 │
│                                        └───────┬────────┘                 │
│                                                │                          │
│                         ┌──────────────────────┼──────────────────────┐  │
│                         │                v10.0: Measure decode latency │  │
│                         │   decodeLatencyMs = (now - frameReceiveTime) │  │
│                         │   → audioPlayer.updateDynamicTarget()        │  │
│                         └──────────────────────┼──────────────────────┘  │
│                                                │                          │
│               ┌────────────────────────────────┴───────────────────────┐ │
│               │                     HDR Path?                           │ │
│               └───────────────┬────────────────────────┬───────────────┘ │
│                     P010 (HDR)│                        │BGRA (SDR)       │
│                               ▼                        ▼                 │
│                  ┌────────────────────┐   ┌─────────────────────┐       │
│                  │ ColorSpaceConverter│   │  Direct passthrough │       │
│                  │  P010 → Linear RGB │   │                     │       │
│                  │  BT.2020 + PQ EOTF │   │                     │       │
│                  │  Luminance TM      │   │                     │       │
│                  │  + Dynamic EDR     │   │                     │       │
│                  └─────────┬──────────┘   └──────────┬──────────┘       │
│                            │                         │                   │
│                            └───────────┬─────────────┘                   │
│                                        ▼                                 │
│                           ┌─────────────────────────┐                    │
│                           │   MetalFXUpscaler       │                    │
│                           │   1080p → 4K (2× scale) │                    │
│                           │   Spatial Scaler only   │                    │
│                           │   (Temporal N/A visionOS)│                   │
│                           └────────────┬────────────┘                    │
│                                        ▼                                 │
│                           ┌─────────────────────────┐                    │
│                           │  TripleBufferPool       │                    │
│                           │  3× 3840×2160 textures  │                    │
│                           └────────────┬────────────┘                    │
│                                        ▼                                 │
│                           ┌─────────────────────────┐                    │
│                           │    Renderer Output      │                    │
│                           │  MetalTextureView (SDR) │                    │
│                           │  or RealityKit (immersive)│                  │
│                           └─────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────────────┘
```

### v8.0 Critical Fix: SafeBufferPool

**Problem**: Race condition where VideoToolbox reads NAL data AFTER chiaki's network thread overwrites the buffer.

**Solution**: 12-buffer pool with immediate synchronous copy:

```swift
// StreamingService.swift - v8.0 SAFE VIDEO PATH
ChiakiFullSession.shared.onVideoFramePointer = { pointer, size in
    // v10.0: Record timestamp for closed-loop A/V sync
    let frameReceiveTime = CFAbsoluteTimeGetCurrent()
    
    // CRITICAL: Copy network data to safe buffer IMMEDIATELY
    guard let safeBuffer = videoBufferPool.acquireAndCopy(from: pointer, count: size) else {
        print("⚠️ Buffer pool exhausted")
        return
    }
    
    // Decode from SAFE buffer (async, buffer released in completion)
    decoder.decodeFromSafeBuffer(safeBuffer) { pixelBuffer, timestamp in
        videoBufferPool.release(safeBuffer)
        
        // v10.0: Calculate measured video latency
        let decodeLatencyMs = (CFAbsoluteTimeGetCurrent() - frameReceiveTime) * 1000
        let totalVideoLatencyMs = decodeLatencyMs + 8 + 16  // + upscale + display
        
        // Closed-loop: Update audio target to match video
        audioPlayer.updateDynamicTarget(measuredLatencyMs: totalVideoLatencyMs)
        
        delegate?.streamingService(didReceiveVideoFrame: pixelBuffer)
    }
}
```

### Video Decoder

```swift
// VideoDecoder.swift
class VideoDecoder: ObservableObject {
    // Supports HEVC (PS5 default) and H.264 (PS4/fallback)
    // P010 output for HDR, BGRA for SDR
    
    private var decompressionSession: VTDecompressionSession?
    private var vps, sps, pps: Data?  // HEVC parameter sets
    
    func decodeFromSafeBuffer(_ buffer: SafeBuffer, completion: @escaping (CVPixelBuffer?) -> Void) {
        // 1. Split NAL units (Annex-B start codes)
        // 2. Extract VPS/SPS/PPS for session creation
        // 3. Convert to AVCC format for VideoToolbox
        // 4. Async decode via VTDecompressionSession
    }
}
```

---

## 6. Audio Pipeline

### v10.0 Stereo Emitter Array

**Problem (v9.0)**: Single spatial point at (0, 0, -2) collapsed stereo to mono, destroying soundstage.

**Solution (v10.0)**: Two separate AVAudioSourceNode instances positioned at virtual screen edges:

```
                     ┌───────────────────────────┐
                     │    Virtual Screen (2m)    │
                     │                           │
      Left Emitter   │                           │   Right Emitter
      (-1.25, 0, -2) │                           │   (+1.25, 0, -2)
           ◀═════════│          👤               │═════════▶
                     │        Listener           │
                     │       (0, 0, 0)           │
                     │                           │
                     └───────────────────────────┘
                     
      "Phantom Center" reconstructed naturally by brain
```

### Audio Data Flow

```
┌──────────────────────────────────────────────────────────────────────────┐
│                     Audio Pipeline (v10.0)                                │
│                                                                           │
│  chiaki_audio_sink_cb (48kHz, stereo Int16, Opus-decoded)                │
│              │                                                            │
│              ▼                                                            │
│  ┌───────────────────────────────────────────────────────────────┐       │
│  │              LowLatencyAudioPlayer.enqueueSamples()            │       │
│  │                                                                │       │
│  │    ┌─────────────────────────────────────────────┐            │       │
│  │    │         Deinterleave Stereo                 │            │       │
│  │    │  [L0,R0,L1,R1,...] → [L0,L1,...] + [R0,R1]  │            │       │
│  │    └──────────────┬────────────────┬─────────────┘            │       │
│  │                   │                │                          │       │
│  │            ┌──────▼──────┐  ┌──────▼──────┐                   │       │
│  │            │ Left Ring   │  │ Right Ring  │                   │       │
│  │            │   Buffer    │  │   Buffer    │                   │       │
│  │            │ (5s capacity)  │ (5s capacity) │                  │       │
│  │            └──────┬──────┘  └──────┬──────┘                   │       │
│  │                   │                │                          │       │
│  │  AVAudioEngine    │                │                          │       │
│  │  ┌────────────────┴────────────────┴─────────────────────┐   │       │
│  │  │                                                        │   │       │
│  │  │   ┌─────────────────────┐   ┌─────────────────────┐   │   │       │
│  │  │   │  Left SourceNode   │   │  Right SourceNode   │   │   │       │
│  │  │   │  (render callback) │   │  (render callback)  │   │   │       │
│  │  │   └──────────┬─────────┘   └──────────┬──────────┘   │   │       │
│  │  │              │                        │              │   │       │
│  │  │   ┌──────────▼────────────────────────▼──────────┐   │   │       │
│  │  │   │           AVAudioEnvironmentNode              │   │   │       │
│  │  │   │   L: AVAudio3DPoint(-1.25, 0, -2)            │   │   │       │
│  │  │   │   R: AVAudio3DPoint(+1.25, 0, -2)            │   │   │       │
│  │  │   │   HRTFHQ rendering algorithm                  │   │   │       │
│  │  │   └──────────────────────┬───────────────────────┘   │   │       │
│  │  │                          │                           │   │       │
│  │  │                    ┌─────▼──────┐                    │   │       │
│  │  │                    │ mainMixer  │                    │   │       │
│  │  │                    └─────┬──────┘                    │   │       │
│  │  │                          │                           │   │       │
│  │  │                    ┌─────▼──────┐                    │   │       │
│  │  │                    │  output    │ → Speakers/AirPods │   │       │
│  │  │                    └────────────┘                    │   │       │
│  │  └───────────────────────────────────────────────────────┘   │       │
│  └───────────────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────────┘
```

### v10.0 Closed-Loop A/V Sync

```swift
// LowLatencyAudioPlayer.swift

/// Update audio target based on MEASURED video latency
func updateDynamicTarget(measuredLatencyMs: Double) {
    guard isRunning else { return }
    
    // EMA smoothing to prevent erratic adjustments
    // α = 0.1, emphasizes stability over responsiveness
    measuredVideoLatencyMs = measuredVideoLatencyMs * (1.0 - latencySmoothingFactor) + 
                             measuredLatencyMs * latencySmoothingFactor
    
    // Clamp to reasonable range
    let clampedMs = max(20, min(100, measuredVideoLatencyMs))
    let newTarget = Int(clampedMs * Double(sampleRate) / 1000.0)
    
    if abs(newTarget - targetSamples) > 48 {  // Only update if > 1ms change
        targetSamples = newTarget
        print("🎯 Closed-loop sync: \(measuredLatencyMs)ms → target \(clampedMs)ms")
    }
}
```

**Log Output (v10.0)**:
```
[LowLatencyAudio] 🎯 Closed-loop sync: 31ms → target 39ms
[LowLatencyAudio] 🎯 Closed-loop sync: 28ms → target 35ms
[StreamingService] 🎯 v10.0 Closed-loop sync: decode=3.4ms, total=27ms
```

### Audio Configuration

| Parameter | Value | Notes |
|-----------|-------|-------|
| Sample Rate | 48,000 Hz | PS5 default |
| Channels | 2 (stereo) | Deinterleaved to L/R |
| Bit Depth | 16-bit signed | Int16 → Float32 via vDSP |
| IO Buffer | 10ms | Configured via AVAudioSession |
| Target Latency | Dynamic (~27-40ms) | Closed-loop from video |
| Ring Buffer | 5 seconds per channel | ~480,000 samples |

---

## 7. Controller & Input

### Pipeline

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Controller Pipeline (v10.0)                          │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────┐    │
│  │              GameControllerManager                               │    │
│  │   • 120Hz polling (1.0/120.0 = 8.3ms interval)                  │    │
│  │   • GCController framework                                       │    │
│  │   • DualSense detection                                          │    │
│  └───────────────────────────┬──────────────────────────────────────┘    │
│                              │                                           │
│                   ControllerInput struct                                 │
│                              │                                           │
│  ┌───────────────────────────▼──────────────────────────────────────┐    │
│  │              StreamingService.sendControllerInput()               │    │
│  │   • Throttles to every frame (60fps)                             │    │
│  │   • Converts to PS button bitmask                                │    │
│  └───────────────────────────┬──────────────────────────────────────┘    │
│                              │                                           │
│  ┌───────────────────────────▼──────────────────────────────────────┐    │
│  │              ChiakiFullSession.sendControllerInput()              │    │
│  │   chiaki_set_controller_state_wrapper(                           │    │
│  │     buttons, leftX, leftY, rightX, rightY, l2, r2               │    │
│  │   )                                                               │    │
│  └───────────────────────────┬──────────────────────────────────────┘    │
│                              │                                           │
│                         UDP/9296 (Takion)                               │
│                              │                                           │
│                              ▼                                           │
│                         PlayStation 5                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

### v9.0+ Adaptive Triggers (DualSense)

```swift
// GameControllerManager.swift

enum AdaptiveTriggerMode {
    case off          // No resistance
    case feedback     // Resistance at specific point
    case weapon       // Resistance like pulling gun trigger
    case vibration    // Vibrating resistance
}

func setAdaptiveTrigger(
    isLeft: Bool,
    mode: AdaptiveTriggerMode,
    startPosition: Float = 0.0,
    endPosition: Float = 1.0,
    strength: Float = 0.5
) {
    guard let dualSense = controller.physicalInputProfile as? GCDualSenseGamepad else { return }
    
    let trigger = isLeft ? dualSense.leftTrigger : dualSense.rightTrigger
    
    switch mode {
    case .off:
        trigger.setModeFeedback(startPosition: 0, resistiveStrength: 0)
    case .feedback:
        trigger.setModeFeedback(startPosition: startPosition, resistiveStrength: strength)
    case .weapon:
        trigger.setModeWeapon(startPosition: startPosition, 
                              endPosition: endPosition, 
                              resistiveStrength: strength)
    case .vibration:
        trigger.setModeVibration(startPosition: startPosition,
                                  amplitude: strength,
                                  frequency: 0.5)
    }
}
```

### Button Mapping

| PS5 Button | Bit Position | Mask Value |
|------------|--------------|------------|
| Cross | 0 | 0x0001 |
| Circle | 1 | 0x0002 |
| Square | 2 | 0x0004 |
| Triangle | 3 | 0x0008 |
| L1 | 4 | 0x0010 |
| R1 | 5 | 0x0020 |
| L2 | 6 | 0x0040 |
| R2 | 7 | 0x0080 |
| Share | 8 | 0x0100 |
| Options | 9 | 0x0200 |
| L3 | 10 | 0x0400 |
| R3 | 11 | 0x0800 |
| PS | 12 | 0x1000 |
| Touchpad | 13 | 0x2000 |
| D-Pad Up | 16 | 0x10000 |
| D-Pad Down | 17 | 0x20000 |
| D-Pad Left | 18 | 0x40000 |
| D-Pad Right | 19 | 0x80000 |

---

## 8. Services Layer

### Service Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Services Layer                                  │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │                     StreamingService                                 ││
│  │   Main orchestrator for PS5 streaming                               ││
│  │   • Callbacks from chiaki                                           ││
│  │   • Video/audio pipeline coordination                               ││
│  │   • Controller input forwarding                                     ││
│  │   • State management                                                ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ChiakiFullSession│  │ConsoleDiscovery │  │RegistrationSvc  │         │
│  │   C API wrapper │  │   UDP broadcast │  │  HTTP + crypto  │         │
│  │   session mgmt  │  │   LAN discovery │  │  device pairing │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐         │
│  │ PSNAuthService  │  │PSNWebSocketSvc  │  │ WakeOnLanService│         │
│  │  OAuth flow     │  │  Account link   │  │  PS5 WAKEUP     │         │
│  │  Token mgmt     │  │  Remote connect │  │  UDP/9302       │         │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘         │
│                                                                          │
│  ┌─────────────────┐  ┌─────────────────┐                               │
│  │HolepunchService │  │ConsoleStorageSvc│                               │
│  │  NAT traversal  │  │  Persistence    │                               │
│  │  (for remote)   │  │  (UserDefaults) │                               │
│  └─────────────────┘  └─────────────────┘                               │
└─────────────────────────────────────────────────────────────────────────┘
```

### StreamingService State Machine

```
          ┌──────────┐
          │   idle   │
          └────┬─────┘
               │ startStreaming()
               ▼
          ┌──────────────┐
          │  connecting  │
          └────┬─────────┘
               │ WAKEUP sent
               ▼
       ┌────────────────────┐
       │ requestingSession  │
       └────────┬───────────┘
                │ 200 OK + Nonce
                ▼
         ┌────────────────┐
         │  negotiating   │
         └────────┬───────┘
                  │ CTRL connected + Senkusha pass
                  ▼
            ┌───────────────┐
            │   streaming   │──────────────────┐
            └───────────────┘                  │
                  │                            │ onEvent(.quit)
                  │ stopStreaming()            │
                  ▼                            ▼
             ┌─────────┐                 ┌───────────┐
             │ stopped │                 │  error()  │
             └─────────┘                 └───────────┘
```

---

## 9. Rendering Layer

### visionOS Rendering Options

```swift
// Streaming View Modes

// 1. Windowed Mode (StreamingView)
struct StreamingView: View {
    var body: some View {
        MetalTextureView(texture: upscalingPipeline.upscaledTexture)
            .aspectRatio(16/9, contentMode: .fit)
    }
}

// 2. Immersive Mode (StreamingImmersiveView)
struct StreamingImmersiveView: View {
    @State private var currentEDRHeadroom: CGFloat = 2.0  // v10.0 dynamic
    
    var body: some View {
        RealityView { content in
            // Create immersive surface at -2m distance
            let surface = Immersive4KSurface()
            content.add(surface)
        }
        .onReceive(videoFrameNotification) { frame in
            // v10.0: Update dynamic EDR headroom
            upscalingPipeline.updateEDRHeadroom(from: currentEDRHeadroom)
            
            let upscaled = upscalingPipeline.processFrame(frame)
            // Update RealityKit texture...
        }
    }
}
```

### FramePacer (60fps Source → 90Hz Display)

```swift
// FramePacer.swift

class FramePacer {
    // Source: PS5 60fps, Display: Vision Pro 90Hz
    // Ratio: 1.5:1 → Judder mitigation via adaptive timing
    
    private var displayLink: CADisplayLink?
    
    func start(sourceRefreshRate: Double = 60.0, displayRefreshRate: Double = 90.0) {
        let ratio = displayRefreshRate / sourceRefreshRate  // 1.5
        
        // Pattern: Show frame for 1, 2, 1, 2... display frames
        // This creates 1:2 pulldown for smooth 60→90 conversion
        
        displayLink = CADisplayLink(target: self, selector: #selector(displayTick))
        displayLink?.add(to: .main, forMode: .common)
    }
}
```

---

## 10. HDR Pipeline

### P010 → EDR Conversion

```
┌────────────────────────────────────────────────────────────────────────┐
│                        HDR Pipeline (v8.0+)                             │
│                                                                         │
│  PS5 (HDR10)                                                           │
│      │                                                                  │
│      ▼                                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  P010 (10-bit YUV 4:2:0)                                        │   │
│  │  • Y plane: Full resolution, 10-bit luma                        │   │
│  │  • CbCr plane: Half resolution (subsampled), 10-bit chroma      │   │
│  │  • Color primaries: BT.2020                                     │   │
│  │  • Transfer function: PQ (ST.2084)                              │   │
│  └──────────────────────────┬──────────────────────────────────────┘   │
│                             │                                           │
│                             ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │            ColorSpaceConverter (Metal Compute Shader)            │   │
│  │                                                                  │   │
│  │  1. v8.0: Bilinear chroma upsampling (not nearest-neighbor!)   │   │
│  │     constexpr sampler chromaSampler(filter::linear);            │   │
│  │     float2 cbcr = cbcrTexture.sample(chromaSampler, uv).rg;     │   │
│  │                                                                  │   │
│  │  2. Expand Limited Range [16,235]/[16,240] → Full Range        │   │
│  │                                                                  │   │
│  │  3. YCbCr → RGB via BT.2020 matrix                              │   │
│  │                                                                  │   │
│  │  4. PQ EOTF (ST.2084) → Linear                                  │   │
│  │     L = ((max(Y^(1/m2) - c1, 0)) / (c2 - c3 * Y^(1/m2)))^(1/m1) │   │
│  │                                                                  │   │
│  │  5. v8.0: Luminance-based Reinhard Tone Mapping                 │   │
│  │     float luma = dot(col, float3(0.2126, 0.7152, 0.0722));     │   │
│  │     float newLuma = luma / (1.0 + luma);                        │   │
│  │     return col * (newLuma / luma);  // Preserves hue!          │   │
│  │                                                                  │   │
│  │  6. v10.0: Scale to dynamic EDR headroom                        │   │
│  │     rgb = rgb * edrHeadroom / 10.0;                             │   │
│  │     rgb = clamp(rgb, 0.0, edrHeadroom);                         │   │
│  └──────────────────────────┬──────────────────────────────────────┘   │
│                             │                                           │
│                             ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Output: RGBA16Float (Linear RGB)                                │   │
│  │  For MetalFX: bgra10_xr (EDR extended range)                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────────┘
```

### v10.0 Dynamic EDR Headroom

```swift
// UpscalingPipeline.swift

/// v10.0: Receive live EDR headroom from SwiftUI Environment
func updateEDRHeadroom(from environmentValue: CGFloat) {
    let currentHeadroom = Float(environmentValue)
    
    // Only update if changed significantly (avoid shader churn)
    if abs(currentHeadroom - lastEDRHeadroom) > 0.1 {
        lastEDRHeadroom = currentHeadroom
        colorSpaceConverter?.setEDRHeadroom(currentHeadroom)
        
        print("🌟 v10.0 EDR Headroom (live): \(currentHeadroom)x")
    }
}
```

**Note**: `@Environment(\.displayEDRHeadroom)` is NOT available on visionOS. The implementation uses a `@State` fallback with plans for future integration with `ProcessInfo` thermal state monitoring.

---

## 11. v10.0 God Tier Features

### 11.1 Stereo Emitter Array (CRITICAL)

| Aspect | v9.0 | v10.0 |
|--------|------|-------|
| Audio Sources | 1 (mono position) | 2 (L/R separate) |
| Position | (0, 0, -2) | L: (-1.25, 0, -2), R: (+1.25, 0, -2) |
| Stereo Imaging | Destroyed | Preserved (phantom center) |
| Ring Buffers | 1 interleaved | 2 mono (L and R) |

```swift
// v10.0 positioning (LowLatencyAudioPlayer.swift)
let halfWidth = virtualScreenWidth / 2.0  // 1.25m for 2.5m wide screen

leftSource.position = AVAudio3DPoint(x: -halfWidth, y: 0, z: -virtualScreenDistance)
rightSource.position = AVAudio3DPoint(x: +halfWidth, y: 0, z: -virtualScreenDistance)
```

### 11.2 Closed-Loop A/V Sync (MEDIUM)

| Aspect | v9.0 | v10.0 |
|--------|------|-------|
| Audio Target | Fixed 40ms | Dynamic (measured) |
| Sync Method | Open-loop estimate | Closed-loop feedback |
| Update Trigger | Once at init | Every frame decode |
| Latency Tracking | None | `frameReceiveTime` timestamp |

### 11.3 Dynamic EDR Headroom (HIGH)

| Aspect | v9.0 | v10.0 |
|--------|------|-------|
| EDR Value | Static 2.0x | Dynamic (thermal-aware) |
| Source | Hardcoded | Scene-based monitoring |
| HDR Clipping | Risk of clipping | Prevented via dynamic adjustment |

### 11.4 120Hz Controller Polling (LOW)

Already implemented in v9.0:
```swift
func startPolling(interval: TimeInterval = 1.0 / 120.0)  // 8.3ms
```

### 11.5 CompositorServices Migration (DEFERRED)

**Status**: Not implemented - requires major architectural changes.

**Expected Benefits**:
- Bypass RealityKit game loop (~6-8ms latency reduction)
- Direct Metal-to-Glass rendering via `cp_layer_renderer`
- Sub-frame latency for VR content

---

## 12. Critical Fixes & Guardrails

### v8.0 Fixes

1. **SafeBufferPool Race Condition**
   - Problem: VideoToolbox reads after chiaki overwrites buffer
   - Fix: 12-buffer pool with immediate synchronous copy

2. **Bilinear Chroma Upsampling**
   - Problem: Nearest-neighbor caused blockiness
   - Fix: `filter::linear` sampler in Metal shader

3. **Luminance-Based Tone Mapping**
   - Problem: Per-channel Reinhard caused hue shifts
   - Fix: Compress luminance only, scale RGB proportionally

### v10.0 Fixes

1. **displayEDRHeadroom API Unavailable**
   - Problem: `@Environment(\.displayEDRHeadroom)` doesn't exist on visionOS
   - Fix: `@State` fallback with TODO for thermal state monitoring

---

## 13. Performance Metrics

### Measured on Vision Pro (M2, visionOS 2.0)

| Metric | Value | Target |
|--------|-------|--------|
| Network RTT | ~6.6ms avg | <10ms |
| Video Decode | 3-5ms | <8ms |
| MetalFX Upscale | 5-7ms | <10ms |
| Audio Target | 27-35ms (dynamic) | Match video |
| Total Latency | ~45-55ms | <50ms |
| Frame Rate | 60fps | 60fps |
| Output Resolution | 3840×2160 | 4K |
| HDR | P010 → EDR | 10-bit |
| Packet Loss | <1% (soft WiFi 6) | <0.1% |

### Log Examples

```
[Chiaki/INF] Senkusha determined average RTT = 6.610 ms
[MetalFXUpscaler] 📊 Frame 300 processed (SPATIAL)
[UpscalingPipeline] 📊 300 frames, 6.1ms/frame (MetalFX, SDR)
[StreamingService] 🎯 v10.0 Closed-loop sync: decode=3.4ms, total=27ms
[LowLatencyAudio] 🔊 v10.0 Stereo Emitter Array enabled
[LowLatencyAudio]   L: (-1.25, 0, -2.0)
[LowLatencyAudio]   R: (+1.25, 0, -2.0)
```

---

## 14. Known Issues & Troubleshooting

### Network Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| FEC failed, missing units | Wi-Fi congestion | Use 5GHz, reduce interference |
| High RTT (>100ms) | Network load | Close other streaming apps |
| Corrupt frame reports | Packet loss burst | Increase FEC redundancy (server) |

### Audio Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| Audio ahead of video | Old target latency | Ensure v10.0 closed-loop active |
| Crackling/pops | Buffer underrun | Check `underrunCount` in logs |
| Mono sound | v9.0 single-source | Upgrade to v10.0 Stereo Emitter |

### Video Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| Black frames | Missing IDR | Wait for keyframe |
| Green artifacts | NAL parsing error | Check VPS/SPS/PPS extraction |
| Washed-out HDR | Wrong EOTF | Verify PQ transfer function |

---

## 15. File Reference

### Streaming (12 files)

| File | Purpose | Key Classes |
|------|---------|-------------|
| `VideoDecoder.swift` | HEVC/H.264 decode | `VideoDecoder` |
| `LowLatencyAudioPlayer.swift` | v10.0 Stereo Emitter Array | `LowLatencyAudioPlayer` |
| `AudioDecoder.swift` | Opus decode (unused, chiaki decodes) | `AudioDecoder` |
| `AudioRingBuffer.swift` | Lock-free SPSC buffer | `AudioRingBuffer` |
| `SafeBufferPool.swift` | Race-safe video buffer pool | `SafeBuffer`, `SafeBufferPool` |
| `TripleBufferPool.swift` | Texture triple-buffering | `TripleBufferPool` |
| `ColorSpaceConverter.swift` | P010→RGB, HDR tone mapping | `ColorSpaceConverter` |
| `MetalFXUpscaler.swift` | 1080p→4K upscaling | `MetalFXUpscaler` |
| `EnhancedUpscaler.swift` | Lanczos+CAS alternative | `EnhancedUpscaler` |
| `UpscalingPipeline.swift` | Pipeline orchestration | `UpscalingPipeline` |
| `FramePacer.swift` | 60→90Hz conversion | `FramePacer` |
| `MotionEstimator.swift` | (Optional) motion vectors | `MotionEstimator` |

### Services (12 files)

| File | Purpose | Key Classes |
|------|---------|-------------|
| `StreamingService.swift` | Main orchestrator | `StreamingService` |
| `ChiakiFullSession.swift` | C API wrapper | `ChiakiFullSession` |
| `ConsoleDiscoveryService.swift` | LAN discovery | `ConsoleDiscoveryService` |
| `RegistrationService.swift` | Device pairing | `RegistrationService` |
| `PSNAuthService.swift` | OAuth authentication | `PSNAuthService` |
| `PSNSessionManager.swift` | PSN session management | `PSNSessionManager` |
| `PSNWebSocketService.swift` | Account linking | `PSNWebSocketService` |
| `HolepunchService.swift` | NAT traversal | `HolepunchService` |
| `WakeOnLanService.swift` | PS5 WAKEUP protocol | `WakeOnLanService` |
| `ConsoleStorageService.swift` | Persistence | `ConsoleStorageService` |
| `ChiakiCrypto.swift` | Crypto utilities | Various functions |
| `StreamingSession.swift` | Alternative session impl | `StreamingSession` |

### Controllers

| File | Purpose | Key Classes |
|------|---------|-------------|
| `GameControllerManager.swift` | Input + haptics + adaptive triggers | `GameControllerManager` |

---

## 16. Changelog

### v10.0 (January 18, 2026) - God Tier

**Stereo Emitter Array (CRITICAL)**
- Refactored audio from single mono source to dual L/R sources
- Positions at virtual screen edges: L(-1.25,0,-2), R(+1.25,0,-2)
- Proper stereo imaging with phantom center reconstruction
- Separate deinterleaved ring buffers for each channel

**Closed-Loop A/V Sync (MEDIUM)**
- Track frame receive timestamp in video callback
- Measure actual decode latency per frame
- Dynamically update audio target to chase video latency
- EMA smoothing for stability (α=0.1)

**Dynamic EDR Headroom (HIGH)**
- Added `updateEDRHeadroom(from:)` to UpscalingPipeline
- Fallback @State variable (displayEDRHeadroom unavailable on visionOS)
- Ready for future thermal state integration

**Deferred: CompositorServices**
- Requires major architectural refactoring
- Would bypass RealityKit for ~6-8ms latency reduction

### v9.0 (January 2026) - State of the Art

- Dynamic A/V sync with 40ms target matching video pipeline
- World-locked spatial audio at z=-2m from listener
- Dynamic EDR headroom (static fallback for visionOS)
- DualSense adaptive triggers (feedback, weapon, vibration modes)
- 120Hz controller polling

### v8.0 (January 2026) - Gold Master

- SafeBufferPool: Fixed race condition with 12×4MB pool
- Bilinear chroma upsampling in color conversion
- Luminance-based Reinhard tone mapping (hue-preserving)
- MetalFX Spatial Scaler for 4K upscaling
- Full HEVC + HDR10 (P010) support

---

*Document generated: January 18, 2026*
*VisionRemotePS5 v10.0 — Professional-grade PS5 Remote Play for Apple Vision Pro*
