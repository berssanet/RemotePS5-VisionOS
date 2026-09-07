# Input and transport host regressions — 2026-09-07

Task 00.07 passed all three existing harnesses, with no code or test changes.

## Environment and dependencies

- App revision: `059a71c`, branch `docs/active-streaming-paths`; working tree clean
  before the tests. That commit records tasks 00.04–00.06 and the curl include fix.
- Host: MacBook Pro `Mac15,7`, Apple M3 Pro, 36 GB RAM; macOS 26.6.2 (`25G83`).
- Toolchain: `/Applications/Xcode-beta.app`, Xcode 27.0 (`27A5252f`), macOS SDK 27.0.
- Local ignored Chiaki checkout: `25f89d386caf20de099040344ecf6b84342acb3e`.
  Its `controller.c`, `feedback.c`, `thread.c`, `time.c`, `base64.c`, `log.c`, and
  `lib/include` have no differences from that revision. Existing edits to
  `takion.c`, `videoreceiver.c`, and other unrelated local material were preserved
  and are not compiled by these harnesses.
- The feedback script exports `feedbacksender.c` from the pinned revision into
  a temporary directory and applies the repository's `feedback_sender.py` patch
  there. It does not edit or relink the shipped native archive.

## Commands and results

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_feedback_sender.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_socket_mode.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_psn_customdata.sh
```

All three ran in the sandbox and exited 0. No dependency acquisition or
unsandboxed retry was needed. The initial runs were concurrent; no timing
benchmark is inferred from them.

| Harness | Result and scope |
|---|---|
| Feedback sender | A simulated blocked sender did not block input updates; press/release ordering and two history sends preserved. Reported local update interval: 2 µs, below the harness's 100 ms guard against a simulated 500 ms stall. This is not controller-to-console latency. |
| Socket mode | Extracted the active `chiaki_socket_set_nonblock` implementation; enabling/disabling O_NONBLOCK preserved other flags, and an invalid descriptor returned an error. Uses a local socket pair, not a PS5 network session. |
| PSN customData1 | Accepted 16/17/18-byte decoded payload cases into a 16-byte output; rejected invalid inputs/capacities without corrupting output; checked redacted logs. AddressSanitizer and UndefinedBehaviorSanitizer enabled; no sanitizer findings reported. |

The PSN harness emitted one compiler warning at `chiaki-ng/lib/src/log.c:85`
for signed/unsigned comparison (`-Wsign-compare`). This unchanged dependency
source is built with the script's existing `-Wno-error=sign-compare`; no warning
policy was relaxed for this run. The same log includes Xcode FSEvents/cache
access diagnostics in the sandbox. They did not prevent compilation or tests.

## Evidence and limits

- `/tmp/VisionRemotePS5-0007-feedback.log`
- `/tmp/VisionRemotePS5-0007-socket.log`
- `/tmp/VisionRemotePS5-0007-customdata.log`
- PSN executable: ignored `build/psn-customdata-tests/psn-customdata-tests`.

`git diff --check` passed after recording the results. These tests exercise host
source harnesses, including patched feedback source, rather than running the
device's linked archive. They do not validate Bluetooth capture, rumble, PS5
connectivity, NAT traversal, or end-to-end latency on the Vision Pro. The next
roadmap task is 00.08, the dedicated Release build.
