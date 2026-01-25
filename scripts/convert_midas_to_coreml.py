#!/usr/bin/env python3
"""
MiDaS to Core ML Conversion Script
Converts MiDaS depth estimation model to Core ML format for VisionOS

Usage:
    pip install torch torchvision coremltools timm
    python convert_midas_to_coreml.py

Output:
    DepthEstimation.mlpackage (drag to Xcode)
"""

import torch
import coremltools as ct
import numpy as np

# Model options:
# - "MiDaS_small" - Fastest, ~25MB, good quality
# - "DPT_Hybrid" - Balanced, ~100MB, better quality  
# - "DPT_Large" - Best quality, ~400MB, slowest

MODEL_TYPE = "MiDaS_small"
INPUT_SIZE = 256  # Smaller = faster inference

def main():
    print(f"Loading MiDaS model: {MODEL_TYPE}")
    
    # Load pre-trained model
    model = torch.hub.load("intel-isl/MiDaS", MODEL_TYPE, pretrained=True)
    model.eval()
    
    # Create example input
    example_input = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    
    # Trace the model
    print("Tracing model...")
    traced_model = torch.jit.trace(model, example_input)
    
    # Convert to Core ML
    print("Converting to Core ML...")
    
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                scale=1/255.0,
                bias=[-0.485/0.229, -0.456/0.224, -0.406/0.225],  # ImageNet normalization
                color_layout=ct.colorlayout.RGB
            )
        ],
        outputs=[
            ct.TensorType(name="depth", dtype=np.float32)
        ],
        compute_units=ct.ComputeUnit.ALL,  # Use Neural Engine
        minimum_deployment_target=ct.target.iOS17,  # visionOS 1.0
        convert_to="mlprogram"
    )
    
    # Set metadata
    mlmodel.author = "VisionRemotePS5"
    mlmodel.short_description = "Monocular depth estimation from MiDaS v2.1"
    mlmodel.version = "1.0"
    
    # Save
    output_path = "DepthEstimation.mlpackage"
    mlmodel.save(output_path)
    print(f"✅ Model saved to: {output_path}")
    print(f"   Drag this folder into Xcode to add to project")
    print(f"   Xcode will compile it to .mlmodelc automatically")

if __name__ == "__main__":
    main()
