//
//  DenseMesh.swift
//  VisionRemotePS5
//
//  Procedural geometry generator for spatial 3D rendering.
//  Generates a high-density mesh grid to support vertex displacement via Metal shaders.
//
//  Standard RealityKit planes have only 4 vertices. For volumetric depth effects,
//  we need ~10,000 vertices to create smooth 3D displacement.
//

import RealityKit
import MetalKit

/// Dense mesh generator for spatial rendering with vertex displacement.
struct DenseMesh {
    
    /// Generates a high-density grid mesh (default 128x72 = 9,289 vertices) for shader-based displacement.
    /// - Parameters:
    ///   - width: Width of the mesh in meters
    ///   - height: Height of the mesh in meters
    ///   - resX: Horizontal resolution (number of segments). Default: 128
    ///   - resY: Vertical resolution (number of segments). Default: 72
    /// - Returns: A MeshResource suitable for RealityKit entities
    static func generate(width: Float, height: Float, resX: Int = 128, resY: Int = 72) throws -> MeshResource {
        var desc = MeshDescriptor(name: "SpatialCanvas")
        
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        
        // Reserve capacity for performance
        let vertexCount = (resX + 1) * (resY + 1)
        let indexCount = resX * resY * 6
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        uvs.reserveCapacity(vertexCount)
        indices.reserveCapacity(indexCount)
        
        // 1. Generate Vertices
        for y in 0...resY {
            for x in 0...resX {
                let u = Float(x) / Float(resX)
                let v = Float(y) / Float(resY)
                
                // Center at origin (0,0)
                let posX = (u - 0.5) * width
                let posY = (1.0 - v - 0.5) * height
                
                positions.append([posX, posY, 0])
                normals.append([0, 0, 1]) // Normal Z+ (pointing towards user)
                uvs.append([u, 1.0 - v])  // Invert V for Metal coordinate system
            }
        }
        
        // 2. Topology (Triangles - Clockwise winding for RealityKit front-face)
        for y in 0..<resY {
            for x in 0..<resX {
                let i = UInt32(y * (resX + 1) + x)
                let iNext = UInt32((y + 1) * (resX + 1) + x)
                
                // First triangle (CW)
                indices.append(contentsOf: [i, i + 1, iNext])
                // Second triangle (CW)
                indices.append(contentsOf: [i + 1, iNext + 1, iNext])
            }
        }
        
        desc.positions = MeshBuffer(positions)
        desc.normals = MeshBuffer(normals)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives = .triangles(indices)
        
        print("[DenseMesh] ✅ Generated \(vertexCount) vertices, \(indexCount/3) triangles (\(resX)x\(resY) grid)")
        
        return try MeshResource.generate(from: [desc])
    }
    
    /// Generates a curved dense mesh with parabolic curvature for immersive viewing.
    /// - Parameters:
    ///   - width: Width of the mesh in meters
    ///   - height: Height of the mesh in meters
    ///   - curvature: Curvature depth (0.0 = flat, 0.4 = wrap-around)
    ///   - resX: Horizontal resolution. Default: 128
    ///   - resY: Vertical resolution. Default: 72
    /// - Returns: A curved MeshResource suitable for cinema-style display
    static func generateCurved(
        width: Float,
        height: Float,
        curvature: Float = 0.3,
        resX: Int = 128,
        resY: Int = 72
    ) throws -> MeshResource {
        var desc = MeshDescriptor(name: "CurvedSpatialCanvas")
        
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        
        let vertexCount = (resX + 1) * (resY + 1)
        let indexCount = resX * resY * 6
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        uvs.reserveCapacity(vertexCount)
        indices.reserveCapacity(indexCount)
        
        let halfWidth = width / 2.0
        let halfHeight = height / 2.0
        let maxDepth = curvature * width // Curvature proportional to width
        
        // 1. Generate Curved Vertices
        for y in 0...resY {
            let v = Float(y) / Float(resY)
            let posY = halfHeight - v * height
            
            for x in 0...resX {
                let u = Float(x) / Float(resX)
                let normalizedX = (u - 0.5) * 2.0 // -1 to 1
                let posX = normalizedX * halfWidth
                
                // Parabolic curvature: z = +depth * x^2 (positive = edges curve TOWARD user)
                // This creates a concave IMAX-style screen wrapping around the user
                let posZ = maxDepth * normalizedX * normalizedX
                
                positions.append([posX, posY, posZ])
                
                // Calculate normal for curved surface (pointing towards user = positive Z)
                // Derivative of z = d*x^2 is dz/dx = 2*d*x
                // For surface curving toward user, normal points toward user (positive Z at center)
                let tangentZ = 2.0 * maxDepth * normalizedX / halfWidth
                let normal = normalize(SIMD3<Float>(-tangentZ, 0, 1))
                normals.append(normal)
                
                // UV with V inversion for Metal
                uvs.append([u, 1.0 - v])
            }
        }
        
        // 2. Topology (Triangles - Counter-Clockwise winding for RealityKit)
        // RealityKit expects CCW winding for front faces when viewed from user (positive Z direction)
        for y in 0..<resY {
            for x in 0..<resX {
                let i = UInt32(y * (resX + 1) + x)
                let iNext = UInt32((y + 1) * (resX + 1) + x)
                
                // CCW winding: for each quad, create two triangles
                // Triangle 1: bottom-left, top-left, bottom-right
                // Triangle 2: bottom-right, top-left, top-right
                indices.append(contentsOf: [i, iNext, i + 1])
                indices.append(contentsOf: [i + 1, iNext, iNext + 1])
            }
        }
        
        desc.positions = MeshBuffer(positions)
        desc.normals = MeshBuffer(normals)
        desc.textureCoordinates = MeshBuffer(uvs)
        desc.primitives = .triangles(indices)
        
        print("[DenseMesh] ✅ Generated CURVED mesh: \(vertexCount) vertices, curvature=\(curvature)")
        
        return try MeshResource.generate(from: [desc])
    }
}
