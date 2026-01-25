#!/usr/bin/env python3
"""
quantize_depth_model.py
VisionRemotePS5

Converts and quantizes Depth Anything V2 Small model to INT8 CoreML format
Optimized for Apple Neural Engine execution with <10ms latency target

Usage:
    python quantize_depth_model.py --input depth_anything_v2_small.pt --output DepthAnythingV2Small_Int8.mlpackage

Requirements:
    pip install coremltools torch torchvision onnx
"""

import argparse
import os
import sys

def main():
    parser = argparse.ArgumentParser(
        description="Convert and quantize Depth Anything V2 model to INT8 CoreML"
    )
    parser.add_argument(
        "--input",
        type=str,
        required=True,
        help="Path to input model (PyTorch .pt, ONNX .onnx, or CoreML .mlmodel/.mlpackage)"
    )
    parser.add_argument(
        "--output",
        type=str,
        default="DepthAnythingV2Small_Int8.mlpackage",
        help="Output path for quantized CoreML model"
    )
    parser.add_argument(
        "--input-size",
        type=int,
        nargs=2,
        default=[518, 518],
        help="Input image size [height, width] (default: 518 518)"
    )
    parser.add_argument(
        "--skip-quantization",
        action="store_true",
        help="Skip INT8 quantization (output Float16 model only)"
    )
    
    args = parser.parse_args()
    
    try:
        import coremltools as ct
        from coremltools.optimize.coreml import (
            OpLinearQuantizerConfig,
            OptimizationConfig,
            linear_quantize_weights
        )
        import torch
    except ImportError as e:
        print(f"❌ Missing dependency: {e}")
        print("Install with: pip install coremltools torch torchvision")
        sys.exit(1)
    
    input_path = args.input
    output_path = args.output
    input_height, input_width = args.input_size
    
    print(f"📦 Loading model from: {input_path}")
    
    # Determine input format and convert to CoreML
    if input_path.endswith(".pt") or input_path.endswith(".pth"):
        mlmodel = convert_from_pytorch(input_path, input_height, input_width)
    elif input_path.endswith(".onnx"):
        mlmodel = convert_from_onnx(input_path)
    elif input_path.endswith(".mlmodel") or input_path.endswith(".mlpackage"):
        mlmodel = ct.models.MLModel(input_path)
    else:
        print(f"❌ Unsupported input format: {input_path}")
        sys.exit(1)
    
    print("✅ Model loaded successfully")
    
    # Apply INT8 quantization
    if not args.skip_quantization:
        print("🔧 Applying INT8 quantization (linear_symmetric)...")
        
        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric",
                dtype="int8",
                granularity="per_tensor"
            )
        )
        
        quantized_model = linear_quantize_weights(mlmodel, config=config)
        
        print("✅ Quantization complete")
    else:
        quantized_model = mlmodel
        print("⏭️ Skipping quantization (Float16 output)")
    
    # Configure compute units for Neural Engine
    print("⚙️ Configuring for Apple Neural Engine...")
    
    # Re-save with Neural Engine preference
    spec = quantized_model.get_spec()
    
    # Set compute units
    quantized_model = ct.models.MLModel(
        spec,
        compute_units=ct.ComputeUnit.CPU_AND_NE  # Prefer Neural Engine
    )
    
    # Save the model
    print(f"💾 Saving to: {output_path}")
    quantized_model.save(output_path)
    
    # Print model info
    print("\n📊 Model Summary:")
    print(f"   Input: {input_height}x{input_width} RGB image")
    print(f"   Output: Depth map (single channel)")
    print(f"   Quantization: {'INT8' if not args.skip_quantization else 'Float16'}")
    print(f"   Compute Units: CPU + Neural Engine")
    
    # Verify file was created
    if os.path.exists(output_path):
        size_mb = os.path.getsize(output_path) / (1024 * 1024)
        print(f"   Size: {size_mb:.2f} MB")
        print("\n✅ Done! Model ready for deployment.")
    else:
        print("\n❌ Error: Output file not created")
        sys.exit(1)


def convert_from_pytorch(pt_path: str, height: int, width: int):
    """Convert PyTorch model to CoreML"""
    import coremltools as ct
    import torch
    
    print("🔄 Converting from PyTorch...")
    
    # Load the PyTorch model
    model = torch.load(pt_path, map_location="cpu")
    
    # If it's a state dict, we need the model architecture
    if isinstance(model, dict):
        print("⚠️ Loaded a state dictionary. Attempting to find model architecture...")
        # Try to import Depth Anything V2
        try:
            from depth_anything_v2.dpt import DepthAnythingV2
            
            model_configs = {
                'vits': {'encoder': 'vits', 'features': 64, 'out_channels': [48, 96, 192, 384]},
                'vitb': {'encoder': 'vitb', 'features': 128, 'out_channels': [96, 192, 384, 768]},
                'vitl': {'encoder': 'vitl', 'features': 256, 'out_channels': [256, 512, 1024, 1024]},
            }
            
            # Default to small model
            config = model_configs['vits']
            architecture = DepthAnythingV2(**config)
            architecture.load_state_dict(model)
            model = architecture
            
        except ImportError:
            print("❌ Cannot find Depth Anything V2 model definition")
            print("   Please provide a traced or scripted model, or install depth_anything_v2")
            sys.exit(1)
    
    model.eval()
    
    # Create example input
    example_input = torch.randn(1, 3, height, width)
    
    # Trace the model
    print("📝 Tracing model...")
    traced_model = torch.jit.trace(model, example_input)
    
    # Convert to CoreML
    print("🔄 Converting to CoreML...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[ct.ImageType(
            name="image",
            shape=example_input.shape,
            scale=1/255.0,
            bias=[0, 0, 0],
            color_layout=ct.colorlayout.RGB
        )],
        outputs=[ct.TensorType(name="depth")],
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram"
    )
    
    return mlmodel


def convert_from_onnx(onnx_path: str):
    """Convert ONNX model to CoreML"""
    import coremltools as ct
    
    print("🔄 Converting from ONNX...")
    
    mlmodel = ct.convert(
        onnx_path,
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram"
    )
    
    return mlmodel


if __name__ == "__main__":
    main()
