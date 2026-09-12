# Presentation timestamp probe

Standalone visionOS app for task 01.03. It links only system frameworks, with
no dependency on VisionRemotePS5, Chiaki, PSN, the decoder, or the metrics recorder.
It uses a separate bundle identifier and does not replace the streaming app.
Minimum visionOS remains 2.0; physical validation targets the installed 27 beta.

The first 20 seconds use the normal `MTKView` delegate path with
`currentRenderPassDescriptor`/`currentDrawable`. The view then switches to
`CAMetalLayer.nextDrawable()` on a serial queue, matching the streaming app's
acquisition pattern. The picker permits subsequent manual comparisons. Both
paths clear to the same smoothly changing color at a requested 60 Hz with
`presentsWithTransaction=false`, BGRA8, three drawables, and two GPU jobs maximum.
This is an endpoint availability diagnostic, not a performance benchmark.

Every presented callback increments bounded counters for zero, positive finite,
or invalid timestamps. Logs show the first three callbacks and every 60th one,
plus separate GPU completion information. Each renderer run has its own UUID;
late callbacks after a mode switch retain their original identity. UI counters
refresh once per second. GPU failures, missing drawables, and capacity skips are
retained separately in `ProbeStats`.

For frame 3 only, a drawable is retained for 100 ms after its callback, then
`presentedTime` is read again. This tests delayed property availability. The
recheck time is never substituted for the presentation endpoint. Retaining one
drawable briefly can affect the pool, so that interval is not a latency baseline.

## Run

Open `PresentationProbe.xcodeproj` in Xcode 27, select your signing team and the
physical Vision Pro, then run `PresentationProbe`. Alternatively:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project Diagnostics/PresentationProbe/PresentationProbe.xcodeproj \
  -scheme PresentationProbe -configuration Debug \
  -destination 'generic/platform=visionOS' \
  -derivedDataPath /tmp/VisionRemotePS5-presentation-probe \
  DEVELOPMENT_TEAM=YOUR_TEAM -allowProvisioningUpdates build
```

Stop the PS5 session before measuring to exclude its workload. Wear the headset,
keep the probe visible, and observe at least 20 seconds in each mode. Confirm
that the color changes smoothly in both. Collect `[PresentationProbe]` logs,
including `start`, `lateRead`, and counter lines. Device/OS and build results
belong in the report; simulator results do not establish device behavior.

If both modes return zero while visible animation is confirmed, record this
specific device/runtime reproduction. It does not prove a universal visionOS
limitation, nor that every sampled frame was displayed. Positive timestamps must
still be validated against a common host clock before any latency claim.

## Apple references

- [MTKView](https://developer.apple.com/documentation/metalkit/mtkview): standard drawable acquisition.
- [presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime): real host endpoint; zero when not presented/dropped.
- [presentsWithTransaction](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction): asynchronous mode versus transaction-specific presentation.
- [CAMetalLayer](https://developer.apple.com/documentation/quartzcore/cametallayer): retaining drawables briefly to query properties.
