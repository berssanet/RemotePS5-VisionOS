# Android Chiaki-ng: Streaming Session Documentation

> **Package**: `com.metallic.chiaki.session`, `com.metallic.chiaki.stream`  
> **Files**: `StreamSession.kt`, `StreamInput.kt`, `StreamViewModel.kt`  
> **Purpose**: Session lifecycle and controller input management

---

## StreamViewModel.kt (46 lines)

Android ViewModel coordinating session, input, and preferences.

```kotlin
class StreamViewModel(
    val application: Application, 
    val connectInfo: ConnectInfo
): ViewModel() {
    val preferences = Preferences(application)
    val logManager = LogManager(application)
    val input = StreamInput(application, preferences)
    val session = StreamSession(connectInfo, logManager, preferences.logVerbose, input)
    
    // LiveData for UI state
    val onScreenControlsEnabled: LiveData<Boolean>
    val touchpadOnlyEnabled: LiveData<Boolean>
    
    fun setOnScreenControlsEnabled(enabled: Boolean)
    fun setTouchpadOnlyEnabled(enabled: Boolean)
    
    override fun onCleared() {
        session.shutdown()
    }
}
```

---

## StreamSession.kt (147 lines)

High-level session manager that wraps the native `Session` class with Android lifecycle awareness.

### Class Definition

```kotlin
class StreamSession(
    val connectInfo: ConnectInfo,
    val logManager: LogManager,
    val logVerbose: Boolean,
    val input: StreamInput
)
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `session` | `Session?` | Native session, null when idle |
| `state` | `LiveData<StreamState>` | Observable stream state |
| `rumbleState` | `LiveData<RumbleEvent>` | Observable rumble feedback |

### Stream States

```kotlin
sealed class StreamState
object StreamStateIdle: StreamState()
object StreamStateConnecting: StreamState()
object StreamStateConnected: StreamState()
data class StreamStateCreateError(val error: CreateError): StreamState()
data class StreamStateQuit(val reason: QuitReason, val reasonString: String?): StreamState()
data class StreamStateLoginPinRequest(val pinIncorrect: Boolean): StreamState()
```

### Lifecycle Methods

#### `resume()`
Creates and starts native session:
1. Creates `Session` with `connectInfo` and log file path
2. Sets state to `StreamStateConnecting`
3. Attaches event callback
4. Calls `session.start()`
5. Sets surface if available

#### `pause()` / `shutdown()`
Stops and disposes session:
1. Calls `session.stop()`
2. Calls `session.dispose()`
3. Sets state to `StreamStateIdle`

### Event Callback

```kotlin
private fun eventCallback(event: Event) {
    when(event) {
        is ConnectedEvent -> _state.postValue(StreamStateConnected)
        is QuitEvent -> _state.postValue(StreamStateQuit(...))
        is LoginPinRequestEvent -> _state.postValue(StreamStateLoginPinRequest(...))
        is RumbleEvent -> _rumbleState.postValue(event)
    }
}
```

### Surface Attachment

#### For SurfaceView (preferred)
```kotlin
fun attachToSurfaceView(surfaceView: SurfaceView) {
    surfaceView.holder.addCallback(object: SurfaceHolder.Callback {
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            session?.setSurface(holder.surface)
        }
        override fun surfaceDestroyed(holder: SurfaceHolder) {
            session?.setSurface(null)
        }
    })
}
```

#### For TextureView
```kotlin
fun attachToTextureView(textureView: TextureView) {
    textureView.surfaceTextureListener = object: TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(surface: SurfaceTexture, ...) {
            session?.setSurface(Surface(surface))
        }
    }
}
```

### PIN Submission
```kotlin
fun setLoginPin(pin: String) {
    session?.setLoginPin(pin)
}
```

---

## StreamInput.kt (206 lines)

Manages all controller input sources and merges them into a single `ControllerState`.

### Class Definition

```kotlin
class StreamInput(val context: Context, val preferences: Preferences) {
    var controllerStateChangedCallback: ((ControllerState) -> Unit)? = null
}
```

### Input Sources

The class maintains 4 separate `ControllerState` instances:

| Source | Purpose |
|--------|---------|
| `sensorControllerState` | Device motion sensors (accelerometer, gyroscope, rotation) |
| `keyControllerState` | Button key events (physical/Bluetooth controller) |
| `motionControllerState` | Analog stick and trigger motion events |
| `touchControllerState` | Touch screen virtual controller |

### Controller State Merging

```kotlin
val controllerState: ControllerState get() {
    val state = sensorControllerState or keyControllerState or motionControllerState
    
    // Apply screen rotation compensation for sensors
    when(windowManager.defaultDisplay.rotation) {
        Surface.ROTATION_90 -> {
            state.accelX *= -1.0f
            state.gyroX *= -1.0f
            // etc.
        }
    }
    
    // Prioritize motion controller triggers over key events
    if(motionControllerState.l2State > 0U)
        state.l2State = motionControllerState.l2State
    
    return state or touchControllerState
}
```

### Motion Sensor Handling

```kotlin
private val sensorEventListener = object: SensorEventListener {
    override fun onSensorChanged(event: SensorEvent) {
        when(event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                sensorControllerState.accelX = event.values[1] / SensorManager.GRAVITY_EARTH
                sensorControllerState.accelY = event.values[2] / SensorManager.GRAVITY_EARTH
                sensorControllerState.accelZ = event.values[0] / SensorManager.GRAVITY_EARTH
            }
            Sensor.TYPE_GYROSCOPE -> {
                sensorControllerState.gyroX = event.values[1]
                sensorControllerState.gyroY = event.values[2]
                sensorControllerState.gyroZ = event.values[0]
            }
            Sensor.TYPE_ROTATION_VECTOR -> {
                val q = floatArrayOf(0f, 0f, 0f, 0f)
                SensorManager.getQuaternionFromVector(q, event.values)
                sensorControllerState.orientX = q[2]
                sensorControllerState.orientY = q[3]
                sensorControllerState.orientZ = q[1]
                sensorControllerState.orientW = q[0]
            }
        }
        controllerStateUpdated()
    }
}
```

**Sensor Sampling**: 4000 microseconds (250 Hz)

### Key Event Handling

```kotlin
fun dispatchKeyEvent(event: KeyEvent): Boolean {
    val buttonMask: UInt = when(event.keyCode) {
        KeyEvent.KEYCODE_BUTTON_A -> 
            if(swapCrossMoon) BUTTON_MOON else BUTTON_CROSS
        KeyEvent.KEYCODE_BUTTON_B -> 
            if(swapCrossMoon) BUTTON_CROSS else BUTTON_MOON
        KeyEvent.KEYCODE_BUTTON_X -> 
            if(swapCrossMoon) BUTTON_PYRAMID else BUTTON_BOX
        KeyEvent.KEYCODE_BUTTON_Y -> 
            if(swapCrossMoon) BUTTON_BOX else BUTTON_PYRAMID
        KeyEvent.KEYCODE_BUTTON_L1 -> BUTTON_L1
        KeyEvent.KEYCODE_BUTTON_R1 -> BUTTON_R1
        KeyEvent.KEYCODE_BUTTON_THUMBL -> BUTTON_L3
        KeyEvent.KEYCODE_BUTTON_THUMBR -> BUTTON_R3
        KeyEvent.KEYCODE_BUTTON_SELECT -> BUTTON_SHARE
        KeyEvent.KEYCODE_BUTTON_START -> BUTTON_OPTIONS
        KeyEvent.KEYCODE_BUTTON_MODE -> BUTTON_PS
        else -> return false
    }
    
    when(event.action) {
        KeyEvent.ACTION_DOWN -> buttons = buttons or buttonMask
        KeyEvent.ACTION_UP -> buttons = buttons and buttonMask.inv()
    }
}
```

### Analog Stick Motion Handling

```kotlin
fun onGenericMotionEvent(event: MotionEvent): Boolean {
    if(event.source and SOURCE_CLASS_JOYSTICK != SOURCE_CLASS_JOYSTICK)
        return false
    
    fun Float.signedAxis() = (this * Short.MAX_VALUE).toInt().toShort()
    fun Float.unsignedAxis() = (this * UByte.MAX_VALUE).toUInt().toUByte()
    
    motionControllerState.leftX = event.getAxisValue(AXIS_X).signedAxis()
    motionControllerState.leftY = event.getAxisValue(AXIS_Y).signedAxis()
    motionControllerState.rightX = event.getAxisValue(AXIS_Z).signedAxis()
    motionControllerState.rightY = event.getAxisValue(AXIS_RZ).signedAxis()
    motionControllerState.l2State = event.getAxisValue(AXIS_LTRIGGER).unsignedAxis()
    motionControllerState.r2State = event.getAxisValue(AXIS_RTRIGGER).unsignedAxis()
    
    // D-pad from HAT axes
    val dpadX = event.getAxisValue(AXIS_HAT_X)
    val dpadY = event.getAxisValue(AXIS_HAT_Y)
    // Convert to discrete buttons...
}
```

### Lifecycle Integration

```kotlin
fun observe(lifecycleOwner: LifecycleOwner) {
    if(preferences.motionEnabled)
        lifecycleOwner.lifecycle.addObserver(motionLifecycleObserver)
}

// On resume: register sensor listeners
// On pause: unregister sensor listeners
```

---

## visionOS Implementation Mapping

| Android | visionOS Equivalent |
|---------|---------------------|
| `SurfaceView` | Metal view / RealityKit rendering |
| `SensorManager` | CMMotionManager |
| `KeyEvent` / `MotionEvent` | GCController |
| `LiveData<StreamState>` | `@Published` + Combine |
| Lifecycle observer | SwiftUI `.onAppear` / `.onDisappear` |

### Key Differences for visionOS

1. **No touch screen virtual controls** - Use GCController for MFi/DualSense controllers
2. **Motion from Apple Watch** - Or from connected DualSense controller's gyro
3. **Head tracking** - visionOS provides ARKit head pose that could be used for orientation
4. **Rumble feedback** - CoreHaptics for system haptics
