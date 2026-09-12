import Foundation

/// A spherical video surface centered on the viewer and facing forward (-Z).
/// Coverage describes angles at the sphere's center, not a planar aspect ratio.
enum CinemaScreenGeometry {
    static let defaultHorizontalCoverage: Float = 180
    static let coverageRange: ClosedRange<Float> = 120...200

    struct MeshData: Sendable {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let textureCoordinates: [SIMD2<Float>]
        let triangleIndices: [UInt32]
    }

    /// Finite requests are clamped before rounding, so hostile values cannot
    /// overflow an integer conversion or expand the fixed mesh allocation.
    static func normalizedCoverage(_ value: Float) -> Float {
        guard value.isFinite else { return defaultHorizontalCoverage }
        let clamped = min(max(value, coverageRange.lowerBound), coverageRange.upperBound)
        return (clamped / 5).rounded(.toNearestOrAwayFromZero) * 5
    }

    /// Positions are relative to the same anchor as the 3m screen. Keep the
    /// panel's center within 2m, leaving a radial margin for its planar extent.
    static func constrainedControlPosition(_ proposed: SIMD3<Float>) -> SIMD3<Float> {
        guard proposed.x.isFinite, proposed.y.isFinite, proposed.z.isFinite else {
            return SIMD3(0, 0, -1.2)
        }
        let z = min(max(proposed.z, -2), -0.45)
        let maximumXY = sqrt(max(0, 4 - Double(z) * Double(z)))
        // Compute before converting back to Float so even its largest finite
        // coordinates cannot overflow the distance or normalization.
        let distanceXY = hypot(Double(proposed.x), Double(proposed.y))
        guard distanceXY > maximumXY else { return SIMD3(proposed.x, proposed.y, z) }
        let scale = maximumXY / distanceXY
        func roundedInward(_ value: Double) -> Float {
            let rounded = Float(value)
            // A projected boundary point must not round outside the 2m sphere.
            // Internal points bypass this adjustment and remain unchanged.
            return rounded == 0 ? 0 : rounded > 0 ? rounded.nextDown : rounded.nextUp
        }
        return SIMD3(roundedInward(Double(proposed.x) * scale),
                     roundedInward(Double(proposed.y) * scale), z)
    }

    static func make(horizontalCoverage: Float) -> MeshData {
        let horizontalAngle = normalizedCoverage(horizontalCoverage) * .pi / 180
        let verticalAngle = horizontalAngle * 9 / 16
        let horizontalSegments = 96
        let verticalSegments = 54
        let rowLength = horizontalSegments + 1
        let vertexCount = rowLength * (verticalSegments + 1)
        let radius: Float = 3
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        var triangleIndices: [UInt32] = []
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        textureCoordinates.reserveCapacity(vertexCount)
        triangleIndices.reserveCapacity(horizontalSegments * verticalSegments * 6)

        for row in 0...verticalSegments {
            let v = Float(row) / Float(verticalSegments)
            let phi = (v - 0.5) * verticalAngle
            for column in 0...horizontalSegments {
                let u = Float(column) / Float(horizontalSegments)
                let theta = (u - 0.5) * horizontalAngle
                let outward = SIMD3<Float>(sin(theta) * cos(phi), sin(phi), -cos(theta) * cos(phi))
                positions.append(outward * radius)
                normals.append(-outward)
                // v grows from the lower edge to the upper edge, matching the
                // existing RealityKit plane. Keep the complete image domain;
                // no crop or wrapping is introduced.
                textureCoordinates.append(SIMD2(u, v))
            }
        }

        for row in 0..<verticalSegments {
            for column in 0..<horizontalSegments {
                let lowerLeft = UInt32(row * rowLength + column)
                let lowerRight = lowerLeft + 1
                let upperLeft = lowerLeft + UInt32(rowLength)
                let upperRight = upperLeft + 1
                // Counterclockwise as seen from the center of the sphere.
                triangleIndices.append(contentsOf: [lowerLeft, lowerRight, upperLeft,
                                                   upperLeft, lowerRight, upperRight])
            }
        }
        return MeshData(positions: positions, normals: normals,
                        textureCoordinates: textureCoordinates, triangleIndices: triangleIndices)
    }
}
