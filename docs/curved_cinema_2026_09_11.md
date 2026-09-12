# Curved cinema — 2026-09-11

The user requested a curved cinema screen covering the player's field of view.
The former 4×2.25 m flat plane at a fixed floor height is replaced with the inside
of a spherical screen, curved horizontally and vertically. Its default angular
coverage is 180° horizontal and 101.25° vertical. The panel exposes **Screen
coverage** from 120° to 200° horizontally, **Reset coverage**, and **Recenter
cinema**. Broader coverage puts the picture into the peripheral view; reducing
it brings the edges and corner HUD elements closer to the forward view.

The surface has a 3 m radius and is centered on an `AnchorEntity(.head,
trackingMode: .once)`. It aligns with the initial head position and orientation,
then remains stable as the player moves their head. Recenter creates a new
once-tracked anchor for both screen and controls. Screen placement no longer
assumes a standing eye height. The controls retain their drag, collapse and
return actions. Their center stays within 2 m of the shared anchor, with at
least 0.45 m forward distance and a margin inside the 3 m screen so the panel
cannot be dragged behind the picture. Actual visible coverage and comfort
require a headset check; the app
does not query or claim an exact optical field of view for the device.

`CinemaScreenGeometry` generates an inward-facing spherical patch with complete
0…1 UV coverage and a 16:9 ratio between horizontal and vertical angular spans.
The video is mapped onto this curved surface rather than cropped to fill it.
This is a curved projection of the existing 2D stream, with the geometric
distortion inherent in wrapping a rectangular image onto a sphere.

The mesh is generated when the screen is prepared or coverage changes in 5°
steps. It is not rebuilt per frame. Coverage updates retain the existing video
texture, material and rendering consumer, and keep the last working geometry
if mesh generation fails. MetalFX output dimensions, decode, audio and controller
delivery use their existing paths. No depth inference or stereo synthesis is
enabled by this change.

Apple API references were checked through MCP Helpike and the SDK installed
with Xcode 27:

- [MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor)
  provides positions, normals, UVs and triangle indices for the custom surface.
- [TrackingMode.once](https://developer.apple.com/documentation/realitykit/anchoringcomponent/trackingmode-swift.struct/once)
  fixes the initial anchor transform after finding its target.

## Validation

- `scripts/test_cinema_screen_geometry.sh` passed with Xcode 27. Checks cover
  the 3 m radius, measured horizontal/vertical angles at every supported setting,
  inward normals and triangle winding, nondegenerate triangles, continuous full
  UV coverage, connected topology, and finite bounded input handling. Panel
  constraints preserve internal points and keep extreme moves inside the
  permitted radius without overflow.
- A separate RealityKit probe inspected the existing `generatePlane(width:height:)`
  mesh and confirmed U increases left to right and V increases bottom to top.
  The curved mesh preserves this orientation. Local probe:
  `/tmp/VisionRemotePS5-plane-uv-probe/main.swift`.
- Signed Debug built successfully with Xcode 27 for the device target, without
  compiler warnings. CoreDevice confirmed installation and normal launch on the Vision Pro.
  Logs: `/tmp/VisionRemotePS5-cinema-screen-geometry-host.log`,
  `/tmp/VisionRemotePS5-curved-cinema-device-build.log`,
  `/tmp/VisionRemotePS5-curved-cinema-install.log` and
  `/tmp/VisionRemotePS5-curved-cinema-console.log`.
- The new device console confirmed `Curved screen: horizontal=180.0 vertical=101.25`
  and successful cinema GPU processing of Source1920×1080 → MetalFX3840×2160 →
  Display target3840×2160. This confirms mesh creation and streaming through the
  cinema renderer; it does not establish the player's perceived coverage or comfort.

Physical coverage, comfort, image orientation and interaction in the new curved
cinema remain pending the user's headset test. No new performance or image
quality gain is inferred from geometry tests or a successful build. No commit
or push was requested for this change.
