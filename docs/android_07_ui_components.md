# Android Chiaki-ng: UI Components & Activities

> **Package**: `com.metallic.chiaki.stream`  
> **Files**: `StreamActivity.kt`, `StreamViewModel.kt`, `AspectRatioFrameLayout.kt`  
> **Purpose**: Main streaming UI and activity lifecycle

---

## StreamActivity.kt (399 lines)

Main streaming screen activity.

### Class Definition

```kotlin
class StreamActivity : AppCompatActivity(), View.OnSystemUiVisibilityChangeListener
```

### Intent Extra

```kotlin
companion object {
    const val EXTRA_CONNECT_INFO = "connect_info"  // ConnectInfo parcelable
    private const val HIDE_UI_TIMEOUT_MS = 2000L
}
```

### Initialization

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    val connectInfo = intent.getParcelableExtra<ConnectInfo>(EXTRA_CONNECT_INFO)
    
    viewModel = ViewModelProvider(this, viewModelFactory {
        StreamViewModel(application, connectInfo)
    })[StreamViewModel::class.java]
    
    viewModel.input.observe(this)
    
    binding = ActivityStreamBinding.inflate(layoutInflater)
    setContentView(binding.root)
    
    viewModel.session.attachToSurfaceView(binding.surfaceView)
    viewModel.session.state.observe(this, Observer { stateChanged(it) })
}
```

### Lifecycle Management

```kotlin
override fun onResume() {
    super.onResume()
    hideSystemUI()
    viewModel.session.resume()
}

override fun onPause() {
    super.onPause()
    viewModel.session.pause()
}
```

### State Handling

```kotlin
private fun stateChanged(state: StreamState) {
    binding.progressBar.visibility = 
        if(state == StreamStateConnecting) View.VISIBLE else View.GONE

    when(state) {
        is StreamStateQuit -> {
            if(state.reason.isError) {
                // Show reconnect/quit dialog
            } else {
                finish()
            }
        }
        is StreamStateCreateError -> {
            // Show error dialog
        }
        is StreamStateLoginPinRequest -> {
            // Show PIN input dialog
        }
    }
}
```

### Controller Input Dispatch

```kotlin
override fun dispatchKeyEvent(event: KeyEvent) = 
    viewModel.input.dispatchKeyEvent(event) || super.dispatchKeyEvent(event)

override fun onGenericMotionEvent(event: MotionEvent) = 
    viewModel.input.onGenericMotionEvent(event) || super.onGenericMotionEvent(event)
```

### Rumble Feedback

```kotlin
if(Preferences(this).rumbleEnabled) {
    val vibrator = getSystemService(VIBRATOR_SERVICE) as Vibrator
    viewModel.session.rumbleState.observe(this, Observer {
        val amplitude = min(255, (it.left.toInt() + it.right.toInt()) / 2)
        vibrator.cancel()
        if(amplitude > 0) {
            if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                vibrator.vibrate(VibrationEffect.createOneShot(1000, amplitude))
            else
                vibrator.vibrate(1000)
        }
    })
}
```

### Full-screen Immersive Mode

```kotlin
private fun hideSystemUI() {
    window.decorView.systemUiVisibility = (
        View.SYSTEM_UI_FLAG_IMMERSIVE
        or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
        or View.SYSTEM_UI_FLAG_FULLSCREEN
    )
}
```

### Overlay Animation

```kotlin
private fun showOverlay() {
    binding.overlay.isVisible = true
    binding.overlay.animate().alpha(1.0f)
    uiVisibilityHandler.postDelayed(hideSystemUIRunnable, HIDE_UI_TIMEOUT_MS)
}

private fun hideOverlay() {
    binding.overlay.animate().alpha(0.0f).setListener(object {
        override fun onAnimationEnd(animation: Animator?) {
            binding.overlay.isGone = true
        }
    })
}
```

---

## AspectRatioFrameLayout.kt (69 lines)

Custom FrameLayout that maintains video aspect ratio.

```kotlin
class AspectRatioFrameLayout : FrameLayout {
    var aspectRatio: Float = 0f      // w/h, e.g., 16/9 = 1.77
    var mode: TransformMode = FIT
    
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        // Adjusts width/height based on mode:
        // FIT: letterbox (shrink to fit)
        // ZOOM: crop to fill (expand to cover)
        // STRETCH: ignore aspect ratio
    }
}
```

---

## Display Transform Modes

```kotlin
enum class TransformMode {
    FIT,     // Letterbox to maintain aspect ratio
    STRETCH, // Fill screen, may distort
    ZOOM     // Crop to fill, maintains aspect ratio
}
```

### Aspect Ratio Calculation

```kotlin
private fun adjustSurfaceViewAspect() {
    val videoProfile = viewModel.session.connectInfo.videoProfile
    binding.aspectRatioLayout.aspectRatio = 
        videoProfile.width.toFloat() / videoProfile.height.toFloat()
    binding.aspectRatioLayout.mode = TransformMode.fromButton(binding.displayModeToggle.checkedButtonId)
}
```

---

## PIN Input Dialog

```kotlin
is StreamStateLoginPinRequest -> {
    val view = layoutInflater.inflate(R.layout.dialog_login_pin, null)
    val pinEditText = view.findViewById<EditText>(R.id.pinEditText)
    
    MaterialAlertDialogBuilder(this)
        .setMessage(if(state.pinIncorrect) 
            R.string.alert_message_login_pin_request_incorrect
        else 
            R.string.alert_message_login_pin_request)
        .setView(view)
        .setPositiveButton(R.string.action_login_pin_connect) { _, _ ->
            viewModel.session.setLoginPin(pinEditText.text.toString())
        }
        .show()
}
```

---

## MainActivity.kt (241 lines)

Main screen showing host list with discovery, wakeup, and navigation.

### Core Methods

| Method | Description |
|--------|-------------|
| `hostTriggered(host)` | Connect to registered host, or show registration for unregistered |
| `wakeupHost(host)` | Send Wake-on-LAN packet via DiscoveryManager |
| `addManualConsole()` | Navigate to EditManualConsoleActivity |
| `showRegistration()` | Navigate to RegistActivity |
| `deleteHost(host)` | Delete manual host with confirmation dialog |

### Connection Logic

```kotlin
private fun hostTriggered(host: DisplayHost) {
    val registeredHost = host.registeredHost
    if(registeredHost != null) {
        // Create ConnectInfo and start StreamActivity
        val connectInfo = ConnectInfo(
            host.isPS5, host.host,
            registeredHost.rpRegistKey, registeredHost.rpKey,
            Preferences(this).videoProfile
        )
        startActivity(StreamActivity with connectInfo)
    } else {
        // Not registered, show RegistActivity
        startActivity(RegistActivity with host.host)
    }
}
```

### Standby Wake Dialog

When host is in STANDBY state:
- "Wake Up" → Send WoL, don't connect
- "Connect Immediately" → Connect without wake (may fail)
- "Cancel" → Do nothing

---

## EditManualConsoleActivity.kt (104 lines)

UI for adding/editing manual host entries.

```kotlin
class EditManualConsoleActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_MANUAL_HOST_ID = "manual_host_id"  // For editing existing
    }
    
    // Allows linking to existing registration by MAC
    val selectedRegisteredHost: LiveData<RegisteredHost?>
    
    private fun saveHost() {
        val host = binding.hostEditText.text.toString().trim()
        viewModel.saveHost(host)  // Insert or update
    }
}
```

**Feature**: When adding a manual host, user can optionally link it to an existing registration. This allows connecting without re-registering.

---

## EditManualConsoleViewModel.kt (60 lines)

ViewModel for manual host CRUD operations.

```kotlin
class EditManualConsoleViewModel(
    val database: AppDatabase, 
    manualHostId: Long?  // null = create new, non-null = edit existing
): ViewModel() {
    // All registered hosts (for dropdown selection)
    val registeredHosts: LiveData<List<RegisteredHost?>>
    
    // Existing host being edited (if manualHostId provided)
    val existingHost: LiveData<ManualHost>?
    
    // Currently selected registration to link
    var selectedRegisteredHost = MutableLiveData<RegisteredHost?>(null)
    
    fun saveHost(host: String): Completable {
        val registeredHost = selectedRegisteredHost.value?.id
        val existing = existingHost?.value
        
        return if(existing != null) {
            // Update existing
            dao.update(ManualHost(id = existing.id, host = host, registeredHost = registeredHost))
        } else {
            // Insert new
            dao.insert(ManualHost(host = host, registeredHost = registeredHost))
        }
    }
}
```

---

## DisplayHostRecyclerViewAdapter.kt (124 lines)

RecyclerView adapter for the main host list with DiffUtil.

```kotlin
class DisplayHostRecyclerViewAdapter(
    val clickCallback: (DisplayHost) -> Unit,
    val wakeupCallback: (DisplayHost) -> Unit,
    val editCallback: (DisplayHost) -> Unit,
    val deleteCallback: (DisplayHost) -> Unit
): RecyclerView.Adapter<...>() {
    var hosts: List<DisplayHost> = listOf()
        set(value) {
            val diff = DiffUtil.calculateDiff(DisplayHostDiffCallback(field, value))
            field = value
            diff.dispatchUpdatesTo(this)
        }
}
```

#### Cell Display Logic

```kotlin
// Console state icons
when(host.discoveredHost.state) {
    State.STANDBY -> R.drawable.ic_console_ps5_standby
    State.READY -> R.drawable.ic_console_ps5_ready
    else -> R.drawable.ic_console_ps5
}

// Running app display
if(discoveredHost.runningAppName != null)
    "Playing: ${discoveredHost.runningAppName} (${discoveredHost.runningAppTitleid})"
```

#### Popup Menu Actions

- **Wakeup**: Available if host is registered
- **Edit/Delete**: Available only for ManualDisplayHost

---

## RegistExecuteActivity.kt (131 lines)

Shows registration progress with live log output.

```kotlin
class RegistExecuteActivity : AppCompatActivity() {
    companion object {
        const val EXTRA_REGIST_INFO = "regist_info"
        const val EXTRA_ASSIGN_MANUAL_HOST_ID = "assign_manual_host_id"
        const val RESULT_FAILED = Activity.RESULT_FIRST_USER
    }
}
```

#### Live Log Display

```kotlin
viewModel.logText.observe(this) { logText ->
    binding.logTextView.text = logText
    // Auto-scroll to bottom
    val scrollY = layout.getLineBottom(lineCount - 1) - height
    binding.logTextView.scrollTo(0, max(scrollY, 0))
}
```

#### Duplicate Host Dialog

When registering an already-registered MAC:
- "Discard" → Don't save
- "Overwrite" → Replace existing registration

---

## visionOS Implementation Mapping

| Android | visionOS Equivalent |
|---------|---------------------|
| `Activity` | `View` / `Window` |
| `SurfaceView` | Metal view with VideoToolbox |
| `View.SYSTEM_UI_FLAG_*` | `.persistentSystemOverlays()` |
| `LiveData<StreamState>` | `@Published var state: StreamState` |
| `MaterialAlertDialogBuilder` | SwiftUI `.alert()` |
| `Vibrator` | `CoreHaptics` |
| `KeyEvent` / `MotionEvent` | `GCController` |

### visionOS Considerations

1. **No fullscreen mode** - visionOS uses windowed/immersive space instead
2. **System UI** - Cannot be hidden; work with system chrome
3. **Haptics** - Use CoreHaptics for rumble feedback
4. **Video Surface** - Use `AVSampleBufferDisplayLayer` or Metal
5. **PIN Dialog** - SwiftUI `.alert()` with TextField
