# Android Chiaki-ng: Controller Input & Touch Controls

> **Package**: `com.metallic.chiaki.touchcontrols`  
> **Files**: `TouchControlsFragment.kt`, `AnalogStickView.kt`, `ButtonView.kt`, `DPadView.kt`  
> **Purpose**: On-screen touch controller input handling

---

## Overview

The touch controls system provides a virtual DualSense controller overlay for devices without physical controllers. It consists of custom View components for each control element.

---

## TouchControlsFragment.kt (127 lines)

Base fragment class for on-screen controls.

### Class Hierarchy

```kotlin
abstract class TouchControlsFragment : Fragment()
class DefaultTouchControlsFragment : TouchControlsFragment()
class TouchpadOnlyFragment : TouchControlsFragment()
```

### Base Class Properties

```kotlin
abstract class TouchControlsFragment : Fragment() {
    // Current controller state from touch inputs
    protected var ownControllerState = ControllerState()
    
    // Observable stream of state changes
    val controllerState: Observable<ControllerState>
    
    // Whether on-screen controls are visible
    var onScreenControlsEnabled: LiveData<Boolean>? = null
}
```

### State Update Pattern

```kotlin
protected var ownControllerState = ControllerState()
    set(value) {
        val diff = field != value
        field = value
        if(diff)
            ownControllerStateSubject.onNext(ownControllerState)
    }
```

Changes trigger RxJava subject emission only when state actually changes.

### DefaultTouchControlsFragment Layout Binding

```kotlin
override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
    // D-pad
    binding.dpadView.stateChangeCallback = this::dpadStateChanged
    
    // Face buttons
    binding.crossButtonView.buttonPressedCallback = buttonStateChanged(BUTTON_CROSS)
    binding.moonButtonView.buttonPressedCallback = buttonStateChanged(BUTTON_MOON)
    binding.pyramidButtonView.buttonPressedCallback = buttonStateChanged(BUTTON_PYRAMID)
    binding.boxButtonView.buttonPressedCallback = buttonStateChanged(BUTTON_BOX)
    
    // Shoulder buttons
    binding.l1ButtonView.buttonPressedCallback = buttonStateChanged(BUTTON_L1)
    binding.r1ButtonView.buttonPressedCallback = buttonStateChanged(BUTTON_R1)
    
    // Triggers (0-255 value)
    binding.l2ButtonView.buttonPressedCallback = { 
        ownControllerState = ownControllerState.copy().apply { 
            l2State = if(it) 255U else 0U 
        }
    }
    
    // Analog sticks
    binding.leftAnalogStickView.stateChangedCallback = { 
        ownControllerState = ownControllerState.copy().apply {
            leftX = (Short.MAX_VALUE * it.x).toInt().toShort()
            leftY = (Short.MAX_VALUE * it.y).toInt().toShort()
        }
    }
}
```

### D-pad Direction Handling

```kotlin
private fun dpadStateChanged(direction: DPadView.Direction?) {
    ownControllerState = ownControllerState.copy().apply {
        buttons = (buttons
            and BUTTON_DPAD_LEFT.inv()
            and BUTTON_DPAD_RIGHT.inv()
            and BUTTON_DPAD_UP.inv()
            and BUTTON_DPAD_DOWN.inv())
        or when(direction) {
            Direction.UP -> BUTTON_DPAD_UP
            Direction.DOWN -> BUTTON_DPAD_DOWN
            Direction.LEFT -> BUTTON_DPAD_LEFT
            Direction.RIGHT -> BUTTON_DPAD_RIGHT
            Direction.LEFT_UP -> BUTTON_DPAD_LEFT or BUTTON_DPAD_UP
            Direction.LEFT_DOWN -> BUTTON_DPAD_LEFT or BUTTON_DPAD_DOWN
            Direction.RIGHT_UP -> BUTTON_DPAD_RIGHT or BUTTON_DPAD_UP
            Direction.RIGHT_DOWN -> BUTTON_DPAD_RIGHT or BUTTON_DPAD_DOWN
            null -> 0U
        }
    }
}
```

### Button State Factory

```kotlin
private fun buttonStateChanged(buttonMask: UInt) = { pressed: Boolean ->
    ownControllerState = ownControllerState.copy().apply {
        buttons = if(pressed) 
            buttons or buttonMask 
        else 
            buttons and buttonMask.inv()
    }
}
```

---

## DPadView Direction Enum

```kotlin
enum class Direction {
    UP, DOWN, LEFT, RIGHT,
    LEFT_UP, LEFT_DOWN, RIGHT_UP, RIGHT_DOWN
}
```

---

## Analog Stick State

```kotlin
data class StickState(
    val x: Float,  // -1.0 to 1.0
    val y: Float   // -1.0 to 1.0
)
```

Converted to `Short` range (-32768 to 32767) for native session.

---

## Custom View Components

### ButtonView.kt (92 lines)

Simple button with pressed/released state and haptic feedback.

```kotlin
class ButtonView : View {
    var buttonPressed: Boolean = false
    var buttonPressedCallback: ((Boolean) -> Unit)? = null
    
    private val drawableIdle: Drawable?
    private val drawablePressed: Drawable?
    private val haptics = ButtonHaptics(context)
}
```

**Overlapping Button Handling**:
When buttons overlap in the layout, the one whose center is closest to the touch point handles it:

```kotlin
private fun bestFittingTouchView(x: Float, y: Float): View {
    return (parent as? ViewGroup)?.children
        ?.filter { it is ButtonView }
        ?.filter { /* touch point inside bounds */ }
        ?.sortedBy { /* distance to center */ }
        ?.firstOrNull() ?: this
}
```

---

### DPadView.kt (132 lines)

8-direction D-pad with angle-based direction detection.

```kotlin
class DPadView : View {
    enum class Direction {
        LEFT, RIGHT, UP, DOWN,
        LEFT_UP, RIGHT_UP, LEFT_DOWN, RIGHT_DOWN;
        
        val isDiagonal: Boolean
    }
    
    var state: Direction? = null
    var stateChangeCallback: ((Direction?) -> Unit)? = null
    
    private val deadzoneRadius = 0.3f  // 30% center deadzone
    private val haptics = ButtonHaptics(context)
}
```

**Direction Calculation** (8 sectors of 45° each):
```kotlin
private fun directionForPosition(position: Vector): Direction {
    val dir = (position / Vector(width, height) - 0.5f) * 2.0f
    val angleSection = PI * 2.0 / 8.0  // 45 degrees
    val angle = atan2(dir.x, dir.y) + PI + angleSection * 0.5
    
    return when {
        angle < 1 * angleSection -> Direction.UP
        angle < 2 * angleSection -> Direction.LEFT_UP
        angle < 3 * angleSection -> Direction.LEFT
        angle < 4 * angleSection -> Direction.LEFT_DOWN
        angle < 5 * angleSection -> Direction.DOWN
        angle < 6 * angleSection -> Direction.RIGHT_DOWN
        angle < 7 * angleSection -> Direction.RIGHT
        angle < 8 * angleSection -> Direction.RIGHT_UP
        else -> Direction.UP
    }
}
```

**Deadzone Logic**: Movement in center 30% radius is ignored while touching, but direction is returned on initial press.

---

### AnalogStickView (122 lines)
Circular touch area with normalized x/y output (-1 to +1).

```kotlin
class AnalogStickView : View {
    val radius: Float           // Max movement radius
    val handleRadius: Float     // Handle circle size
    
    var state = Vector(0f, 0f)  // Current normalized position
    var stateChangedCallback: ((Vector) -> Unit)? = null
    
    private var center: Vector? = null  // Center when touch started
    private var handlePosition: Vector  // Visual handle position
}
```

**Touch Logic:**
1. First touch sets the center point
2. Calculate direction vector from center to current position
3. Normalize to box coordinates (x & y independently from -1 to +1)
4. Scale by strength (clamped at radius)

```kotlin
private fun updateState(position: Vector?) {
    val dir = position - center
    val length = dir.length
    val strength = if(length > radius) 1.0f else length / radius
    val dirNormalized = dir / length
    
    // Box normalization for square output
    val dirBoxNormalized = if(abs(dirNormalized.x) > abs(dirNormalized.y))
        dirNormalized / abs(dirNormalized.x)
    else
        dirNormalized / abs(dirNormalized.y)
    
    state = dirBoxNormalized * strength
}
```

### TouchTracker Utility
Tracks touch position changes across touch events.

```kotlin
class TouchTracker {
    var positionChangedCallback: ((Vector?) -> Unit)? = null
    fun touchEvent(event: MotionEvent)
}
```

---

### ButtonHaptics.kt (29 lines)

Haptic feedback utility for touch controls.

```kotlin
class ButtonHaptics(val context: Context) {
    private val enabled = Preferences(context).buttonHapticEnabled
    
    fun trigger(harder: Boolean = false) {
        if(!enabled) return
        
        // Android 10+: EFFECT_CLICK or EFFECT_TICK
        // Android 8+: OneShot(10ms, amplitude)
        // Legacy: vibrate(10ms)
    }
}
```

---

### TouchpadOnlyFragment.kt (47 lines)

Simplified mode showing only the touchpad (no buttons/sticks).

```kotlin
class TouchpadOnlyFragment : TouchControlsFragment() {
    var touchpadOnlyEnabled: LiveData<Boolean>? = null
    
    // Merges own state with touchpadView.controllerState
}
```

---### TouchpadView.kt (168 lines)

DualSense touchpad emulation with multi-touch and gesture detection.

```kotlin
class TouchpadView : View {
    companion object {
        private const val BUTTON_PRESS_MAX_MOVE_DIST_DP = 32.0f
        private const val SHORT_BUTTON_PRESS_DURATION_MS = 200L
        private const val BUTTON_HOLD_DELAY_MS = 500L
    }
    
    private val state: ControllerState = ControllerState()
    val controllerState: Observable<ControllerState>
    
    inner class Touch(
        val stateId: UByte,  // Native touch ID (0 or 1)
        startX: Float, startY: Float
    ) {
        var lifted = false
        val moveInsignificant: Boolean  // Movement < 32dp
    }
    
    private val pointerTouches = mutableMapOf<Int, Touch>()
}
```

**Coordinate Mapping** (screen to PS5 touchpad):
```kotlin
private fun touchX(event: MotionEvent, index: Int): UShort =
    (TOUCHPAD_WIDTH * event.getX(index) / width).toUShort()  // 0-1919

private fun touchY(event: MotionEvent, index: Int): UShort =
    (TOUCHPAD_HEIGHT * event.getY(index) / height).toUShort()  // 0-941
```

**Gesture Detection:**
- **Tap**: Lift with minimal movement (< 32dp) → Short `BUTTON_TOUCHPAD` press (200ms)
- **Hold**: Stay pressed > 500ms with minimal movement → Sustained `BUTTON_TOUCHPAD`
- **Swipe**: Movement > 32dp → Touch position tracking only, no button

```kotlin
// On touch up
when {
    buttonHeld -> {
        // Release held button
        state.buttons = state.buttons and BUTTON_TOUCHPAD.inv()
    }
    it.moveInsignificant -> {
        // Trigger short button press (tap)
        triggerShortButtonPress(it)
    }
    else -> {
        // Just release touch, no button
        state.stopTouch(it.stateId)
    }
}
```

---

## Integration with StreamSession

```kotlin
// StreamActivity.kt
override fun onAttachFragment(fragment: Fragment) {
    if(fragment is TouchControlsFragment) {
        fragment.controllerState
            .subscribe { viewModel.input.touchControllerState = it }
    }
}
```

Touch controls merge with physical controller input in `StreamInput`:

```kotlin
// StreamInput.kt
val controllerState: ControllerState get() =
    sensorControllerState or keyControllerState or motionControllerState or touchControllerState
```

---

## visionOS Implementation Mapping

| Android Touch Controls | visionOS Equivalent |
|------------------------|---------------------|
| On-screen overlays | Not typically needed (GCController) |
| Touch D-pad | GCController.dpad |
| Touch buttons | GCController.buttonA, etc. |
| Touch analog stick | GCController.thumbstick |
| Touch touchpad | Hand tracking gestures (ARKit) |

### visionOS Controller Input Sources

1. **MFi Controller** - GCController API
2. **DualSense via Bluetooth** - GCController with extended profile
3. **Apple Watch** - Crown/Accelerometer for basic input
4. **Hand Tracking** - ARKit for gestures (limited)

### Example GCController Usage (visionOS)

```swift
class ControllerManager {
    var controllerState = ChiakiControllerState()
    
    func setupController(_ controller: GCController) {
        guard let extended = controller.extendedGamepad else { return }
        
        extended.buttonA.pressedChangedHandler = { _, _, pressed in
            self.controllerState.buttons = pressed 
                ? self.controllerState.buttons | BUTTON_CROSS 
                : self.controllerState.buttons & ~BUTTON_CROSS
            self.onStateChanged?()
        }
        
        extended.leftThumbstick.valueChangedHandler = { _, x, y in
            self.controllerState.leftX = Int16(x * Float(Int16.max))
            self.controllerState.leftY = Int16(y * Float(Int16.max))
            self.onStateChanged?()
        }
    }
}
```
