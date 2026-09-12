# Depth Anything V2 Small

This repository retains the unmodified **DepthAnythingV2SmallF16** Core ML conversion published by Apple for the suspended depth experiment. The model and depth pipeline are excluded from the active app target: the current app neither bundles nor executes them. The model predicts relative monocular inverse depth, not the PS5 game's depth buffer or metric scene geometry.

- Publisher and model card: https://huggingface.co/apple/coreml-depth-anything-v2-small
- Apple model gallery: https://developer.apple.com/machine-learning/models/
- Download: https://ml-assets.apple.com/coreml/models/Image/DepthEstimation/DepthAnything/DepthAnythingV2SmallF16.mlpackage.zip
- Original authors and source: https://github.com/DepthAnything/Depth-Anything-V2
- License: Apache License 2.0, reproduced in `DepthAnythingV2-LICENSE.txt`. The original repository explicitly licenses the **Small** model under Apache-2.0; this does not cover the larger model variants.
- Downloaded: 2026-09-09.

Original work: Lihe Yang, Bingyi Kang, Zilong Huang, Zhen Zhao, Xiaogang Xu, Jiashi Feng, and Hengshuang Zhao, *Depth Anything V2*, 2024. https://arxiv.org/abs/2406.09414

The package contains approximately 49.8 MB of weights/model data. Xcode's Core ML compiler confirms the fixed input `image` is a 518 × 392 BGRA pixel buffer; output `depth` is a 518 × 392 one-component Float16 pixel buffer. The retained experimental pipeline stretches the complete incoming image to that input, then samples the relative depth map using normalized source coordinates. Its prediction configuration uses Core ML's CPU and GPU on an independent serial queue.

SHA-256 checksums:

```text
8e875979ec82fa46f292468a7567a520b2aa07c41008c32141f3396da05a4067  DepthAnythingV2SmallF16.mlpackage.zip
44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042  Data/com.apple.CoreML/model.mlmodel
fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed  Data/com.apple.CoreML/weights/weight.bin
```

Apple publishes timing on other devices, but those measurements do not establish Vision Pro latency or game-image quality. The suspended pipeline admits at most one inference every 125 ms and never queues source frames. Its live maps older than 250 ms, abrupt image changes, and serious/critical thermal state reduce or disable stereo displacement. A frozen image may keep the map from that exact source frame. The resulting stereo is a synthesized approximation; it can have depth errors and missing information behind objects.
