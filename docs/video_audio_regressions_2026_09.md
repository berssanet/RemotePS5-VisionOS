# Video/audio host regressions — 2026-09-07

Task 00.06 passed all three existing harnesses with Xcode 27. These are host
functional checks, not Vision Pro playback or performance measurements.

## Environment and source

- MacBook Pro `Mac15,7`, Apple M3 Pro CPU/GPU, 36 GB memory.
- macOS 26.6.2 (`25G83`).
- Xcode 27.0 (`27A5252f`) at `/Applications/Xcode-beta.app`, macOS SDK 27.0.
- Branch `docs/active-streaming-paths`, HEAD
  `cc7e91164a37e6bc7319844148b13ce44e461490`.
- Pending changes from tasks 00.04/00.05 were preserved: documentation and curl
  header/build-path fix. Tested decoder, upscalers, ring buffer, scripts, and
  host harnesses were not modified in this task.

## Commands and results

Run from the project root:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_video_decoder.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_audio_buffer.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/test_video_gpu.sh
```

| Harness | Final exit | Verified coverage |
|---|---|---|
| `test_video_decoder.sh` | 0 | H.264 and HEVC dependent frames, reference preservation under loss/recovery metadata, bounded submission overflow and recovery, stop admission gate, Annex-B parsing |
| `test_audio_buffer.sh` | 0 | Seven-second producer stall simulation bounded to 200 ms, catch-up toward 40 ms, stereo alignment, concurrent wraparound, silence after reset |
| `test_video_gpu.sh` | 0 | MetalFX and Enhanced asynchronous encoding, shared-command-queue texture reuse, center and opposite-corner pixels |

The decoder harness extracts the active `StreamVideoDecoder` and
`ContinuationGate` source, generates encoded 64×64 frames through VideoToolbox,
and decodes both codecs. It deliberately saturates 12 CPU admission slots and
checks that one rejected submission does not destroy references or prevent
subsequent output. The expected queue-full diagnostic is not a test failure.

The audio harness exercises `AudioRingBuffer`, including 20,000 producer and
consumer iterations. It does not start AVAudioEngine or validate audible output.

The GPU harness compiles the actual upscalers, submits three constant-intensity
1920×1080 inputs per mode, and reads back 3840×2160 outputs after GPU completion.
Its pixel checks tolerate a difference of 3 intensity levels. It does not
exercise the MTKView presentation path, screen color fidelity, thermal behavior,
or sustained gameplay. CPU waits/readbacks are test-only operations.

## Sandbox failures and successful retries

The initial three harnesses were launched concurrently in the restricted
environment. Audio passed. Decoder initialization failed with VideoToolbox
status `-12908`; the GPU harness failed because `MTLCreateSystemDefaultDevice()`
returned nil. Both scripts exited 133 before their functional cases completed.

After approved retries outside the sandbox, decoder and GPU harnesses ran
sequentially and both passed unchanged. No assertions were removed, cases
skipped, or production code adjusted to obtain the passing results. Host
VideoToolbox/Metal service access was required in this environment.

Local evidence:

- `/tmp/VisionRemotePS5-0006-audio.log`: passing audio run.
- `/tmp/VisionRemotePS5-0006-decoder.log`: initial restricted failure.
- `/tmp/VisionRemotePS5-0006-gpu.log`: initial restricted failure.
- `/tmp/VisionRemotePS5-0006-decoder-unsandboxed.log`: passing H.264, HEVC, parser checks.
- `/tmp/VisionRemotePS5-0006-gpu-unsandboxed.log`: passing MetalFX and Enhanced checks.

`git diff --check` passed after recording the results. No new device session,
end-to-end latency measurement, or performance acceptance is claimed. Input and
transport regressions remain task 00.07.
