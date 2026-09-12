# Legacy model conversion audit — 2026-09-07

Task 00.10 is complete as a source/documentation audit. Neither legacy script
is suitable to restore unchanged. No model was downloaded, converted, loaded,
quantized, or added to the app; no Python ML dependencies were installed.

## Historical inputs

The scripts were removed in cleanup commit `d05c118`. Inspected their last
pre-removal content at `edc0a3d378bed14fb8342277ce049a48f9db7871` using:

```sh
git show edc0a3d378bed14fb8342277ce049a48f9db7871:scripts/convert_midas_to_coreml.py
git show edc0a3d378bed14fb8342277ce049a48f9db7871:scripts/quantize_depth_model.py
```

| Script | SHA-256 of historical bytes |
|---|---|
| `convert_midas_to_coreml.py` | `869ead984efbccb034c4ff6bcce808ea54f27936f5a19ad4d74bd5e6d4144bf4` |
| `quantize_depth_model.py` | `eec56f7e292c01c24a84a64866071bc6800396501724fcc57753ede46fa6f325` |

Both parse as Python syntax via `ast.parse`; parsing does not execute imports or
validate conversion. The app branch is `docs/active-streaming-paths` at
`059a71c`; this task adds documentation only.

## MiDaS conversion

The script loads `MiDaS_small` through an unpinned `torch.hub.load`, traces one
random 1×3×256×256 input, and exports an `mlprogram` with RGB image input.

**Normalization is incorrect.** It uses scale `1/255` with bias `-mean/std`,
which computes `pixel/255 - mean/std`. The intended per-channel expression is
`(pixel/255 - mean)/std`. For a red pixel of 255, the script gives −1.117904
instead of 2.248908. Apple's image preprocessing applies scale before bias and
has one shared scale, so exact unequal channel standard deviations need an
explicit graph/preprocessing implementation, not the current parameters.
[Apple image-input guide](https://apple.github.io/coremltools/docs-guides/source/image-inputs.html)

The upstream small-model transform also preserves aspect ratio, uses a
256-pixel bound, and aligns dimensions to multiples of 32. A fixed square trace
does not define how a 16:9 game frame is resized, cropped, padded, or mapped back
to video coordinates. The script does not apply or validate that transform.
[MiDaS transforms](https://raw.githubusercontent.com/isl-org/MiDaS/master/hubconf.py)

The generic model-size/quality comments and metadata string “v2.1” are not
checkpoint provenance: dependencies, repository revision, weight hash, license,
and conversion environment are not recorded. `model.eval()` and explicit tensor
names/shapes are reusable structure, but the single random trace is not a
numerical parity test against representative images.

## Depth Anything conversion and quantization

| Finding | Consequence / requirement for future work |
|---|---|
| PyTorch image input uses scale `1/255`, zero bias, and traces `forward`. | Missing mean/std preprocessing; `forward` does not call `image2tensor`. |
| Any state dictionary selects the Small (`vits`) architecture. | File suffix and dictionary type do not identify model variant or checkpoint layout. Validate explicit architecture and checkpoint contract. |
| Arbitrary `--input-size` is accepted; summary always reports CLI dimensions. | No positivity/patch-alignment check, no aspect-ratio mapping, and no inspection of actual inputs for an existing Core ML package. |
| `.onnx` is sent directly to `ct.convert`. | Not a supported source in the inspected unified converter API; this route needs a separately validated conversion path. |
| `linear_quantize_weights` is labeled “INT8 CoreML”. | Weight compression alone does not establish INT8 activations or integer compute. |
| Recreates `MLModel(spec, compute_units=...)` without `weights_dir`. | A weighted ML Program stores weights separately; this loses required package context and cannot reconstruct that model correctly. |
| `--skip-quantization` is reported as Float16 for every input type. | Existing Core ML inputs are not converted to FP16 by this branch. Report precision from the actual result. |
| `os.path.getsize(output_path)` is used for `.mlpackage`. | Reports the directory entry's size rather than recursively totaling package files. |
| Versions/checkpoints are unpinned; `depth_anything_v2` is an external import not installed by the listed command. | The recipe is not reproducible and has unresolved acquisition/environment requirements. |

The official relative-depth implementation scales BGR input to RGB in [0,1],
normalizes by mean `[0.485, 0.456, 0.406]` and std `[0.229, 0.224, 0.225]`, and
resizes with aspect ratio retained and dimensions aligned to 14. `infer_image`
also resizes predictions back to the original image dimensions. The script
traces `forward` alone, bypassing these surrounding transformations.
[Depth Anything V2 implementation](https://raw.githubusercontent.com/DepthAnything/Depth-Anything-V2/main/depth_anything_v2/dpt.py)

The inspected unified converter documents TensorFlow, PyTorch, and MIL sources,
not direct ONNX input. Its compute-unit choices specify allowed units;
`ALL` allows CPU/GPU/NE and `CPU_AND_NE` allows CPU/NE while excluding GPU.
Neither establishes which operators ran on ANE, and changing the Python model
object's configuration is not evidence of the app's runtime configuration.
[Apple converter API](https://apple.github.io/coremltools/source/coremltools.converters.convert.html)

Apple's weight-quantization documentation explicitly distinguishes compressed
weight storage from floating-point runtime computation. The legacy “<10 ms”
and Neural Engine optimization statements have no measurement procedure or
device results. Preserve them only as unvalidated aspirations, not capabilities.
[Apple weight compression API](https://apple.github.io/coremltools/docs/source/coremltools.optimize.coreml.post_training_quantization.html)

For a weighted `mlprogram` reconstructed from a spec, both that spec and its
weight directory must be preserved. Reuse the original package/model or provide
the associated `weights_dir` when rebuilding the object.
[Apple model API](https://apple.github.io/coremltools/source/coremltools.models.html)

## Reuse and future gates

Reusable ideas are limited to CLI input/output selection, `eval()` before export,
explicit RGB/tensor contracts, export metadata, and separating conversion from
optional compression. The Small architecture configuration is a candidate to
verify against the selected package, not a detector for arbitrary checkpoints.

Both scripts select `ct.target.iOS17`; the MiDaS comment equating that setting
to visionOS 1.0 is not an SDK/runtime compatibility test. Future work must pin
Python/PyTorch/coremltools/model revisions, inspect the actual target API, and
compile/load on the intended visionOS version without automatically raising the
app's deployment target. No conversion-library version was installed or tested
by this audit. The linked Apple references identify API documentation versions
8.1/8.3; they are evidence for these defects, not a selected future toolchain.

Before stage 06 conversion work: pin checkpoint/hash/license and acquisition;
define exact RGB normalization and geometric transforms; validate deterministic
reference images; inspect real model I/O and package size; preserve weights;
measure precision error and runtime placement/latency on the headset. Keep the
planned initial FP16 candidate separate from any later weight-compression trial.

Test R evidence: historical source hashes and syntax inspection; the independent
scalar normalization calculation above; primary documentation reviewed on
2026-09-07; `git diff --check`. Upstream branch URLs describe the inspected
reference implementation and must be pinned to a specific revision before a
future reproducible conversion. No inference benchmark or model-quality result
is claimed. Next task: 01.01, monotonic metrics schema.
