# PSN connection analysis

## customData1 decoding failure after PSN session creation

The latest device trace reaches `psn-awaiting-console`, then fails inside
`decode_customdata1`. The reported field is 32 characters, decodes to 24 bytes of
Base64 text, then to **17 binary bytes**. Its contents are intentionally not stored
here or in the regression fixtures.

The vendored `chiaki-ng/lib/src/remote/holepunch.c` decoder has two problems:

- It requires the second decode to produce exactly 16 bytes, rejecting this PSN
  response before control-hole negotiation.
- It reuses the first decode's length (24) as the capacity of the second decode's
  destination, even though `session->custom_data1` has only 16 bytes. The 17-byte
  result can overwrite the adjacent session field before returning `Unknown`.

`VisionRemotePS5/Chiaki/PSNCustomData.h` adapts the bounded two-buffer decoder found
in the newer Chiaki source snapshot available locally: decode into independent
temporary buffers, reject short/oversized results, then copy the first 16 bytes
used by `chiaki_rpcrypt_init_regist_psn`. The newer decoder allows up to four
trailing bytes; the existing 32-character wire field and 24-byte intermediate
buffer further limit this path to 16–18 decoded bytes. Invalid Base64 characters
and padding are rejected before calling the vendored decoder, including non-ASCII
bytes that are unsafe for its character lookup table.

`scripts/rebuild_holepunch_module.sh` applies this helper to a temporary copy of
the old source, removes the secret from the decode-failure log, and replaces only
`holepunch.c.o` in the shipped visionOS `libchiaki_full.a`. The vendored tree stays
untouched. The rebuilt archive is part of this correction; changing Swift alone
does not change this decoder. A successful extended-field decode now logs only:

```text
PSN customData1: decoded 17 bytes; using the 16-byte registration value
```

The streaming window now opens HoloPad only after `StreamingService.isStreaming`
becomes true, not merely after the startup function returns. A failed PSN setup
therefore no longer opens an unrelated hand-tracking space.

Validation:

- `bash scripts/test_psn_customdata.sh` uses the production helper and Chiaki
  Base64 implementation with AddressSanitizer/UndefinedBehaviorSanitizer. It covers
  synthetic 16/17/18-byte fields, unchanged output on rejection, invalid sizes,
  invalid characters/padding, non-ASCII input, and logs without secret values.
- Rebuilt the visionOS holepunch archive member. Verified that all other archive
  members except the regenerated symbol table retained their hashes.
- The app code compiles and links for visionOS with assets/shaders excluded.
  Full packaging is still blocked here by the missing Metal Toolchain and
  unavailable simulator asset services. Live PSN registration/streaming still
  requires a device test; passing this decoder does not prove later NAT stages.

## Continuous PSN streaming path

Account lookup and device-list HTTP 200 responses confirm PSN authentication, not a
Remote Play connection. A trace containing `[LocalConnection]` and a session to
port 9295 is the direct LAN path, even when PSN supplied the Account ID.

The Home screen's **Connect via PSN** action now passes a PSN device identity to
the streaming window. `StreamingService` starts Chiaki with `autoRegist: false`,
so registration and streaming share the same holepunch session. It does not run
the registration-only coordinator, tear down the negotiated sockets, then try
LAN TCP against the selected IP. OAuth tokens are obtained at connection time
and are not included in the Codable console/window value. The registration-only
path described in the historical analysis below is no longer the Home action.

**Connect locally** still uses this app's PIN registration and direct LAN wakeup.
Choosing this route explicitly clears any PSN transport selection on the returned
console without changing its saved keys. PSN connection failures are reported;
there is no silent fallback to LAN or PIN pairing.

To validate on hardware:

1. Confirm the existing LAN/PIN stream still works.
2. Close that stream, then use **Connect via PSN**. Expect
   `Starting PSN session (autoRegist=false, ...)`, `[ChiakiPSN]` stages, and
   finally `CONNECTED`, rather than a LAN WAKEUP/9295 probe.
3. Repeat from another network to exercise NAT traversal. HTTP 200 alone is not
   sufficient evidence of remote streaming success.
4. Close the streaming window while waiting for the console; retry after cleanup
   and verify that no native session remains busy.

`Server shutting down` after successful video/audio means the console ended the
stream; it is not an OAuth rejection. Hand-tracking authorization failures are a
separate visionOS permission issue. Do not publish registration keys or tokens
when sharing diagnostic logs.

## Same-LAN route

The user confirmed that the Vision Pro, Mac, and PS5 are on the same LAN and
provided the console's local IPv4 address. A direct DDP request to that address
from Python returned `HTTP/1.1 200 Ok`. This verifies local discovery from the
Mac, not registration or video streaming on the Vision Pro. The standalone
Swift discovery executable was refused by this session's network permissions
(`sendto: Operation not permitted`); its hardware test did not pass.

The home screen previously led with a generic PSN Connect button, which always
created a cloud session even for a local console. The new **Local Network**
panel provides an explicit direct-IP path instead:

- Discover the selected IP using unicast DDP, so broadcast discovery is not
  required. Retry an access-refused probe once after a short pause for the Local
  Network permission prompt. Do not fall back to PSN if local discovery fails.
- Reuse this app's registration only when the discovered MAC and console family
  match, the RP key and Account ID lengths are valid, the registration key has
  the format accepted by the streaming pipeline, and any currently signed-in
  account matches. Retain the saved console identity but use the discovered IP
  for this connection. Stored IP metadata is not rewritten by discovery.
- Existing registered consoles can reconnect without a PSN token. A registered
  standby console uses the existing streaming wake-up path.
- Without usable keys, open local PIN pairing with the discovered console
  metadata and IP. Prefill the current signed-in Account ID, and reject missing
  or malformed IDs instead of submitting an all-zero identity.
- Remember the local address per installation, not as a hardcoded project IP.
- Prevent simultaneous local preparation and PSN registration in the home UI.
  Cancel pending local checks when leaving the panel.
- Clearly label the old action **Try PSN registration** and remove the promise
  that PSN sign-in always creates a usable registration without a PIN.

This is a local route around the failing cloud-registration step, not a claim
that the PSN timeout or internet transport has been fixed. The app cannot import
the official client's registration implicitly. First-time local pairing requires
the PS5 Link Device PIN; it should be entered in the app, never shared here.

Local PIN/key/registration-response dumps were removed from the exercised
registration and streaming services. Native LAN logging no longer enables raw
verbose/debug payloads; the ABI diagnostics are unchanged.

Validation includes 16 new offline LAN tests alongside the 14 PSN regressions:
identity matching, moved IPs, account mismatch, invalid keys, first pairing,
offline reconnect with saved keys, standby, unreachable/invalid addresses, and
cancellation. Full app packaging remains blocked by the session's unavailable
Metal toolchain and simulator services. No first-time PIN registration or live
stream was performed on the user's console by this agent.

## Follow-up: session creation succeeds, console connection still unverified

The next device log ends during network-offer preparation. It does not contain
the final timeout or an acknowledgement from the console. Authentication and
device listing continue to return HTTP 200.

Additional read-only checks performed from this Mac:

- A standard UDP DDP search received `HTTP/1.1 200 Ok` from a PS5 with the same
  advertised name as the previously reported console. The response advertised
  system version `13600007`, discovery protocol `00030010`, and request port 997.
  This establishes local discoverability from the Mac, not PSN command delivery
  or reachability from the Vision Pro.
- Process enumeration succeeded and did not find the official RemotePlay
  executable running on this Mac. This does not exclude a client on another device.
- The native call order matches the vendored GUI's
  `StreamSession::ConnectPsnConnection`. No sequence change is justified by that
  comparison.
- The IPv6 message is emitted because `ENABLE_IPV6` is false in the vendored
  implementation. It is not a detected incompatibility of this particular PS5.

The previous log-level reduction hid the command-acceptance milestone along with
sensitive payloads. This follow-up fixes that diagnostic regression:

- The PSN-specific log callback consumes verbose messages without printing them.
  It recognizes the library's `DATA_SENT` state and emits only the constant
  `psn-awaiting-console` milestone. Deleted sessions and console-joined states
  are excluded. Raw JSON, command IDs, tokens, and connection secrets are not
  forwarded by this verbose path.
- The native wrapper emits stage transitions around session creation, offer
  preparation, command sending, control negotiation, and registration.
- The coordinator displays these stages rather than leaving the UI on a generic
  waking/registration message. The overall timeout includes the last UI stage.
- The misleading IPv6 line is replaced with an explanation that this build uses
  IPv4. Neither TLS validation nor network requirements were bypassed.

Validation: all Swift app sources passed visionOS type-checking, the C bridge
passed syntax checking, and the offline Swift regression suite passed 14 tests.
The standalone C diagnostic test passed nine checks, including raw-payload
rejection, using:

```sh
xcrun clang -std=c11 -Wall -Wextra -Werror \
  VisionRemotePS5Tests/PSNConnectionDiagnosticsTests.c \
  -o build/psn-connection-diagnostics-tests
./build/psn-connection-diagnostics-tests
```

These are diagnostic changes, not a verified fix for console joining. No live
PSN credentials were used and no signed-device connection was established in
this session. The remaining distinction is whether the official app currently
connects only over LAN or also through PSN from another network.

## Runtime findings and corrective patch

The subsequently supplied device log establishes the failing stage:

- The initial refresh requests received HTTP 400, `invalid_scope` (4153).
- A fresh sign-in subsequently succeeded, as did Account ID resolution and
  console listing. The console advertises `device.enabledFeatures: ["remotePlay"]`.
- The push WebSocket connected, a PSN session was created, and the client's
  membership was confirmed. STUN also returned responses.
- The Remote Play command returned a `commandId`, but no console membership or
  custom-data notification followed. Chiaki returned `CHIAKI_ERR_HOST_DOWN`
  after waiting for session-start notifications.

The observed final failure is **before registration and streaming**, not the
direct-IP handoff discussed in the initial analysis below. It is not evidence
of an incorrect password, missing CA bundle, or Remote Play being disabled.
A command ID acknowledges command acceptance, not successful console execution.
The log does not establish why the console did not join.

Changes made in response:

- Both token grants now send explicit Remote Play scopes and the redirect URI,
  with HTTP Basic client authentication, matching
  `chiaki-ng/gui/src/psntoken.cpp:18-30`. Form keys and values are percent-encoded.
- OAuth errors retain their actionable category without logging response bodies.
  Concurrent refresh callers share an in-flight task; transient failures no
  longer delete credentials. A rejected grant/client still requires sign-in.
- `PSNSessionManager` no longer constructs a second authentication service on
  startup. Callers inject the app's service.
- Profiles come from the authoritative token-info endpoint rather than treating
  arbitrary JWT subjects as registration Account IDs. PSN registration does not
  fall back to a manually saved ID from a different account.
- Device decoding handles the actual nested `device` object and root `platform`,
  while retaining compatibility with the older flat shape.
- Native startup errors are preserved. Only `CHIAKI_ERR_HOST_DOWN` triggers the
  bounded second attempt; TLS/HTTP/other failures are not reported as a console
  that failed to join. The second attempt obtains a current access token.
- PSN native logging excludes verbose/debug payloads. OAuth token bodies and
  the Swift session manager's token prefix are no longer printed.

Validation for this patch:

- 13 offline XCTest regressions passed using the production protocol types and
  the `PSNProtocolRegressionTests` class in a temporary macOS harness. These cover
  scope/redirect fields, form encoding, Basic authentication placement, safe error
  categories, nested/legacy devices, and the console-timeout message.
- All app Swift sources passed a visionOS type-check using the Xcode-generated
  source list and the project's bridging header. The modified C bridge passed
  Clang syntax checking with the Xcode-generated compilation arguments.
- Full `xcodebuild` packaging was attempted but blocked in this session by the
  unavailable Metal toolchain and inaccessible simulator services required by
  asset compilation. A signed build and console connection were not validated.

The earlier official-app comparison also found additional startup-payload fields
(`protocolVer`, `supportCmd`, `data3`) in the installed app's string templates.
Their presence alone does not establish their runtime values or whether the
console requires them. No guessed protocol values were inserted, and the
vendored source and prebuilt library were left unchanged by this patch.

Before the next device test, revoke the exposed PSN tokens through the account's
session/security controls and sign in again. Local Sign Out clears this app's
copies; it is not a server-side token revocation. Test first with the PS5 fully
on, signed into the same account, and other Remote Play clients disconnected.
If console joining still fails, compare the official app from a different
network: a successful LAN connection does not validate PSN wake/session delivery.

## Initial analysis: scope and confidence

Analysis of the working tree, including existing uncommitted changes, compared
with the installed `/Applications/RemotePlay.app` version 9.0.0. The official app
was inspected read-only through bundle metadata and executable strings; this is
not a network trace or access to Sony's source code.

No real account sign-in, console wake-up, or streaming session was initiated.
Consequently, the exact stage of the user's failed attempt is not established.
The findings below distinguish reproducible defects from compatibility questions.
No production code, credentials, or installed application was changed.

## Main finding: PSN registration is followed by a direct-IP connection

The active home-screen flow is:

1. `HomeView` presents `PSNConsolesSection`.
2. The section calls `PSNRemotePlayCoordinator.registerViaPSN`.
3. The coordinator calls `ChiakiFullSession.startPSN` with `autoRegist: true`.
4. After the registration event, `finish` calls `session.teardown()`.
5. Registration keys and the selected IP are stored in a `Console`.
6. `HomeView` starts streaming; `StreamingService.startStreamingV2` calls
   `ChiakiFullSession.shared.start(host: ...)`, not `startPSN`.

References:

- `VisionRemotePS5/Views/HomeView.swift:34`
- `VisionRemotePS5/Services/PSNRemotePlayCoordinator.swift:141`
- `VisionRemotePS5/Services/PSNRemotePlayCoordinator.swift:175`
- `VisionRemotePS5/Services/StreamingService.swift:306`

**Confirmed architectural limitation:** the streaming step does not retain or
reestablish the PSN-negotiated transport. Registration keys and an IP address do
not preserve its sockets, selected ports, or NAT traversal state. A directly
reachable console can work, but internet connectivity cannot rely on the PSN
holepunch performed by the registration step. This explains a failure after
successful registration when direct access is unavailable; it does not explain
a rejection on Sony's login page.

The bridge already exposes a PSN start with `autoRegist: false`, and its C wrapper
passes the holepunch session to Chiaki. Completing this integration requires
coordinating streaming callbacks, session ownership, cancellation, and console
identity persistence, not merely changing that Boolean in the coordinator.

## OAuth and account identity

### Confirmed form-encoding defect

`PSNAuthService.swift:224` declares an
`application/x-www-form-urlencoded` request, but `urlEncodedString` at line 554
only concatenates keys and values. It does not escape either.

An isolated Swift probe using the actual extension reproduced a failed round
trip for the synthetic code `example+code&part=two%25`. A form decoder interprets
`+` as a space, `&` as a field separator, and percent escapes as encoded bytes.
This can corrupt authorization codes or refresh tokens containing these
characters. It is a conditional failure, not evidence that the user's current
token contains them. The configured client ID and secret did not contain
characters requiring escaping in the configuration inspected.

### Confirmed inconsistency in Account ID representation

`PSNAuthService.swift:394` copies JWT `sub` or `account_id` directly into
`PSNUserProfile.accountId`. In contrast, the token-info API path converts a
numeric `user_id` to eight little-endian bytes encoded as Base64, which is the
format expected by registration.

For example, the synthetic decimal subject `1234567890123456`, interpreted as
Base64, produces 12 bytes rather than 8. The JWT shortcut skips the API fallback
once it obtains any subject. The coordinator can recover by reloading the
profile, but can also choose a stale manually stored Account ID before doing so.
This is not proof that PSN issued a JWT with those claims in the failed attempt.

### Sign-in success is not connection readiness

`exchangeCodeForToken` sets `isAuthenticated` before loading the profile, and
`loadUserProfile` logs rather than propagates profile-fetch errors. A signed-in
screen therefore does not establish that an Account ID is usable, a push
WebSocket is authorized, the console joined a session, or streaming connected.

### Differences requiring live validation, not automatic replacement

| Item | Project | Installed official app evidence |
| --- | --- | --- |
| Authorization endpoint | `auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize` | Contains `account.sony.com/api/v1/oauth/authorize` |
| Token endpoint | `auth.api.sonyentertainmentnetwork.com/2.0/oauth/token` | Same endpoint string present |
| Redirect | `https://remoteplay.dl.playstation.net/remoteplay/redirect` | Same redirect string present |
| Permissions | Four Remote Play-related scopes | Contains those four plus `sbahn:pc.telemetry.publish` |
| Login handoff | Browser link and manually pasted redirect | Static inspection does not establish the official callback implementation |

The different authorization endpoint deserves investigation if failure occurs
in the browser. Strings alone do not prove that the project's endpoint has been
disabled or that changing endpoints will be compatible with its OAuth client.
There is no evidence that the additional telemetry scope is required to stream.

The vendored Chiaki GUI uses HTTP Basic client authentication for token
requests; the Swift implementation sends client credentials in the form body.
This is a protocol difference to validate against the actual server error, not
proof that form-body client authentication is rejected.

The project already includes `duid` in its login URL. However, the local
`psn_token_duid_bound` Boolean is set after every successful code exchange; it
does not verify the origin or DUID binding of a manually supplied code.

## Older connection path is not the active home-screen path

`PSNConnectionView.connectToDevice` uses the Swift session/WebSocket/holepunch
services and still ends with `TODO: Start streaming session`. Its UDP holepunch
implementation treats local `NWConnection.ready` as success without establishing
that the console accepted a Remote Play session.

This path must not be treated as an implementation equivalent to the official
app. However, the current home screen uses the newer coordinator, so this TODO
alone is not the explanation for a failure through the home-screen Connect button.

## Existing fixes/configuration that were verified

- A device build completed successfully with Xcode 26.6:
  `xcodebuild build -scheme VisionRemotePS5 -destination 'generic/platform=visionOS' -quiet CODE_SIGNING_ALLOWED=NO`.
  Exit status was 0; the captured build output contained no warnings or errors.
- Both OAuth configuration values were nonempty and resolved in the built
  `Info.plist`. Their server-side validity was not tested, and their values were
  not printed or copied into this report.
- `cacert.pem` was present in the built app.
- `nm` confirmed real holepunch session symbols in `libchiaki_full.a`, and that
  its `holepunch.c.o` references `chiaki_visionos_curl_easy_init`.
- `startPSN` installs the CA bundle before starting the C session. Missing CA
  wiring and missing holepunch stubs are therefore not supported as current
  explanations; certificate validity and server reachability remain untested.
- `xcodebuild -showdestinations` exposed device destinations only, with no
  available visionOS simulator destination. The vendored XCFramework contains
  only the arm64 device variant. The XCTest suite was not executed on hardware.
- The existing authentication tests use the real service, Keychain, and network
  rather than isolated OAuth responses. They are not end-to-end evidence that
  PSN login or streaming works.

## Safe diagnosis and correction order

1. Record the failing stage and HTTP status or Chiaki error: browser login,
   token exchange, Account ID resolution, device listing, push connection,
   session creation/start, control holepunch, registration, or streaming.
2. Fix form serialization and test reserved characters. Validate pasted redirect
   URLs and OAuth errors before attempting token exchange.
3. Normalize account identity to the registration format and prevent stale
   Account IDs from being reused across signed-in accounts.
4. Connect the streaming pipeline to a live PSN transport instead of silently
   falling back to direct-IP transport after registration.
5. Validate LAN and separate-network scenarios independently. Console Remote
   Play settings and another active client are checks, not conclusions derived
   solely from a generic timeout.

Before collecting or sharing logs, remove sensitive payload logging:
`PSNAuthService.swift:238` logs the token response, and
`StreamingService.swift:302` logs registration and RP keys. Diagnostics should
contain stage, status, and sanitized server error codes, not token bodies,
authorization headers, pasted redirects, or pairing keys.

**Conclusion:** correct PSN account credentials are necessary but not sufficient.
The current implementation has reproducible OAuth/identity defects and an
incomplete handoff from PSN registration to internet streaming. A sanitized
runtime error is still needed to identify which one blocks the specific attempt.
