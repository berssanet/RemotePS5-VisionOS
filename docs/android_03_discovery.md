# Android Chiaki-ng: Discovery Service Documentation

> **Package**: `com.metallic.chiaki.discovery`  
> **File**: `DiscoveryManager.kt`  
> **Purpose**: PS4/PS5 console discovery via UDP broadcast

---

## DiscoveryManager.kt (130 lines)

Kotlin wrapper around the native `DiscoveryService` with RxJava reactive streams.

### Class Definition

```kotlin
class DiscoveryManager
```

---

## MainViewModel.kt (66 lines)

Coordinates discovery with database to create unified host list.

```kotlin
class MainViewModel(val database: AppDatabase, val preferences: Preferences): ViewModel() {
    val discoveryManager = DiscoveryManager()
    
    // Combines discovered + manual + registered hosts
    val displayHosts: LiveData<List<DisplayHost>> = combineLatest(
        database.manualHostDao().getAll(),
        database.registeredHostDao().getAll(),
        discoveryManager.discoveredHosts
    ) { manualHosts, registeredHosts, discoveredHosts ->
        val macRegisteredHosts = registeredHosts.associateBy { it.serverMac }
        
        // Map discovered hosts with their registration
        discoveredHosts.map { DiscoveredDisplayHost(macRegisteredHosts[it.serverMac], it) } +
        // Add manual hosts
        manualHosts.map { ManualDisplayHost(idRegisteredHosts[it.registeredHost], it) }
    }
    
    val discoveryActive: LiveData<Boolean>
    
    fun deleteManualHost(manualHost: ManualHost) { ... }
}
```

**Key Pattern**: RxJava `combineLatest` merges 3 streams (manual hosts, registered hosts, discovered hosts) into unified `DisplayHost` list for UI.

### Constants

```kotlin
companion object {
    const val HOSTS_MAX: ULong = 16U     // Max tracked consoles
    const val DROP_PINGS: ULong = 3U     // Pings before host dropped
    const val PING_MS: ULong = 500U      // Ping interval (ms)
    const val PORT = 987                 // UDP discovery port
    const val DEBOUNCE_EMPTY_MS = 1000L  // Debounce for empty list
}
```

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `discoveryService` | `DiscoveryService?` | Native service, null when inactive |
| `discoveryActive` | `Observable<Boolean>` | Whether discovery is running |
| `active` | `Boolean` | User-controlled active state |
| `discoveredHosts` | `Observable<List<DiscoveryHost>>` | Discovered consoles (debounced) |

### State Management

```kotlin
var active = false
    set(value) {
        field = value
        discoveryActiveSubject.onNext(value)
        updateService()
    }
```

Setting `active = true` starts discovery; `active = false` stops it.

### Lifecycle Methods

#### `resume()`
```kotlin
fun resume() {
    paused = false
    updateService()
}
```

#### `pause()`
```kotlin
fun pause() {
    paused = true
    updateService()
}
```

#### `dispose()`
```kotlin
fun dispose() {
    active = false
    disposable.dispose()
}
```

### Service Control

```kotlin
private fun updateService() {
    if(active && !paused && discoveryService == null) {
        // Start discovery
        discoveryService = DiscoveryService(
            DiscoveryServiceOptions(
                HOSTS_MAX, DROP_PINGS, PING_MS,
                InetSocketAddress("255.255.255.255", PORT)
            ),
            discoveredHostsSubjectRaw::onNext
        )
    }
    else if((!active || paused) && discoveryService != null) {
        // Stop discovery
        discoveryService?.dispose()
        discoveryService = null
    }
}
```

### Wake-on-LAN

```kotlin
fun sendWakeup(host: String, registKey: ByteArray, ps5: Boolean) {
    // Convert registKey to hex credential
    val registKeyString = registKey.toString(StandardCharsets.UTF_8)
    val credential = registKeyString.toULong(16)
    DiscoveryService.wakeup(discoveryService, host, credential, ps5)
}
```

### Debouncing

Empty host lists are debounced by 1000ms to prevent UI flicker:

```kotlin
discoveredHostsSubjectRaw
    .debounce { hosts ->
        if(hosts.isEmpty())
            Observable.timer(DEBOUNCE_EMPTY_MS, TimeUnit.MILLISECONDS)
        else
            Observable.empty()
    }
    .subscribe { hosts ->
        discoveredHostsSubjectDebounced.onNext(hosts)
    }
```

---

## DiscoveryHost Extension

```kotlin
val DiscoveryHost.serverMac: MacAddress? get() = 
    this.hostId?.hexToByteArray()?.let {
        if(it.size == MacAddress.LENGTH) MacAddress(it) else null
    }
```

---

## Discovery Protocol Details

### UDP Broadcast
- **Port**: 987
- **Address**: 255.255.255.255 (subnet broadcast)
- **Ping Interval**: 500ms
- **Timeout**: 3 missed pings = host offline

### DiscoveryHost Properties

From native `DiscoveryHost` (see `Chiaki.kt`):

```kotlin
data class DiscoveryHost(
    val state: State,                    // UNKNOWN, READY, STANDBY
    val hostRequestPort: UShort,         // Port for connection
    val hostAddr: String?,               // IP address
    val systemVersion: String?,          // Firmware version
    val deviceDiscoveryProtocolVersion: String?,  // "00030010" = PS5
    val hostName: String?,               // Console name
    val hostType: String?,               // Device type
    val hostId: String?,                 // MAC address (hex)
    val runningAppTitleid: String?,      // Current game ID
    val runningAppName: String?          // Current game name
) {
    val isPS5: Boolean get() = deviceDiscoveryProtocolVersion == "00030010"
}
```

### Host States

```kotlin
enum class State {
    UNKNOWN,   // No response received
    READY,     // Console is on and ready
    STANDBY    // Console is in rest mode
}
```

---

## visionOS Implementation Mapping

| Android | visionOS Equivalent |
|---------|---------------------|
| `DiscoveryService` | `ConsoleDiscoveryService.swift` |
| RxJava `Observable` | Combine `Publisher` |
| `BehaviorSubject` | `CurrentValueSubject` or `@Published` |
| `255.255.255.255` broadcast | Same, but requires local network permission |
| `NetService`/`NWBrowser` | Alternative for Bonjour (not used by Chiaki) |

### Key visionOS Considerations

1. **Local Network Permission** - Must request `NSLocalNetworkUsageDescription` entitlement
2. **UDP Socket** - Use `NWConnection` with UDP datagram protocol
3. **Broadcast** - visionOS supports UDP broadcast on LAN
4. **Background Discovery** - May be limited by visionOS power management
