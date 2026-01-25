# Android Chiaki-ng: JNI Bridge Documentation

> **File**: `com/metallic/chiaki/lib/Chiaki.kt`  
> **Lines**: 535  
> **Purpose**: Primary bridge between Kotlin/Android and native C Chiaki library

---

## Overview

This file provides the complete JNI (Java Native Interface) bridge for all Chiaki functionality. It loads `libchiaki-jni.so` and exposes native functions for streaming, discovery, and registration.

---

## Enumerations

### `Target`
Identifies PlayStation console version and firmware.

```kotlin
enum class Target(val value: Int) {
    PS4_UNKNOWN(0),
    PS4_8(800),
    PS4_9(900),
    PS4_10(1000),
    PS5_UNKNOWN(1000000),
    PS5_1(1000100);
    
    val isPS5: Boolean get() = value >= PS5_UNKNOWN.value
    
    companion object {
        fun fromValue(value: Int): Target
    }
}
```

**visionOS equivalent**: Use integer enum with `isPS5` computed property.

---

### `VideoResolutionPreset`
```kotlin
enum class VideoResolutionPreset(val value: Int) {
    RES_360P(1),
    RES_540P(2),
    RES_720P(3),
    RES_1080P(4)
}
```

---

### `VideoFPSPreset`
```kotlin
enum class VideoFPSPreset(val value: Int) {
    FPS_30(30),
    FPS_60(60)
}
```

---

### `Codec`
```kotlin
enum class Codec(val value: Int) {
    CODEC_H264(0),
    CODEC_H265(1),
    CODEC_H265_HDR(2)
}
```

---

## Data Classes

### `ConnectVideoProfile`
Video streaming configuration.

```kotlin
data class ConnectVideoProfile(
    val width: Int,           // e.g., 1920
    val height: Int,          // e.g., 1080
    val maxFPS: Int,          // e.g., 60
    val bitrate: Int,         // e.g., 15000000
    val codec: Codec          // H264, H265, H265_HDR
)
```

**Factory Method**:
```kotlin
companion object {
    fun preset(resolutionPreset: VideoResolutionPreset, fpsPreset: VideoFPSPreset, codec: Codec): ConnectVideoProfile
}
```

---

### `ConnectInfo`
Complete connection configuration passed to native session.

```kotlin
data class ConnectInfo(
    val ps5: Boolean,              // true for PS5, false for PS4
    val host: String,              // IP address (e.g., "192.168.1.100")
    val registKey: ByteArray,      // Registration key (16 bytes)
    val morning: ByteArray,        // RP-Key from registration (16 bytes)
    val videoProfile: ConnectVideoProfile
)
```

**visionOS equivalent**: Already implemented as `ChiakiConnectInfo` struct.

---

### `ControllerState`
Complete DualSense/DualShock controller state with all inputs.

```kotlin
data class ControllerState(
    var buttons: UInt = 0U,        // Bitmask of pressed buttons
    var l2State: UByte = 0U,       // L2 trigger (0-255)
    var r2State: UByte = 0U,       // R2 trigger (0-255)
    var leftX: Short = 0,          // Left stick X (-32768 to 32767)
    var leftY: Short = 0,          // Left stick Y
    var rightX: Short = 0,         // Right stick X
    var rightY: Short = 0,         // Right stick Y
    var touches: Array<ControllerTouch>,  // Touchpad (max 2 touches)
    var gyroX: Float = 0.0f,       // Gyroscope
    var gyroY: Float = 0.0f,
    var gyroZ: Float = 0.0f,
    var accelX: Float = 0.0f,      // Accelerometer
    var accelY: Float = 1.0f,
    var accelZ: Float = 0.0f,
    var orientX: Float = 0.0f,     // Orientation quaternion
    var orientY: Float = 0.0f,
    var orientZ: Float = 0.0f,
    var orientW: Float = 1.0f
)
```

**Button Constants**:
```kotlin
companion object {
    val BUTTON_CROSS      = (1 shl 0).toUInt()   // X button
    val BUTTON_MOON       = (1 shl 1).toUInt()   // Circle button
    val BUTTON_BOX        = (1 shl 2).toUInt()   // Square button
    val BUTTON_PYRAMID    = (1 shl 3).toUInt()   // Triangle button
    val BUTTON_DPAD_LEFT  = (1 shl 4).toUInt()
    val BUTTON_DPAD_RIGHT = (1 shl 5).toUInt()
    val BUTTON_DPAD_UP    = (1 shl 6).toUInt()
    val BUTTON_DPAD_DOWN  = (1 shl 7).toUInt()
    val BUTTON_L1         = (1 shl 8).toUInt()
    val BUTTON_R1         = (1 shl 9).toUInt()
    val BUTTON_L3         = (1 shl 10).toUInt()  // Left stick press
    val BUTTON_R3         = (1 shl 11).toUInt()  // Right stick press
    val BUTTON_OPTIONS    = (1 shl 12).toUInt()
    val BUTTON_SHARE      = (1 shl 13).toUInt()
    val BUTTON_TOUCHPAD   = (1 shl 14).toUInt()
    val BUTTON_PS         = (1 shl 15).toUInt()
    
    val TOUCHPAD_WIDTH: UShort = 1920U
    val TOUCHPAD_HEIGHT: UShort = 942U
}
```

**Key Methods**:
- `or(o: ControllerState)`: Merge two states (max values win)
- `startTouch(x, y): UByte?`: Start touch, returns touch ID
- `stopTouch(id)`: End touch
- `setTouchPos(id, x, y): Boolean`: Update touch position

---

### `ControllerTouch`
Single touchpad touch point.

```kotlin
data class ControllerTouch(
    var x: UShort = 0U,    // X position (0-1919)
    var y: UShort = 0U,    // Y position (0-941)
    var id: Byte = -1      // Touch ID (-1 = not touching)
)
```

---

## Native Interface (ChiakiNative)

Private class that loads `libchiaki-jni.so` and declares external JNI functions.

```kotlin
private class ChiakiNative {
    companion object {
        init {
            System.loadLibrary("chiaki-jni")
        }
        
        // Utility functions
        @JvmStatic external fun errorCodeToString(value: Int): String
        @JvmStatic external fun quitReasonToString(value: Int): String
        @JvmStatic external fun quitReasonIsError(value: Int): Boolean
        @JvmStatic external fun videoProfilePreset(resolutionPreset: Int, fpsPreset: Int, codec: Codec): ConnectVideoProfile
        
        // Session management
        @JvmStatic external fun sessionCreate(result: CreateResult, connectInfo: ConnectInfo, logFile: String?, logVerbose: Boolean, javaSession: Session)
        @JvmStatic external fun sessionFree(ptr: Long)
        @JvmStatic external fun sessionStart(ptr: Long): Int
        @JvmStatic external fun sessionStop(ptr: Long): Int
        @JvmStatic external fun sessionJoin(ptr: Long): Int
        @JvmStatic external fun sessionSetSurface(ptr: Long, surface: Surface?)
        @JvmStatic external fun sessionSetControllerState(ptr: Long, controllerState: ControllerState)
        @JvmStatic external fun sessionSetLoginPin(ptr: Long, pin: String)
        
        // Discovery
        @JvmStatic external fun discoveryServiceCreate(result: CreateResult, options: DiscoveryServiceOptions, javaService: DiscoveryService)
        @JvmStatic external fun discoveryServiceFree(ptr: Long)
        @JvmStatic external fun discoveryServiceWakeup(ptr: Long, host: String, userCredential: Long, ps5: Boolean)
        
        // Registration
        @JvmStatic external fun registStart(result: CreateResult, registInfo: RegistInfo, javaLog: ChiakiLog, javaRegist: Regist)
        @JvmStatic external fun registStop(ptr: Long)
        @JvmStatic external fun registFree(ptr: Long)
    }
}
```

---

## Session Class

Main streaming session class. Wraps native `ChiakiSession`.

### Constructor
```kotlin
class Session(connectInfo: ConnectInfo, logFile: String?, logVerbose: Boolean)
```

Creates native session. Throws `CreateError` on failure.

### Lifecycle Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `start()` | `ErrorCode` | Start streaming session |
| `stop()` | `ErrorCode` | Stop streaming session |
| `dispose()` | `Unit` | Join and free native resources |

### Control Methods

| Method | Parameters | Description |
|--------|-----------|-------------|
| `setSurface(surface)` | `Surface?` | Set Android Surface for video rendering |
| `setControllerState(state)` | `ControllerState` | Send controller input to PS5 |
| `setLoginPin(pin)` | `String` | Submit login PIN when requested |

### Event Callback

```kotlin
var eventCallback: ((event: Event) -> Unit)? = null
```

**Event Types**:
```kotlin
sealed class Event
object ConnectedEvent: Event()
data class LoginPinRequestEvent(val pinIncorrect: Boolean): Event()
data class QuitEvent(val reason: QuitReason, val reasonString: String?): Event()
data class RumbleEvent(val left: UByte, val right: UByte): Event()
```

**Native Callback Methods** (called from JNI):
- `eventConnected()` - Connection established
- `eventLoginPinRequest(pinIncorrect: Boolean)` - PIN needed
- `eventQuit(reasonValue: Int, reasonString: String?)` - Session ended
- `eventRumble(left: Int, right: Int)` - Controller rumble

---

## DiscoveryService Class

UDP-based console discovery service.

### Constructor
```kotlin
class DiscoveryService(
    options: DiscoveryServiceOptions,
    val callback: ((hosts: List<DiscoveryHost>) -> Unit)?
)
```

### Configuration
```kotlin
data class DiscoveryServiceOptions(
    val hostsMax: ULong,        // Max hosts to track
    val hostDropPings: ULong,   // Pings before host considered offline
    val pingMs: ULong,          // Ping interval in ms
    val sendAddr: InetSocketAddress  // Broadcast address
)
```

### Methods

| Method | Description |
|--------|-------------|
| `dispose()` | Free native resources |
| `wakeup(host, userCredential, ps5)` | Wake-on-LAN for console (static) |

### DiscoveryHost Data
```kotlin
data class DiscoveryHost(
    val state: State,           // UNKNOWN, READY, STANDBY
    val hostRequestPort: UShort,
    val hostAddr: String?,
    val systemVersion: String?,
    val deviceDiscoveryProtocolVersion: String?,
    val hostName: String?,
    val hostType: String?,
    val hostId: String?,        // MAC address
    val runningAppTitleid: String?,
    val runningAppName: String?
) {
    val isPS5: Boolean get() = deviceDiscoveryProtocolVersion == "00030010"
}
```

---

## Regist Class

Console registration handler.

### Constructor
```kotlin
class Regist(
    info: RegistInfo,
    log: ChiakiLog,
    val callback: (RegistEvent) -> Unit
)
```

### RegistInfo
```kotlin
data class RegistInfo(
    val target: Target,         // PS4/PS5 version
    val host: String,           // IP address
    val broadcast: Boolean,     // Use broadcast?
    val psnOnlineId: String?,   // PSN Online ID (PS4)
    val psnAccountId: ByteArray?, // Account ID (PS5, 8 bytes)
    val pin: Int               // 8-digit PIN from console
)
```

### RegistHost (successful registration result)
```kotlin
data class RegistHost(
    val target: Target,
    val apSsid: String,
    val apBssid: String,
    val apKey: String,
    val apName: String,
    val serverMac: ByteArray,   // Console MAC address
    val serverNickname: String, // Console name
    val rpRegistKey: ByteArray, // Registration key (16 bytes)
    val rpKeyType: UInt,
    val rpKey: ByteArray        // RP-Key (16 bytes)
)
```

### Events
```kotlin
sealed class RegistEvent
object RegistEventCanceled: RegistEvent()
object RegistEventFailed: RegistEvent()
class RegistEventSuccess(val host: RegistHost): RegistEvent()
```

### Methods

| Method | Description |
|--------|-------------|
| `stop()` | Cancel registration |
| `dispose()` | Free native resources |

---

## ChiakiLog Class

Logging utility with callback support.

```kotlin
class ChiakiLog(
    val levelMask: Int,
    val callback: (level: Int, text: String) -> Unit
) {
    enum class Level(val value: Int) {
        DEBUG(1 shl 4),
        VERBOSE(1 shl 3),
        INFO(1 shl 2),
        WARNING(1 shl 1),
        ERROR(1 shl 0),
        ALL(0.inv())
    }
    
    fun d(text: String)  // Debug
    fun v(text: String)  // Verbose
    fun i(text: String)  // Info
    fun w(text: String)  // Warning
    fun e(text: String)  // Error
    
    companion object {
        fun formatLog(level: Int, text: String): String
    }
}
```

---

## visionOS Implementation Mapping

| Android | visionOS Equivalent |
|---------|---------------------|
| `System.loadLibrary("chiaki-jni")` | Link to `Chiaki.xcframework` |
| `Session` class | `ChiakiFullSession.swift` |
| `Surface` | VideoToolbox + Metal rendering |
| `DiscoveryService` | `ConsoleDiscoveryService.swift` |
| `Regist` | `RegistrationService.swift` |
| `ControllerState` | `ChiakiControllerState` struct |
| JNI callbacks | Swift closures via C function pointers |

---

## Key Implementation Patterns

### Native Pointer Management
```kotlin
private var nativePtr: Long  // Holds C pointer

init {
    val result = CreateResult(0, 0)
    ChiakiNative.someCreate(result, ...)
    if(!ErrorCode(result.errorCode).isSuccess)
        throw CreateError(errorCode)
    nativePtr = result.ptr
}

fun dispose() {
    if(nativePtr == 0L) return
    ChiakiNative.someFree(nativePtr)
    nativePtr = 0L
}
```

### Event Callback Pattern
1. Native code calls private Java method (e.g., `eventConnected()`)
2. Private method wraps data in sealed class event
3. Event passed to user-provided callback lambda

This pattern is replicated in visionOS using Swift closures.
