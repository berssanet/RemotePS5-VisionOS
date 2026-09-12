import Foundation
import simd

@MainActor
private enum Checks {
    static var count = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        count += 1
        guard condition() else { fatalError(message, file: file, line: line) }
    }
}

private struct Edge: Hashable {
    let low: UInt32
    let high: UInt32
    init(_ a: UInt32, _ b: UInt32) { low = min(a, b); high = max(a, b) }
}

@MainActor
@main
private enum CinemaScreenGeometryHostTests {
    static func main() {
        typealias Geometry = CinemaScreenGeometry
        Checks.expect(Geometry.defaultHorizontalCoverage == 180, "Default coverage is 180 degrees")
        Checks.expect(Geometry.coverageRange == 120...200, "The supported range is bounded at 120–200 degrees")
        let normalizedCases: [(Float, Float)] = [
            (.nan, 180), (.infinity, 180), (-.infinity, 180),
            (-.greatestFiniteMagnitude, 120), (.greatestFiniteMagnitude, 200),
            (-1, 120), (0, 120), (119.9, 120), (120, 120),
            (122.49, 120), (122.5, 125), (127.5, 130),
            (177.49, 175), (177.5, 180), (180, 180),
            (197.49, 195), (197.5, 200), (200, 200), (201, 200)
        ]
        for (request, expected) in normalizedCases {
            let value = Geometry.normalizedCoverage(request)
            Checks.expect(value == expected, "Normalization must have deterministic clamp, bucket and invalid-input behavior")
            Checks.expect(Geometry.normalizedCoverage(value) == value, "Normalization is idempotent")
            let actual = Geometry.make(horizontalCoverage: request)
            let canonical = Geometry.make(horizontalCoverage: expected)
            Checks.expect(actual.positions == canonical.positions && actual.normals == canonical.normals
                          && actual.textureCoordinates == canonical.textureCoordinates
                          && actual.triangleIndices == canonical.triangleIndices,
                          "Mesh creation must use the normalized coverage for every input, including nonfinite values")
        }

        for coverage in stride(from: Float(120), through: 200, by: 5) {
            validate(Geometry.make(horizontalCoverage: coverage), coverage: coverage)
        }
        validateControlPositions()
        print("PASS: CinemaScreenGeometry \(Checks.count) checks; all 17 coverages, 3m radius, inward normals/winding, complete continuous UVs, open-patch topology, finite inputs and bounded normalization")
    }

    private static func validateControlPositions() {
        let fallback = SIMD3<Float>(0, 0, -1.2)
        for point: SIMD3<Float> in [fallback, SIMD3(0.3, -0.2, -1.2), SIMD3(1.5, 0, -1.2),
                                   SIMD3(0, 0, -2), SIMD3(0, 0, -0.45)] {
            Checks.expect(CinemaScreenGeometry.constrainedControlPosition(point) == point,
                          "A valid interior panel position must remain exactly unchanged")
        }
        Checks.expect(CinemaScreenGeometry.constrainedControlPosition(SIMD3(0.3, -0.2, 8)) == SIMD3(0.3, -0.2, -0.45),
                      "Clamping depth preserves XY when it already fits at that depth")
        for axis in 0..<3 {
            for invalid: Float in [.nan, .infinity, -.infinity] {
                var point = SIMD3<Float>(0.3, -0.2, -1.2)
                point[axis] = invalid
                Checks.expect(CinemaScreenGeometry.constrainedControlPosition(point) == fallback,
                              "Any nonfinite component restores the complete safe position")
            }
        }
        let extreme = Float.greatestFiniteMagnitude
        let points: [SIMD3<Float>] = [
            SIMD3(3, 4, -1.2), SIMD3(-3, 4, -1.2), SIMD3(3, -4, -1.2), SIMD3(-3, -4, -1.2),
            SIMD3(1, 1, -2), SIMD3(1, 1, -1.999), SIMD3(0, 0, -extreme),
            SIMD3(2, 0, 0), SIMD3(0, -2, 10), SIMD3(0, 0, extreme),
            SIMD3(extreme, extreme, -0.45), SIMD3(-extreme, extreme, -1.2),
            SIMD3(extreme, -extreme, -extreme), SIMD3(-extreme, -extreme, extreme),
            SIMD3(extreme, .leastNonzeroMagnitude, -1.2), SIMD3(.leastNonzeroMagnitude, -extreme, -1.2)
        ]
        for point in points {
            let result = CinemaScreenGeometry.constrainedControlPosition(point)
            Checks.expect(result.x.isFinite && result.y.isFinite && result.z.isFinite,
                          "Finite extreme coordinates cannot overflow the constraint")
            Checks.expect((-2 ... -0.45).contains(result.z) && result.z == min(max(point.z, -2), -0.45),
                          "Radial limiting preserves the clamped depth")
            let resultXY = hypot(Double(result.x), Double(result.y))
            Checks.expect(hypot(resultXY, Double(result.z)) <= 2,
                          "The panel center remains within 2m, including Float rounding at the boundary")
            Checks.expect(CinemaScreenGeometry.constrainedControlPosition(result) == result,
                          "Applying the constraint repeatedly must not move the panel")
            let proposedXY = hypot(Double(point.x), Double(point.y))
            if resultXY > 0 && proposedXY > 0 {
                let xError = abs(Double(result.x) / resultXY - Double(point.x) / proposedXY)
                let yError = abs(Double(result.y) / resultXY - Double(point.y) / proposedXY)
                Checks.expect(max(xError, yError) < 0.000001,
                              "An outward drag preserves its XY direction rather than clipping each axis separately")
            }
        }
        print("PASS: panel constraints preserve interior points and XY direction, clamp depth, bound radius to2m and handle nonfinite/extreme coordinates")
    }

    private static func validate(_ mesh: CinemaScreenGeometry.MeshData, coverage: Float) {
        let columns = 97, rows = 55
        let vertexCount = columns * rows
        Checks.expect(mesh.positions.count == vertexCount, "Every coverage uses exactly 97×55 vertices")
        Checks.expect(mesh.normals.count == vertexCount && mesh.textureCoordinates.count == vertexCount,
                      "Positions, normals and UVs have identical vertex domains")
        Checks.expect(mesh.triangleIndices.count == 96 * 54 * 6, "The patch contains exactly two triangles per quad")
        let centerIndex = 27 * columns + 48
        Checks.expect(simd_distance(mesh.positions[centerIndex], SIMD3(0, 0, -3)) < 0.00001,
                      "The center stays three meters directly forward at every coverage")
        Checks.expect(simd_distance(mesh.normals[centerIndex], SIMD3(0, 0, 1)) < 0.00001,
                      "The front of the center points toward the viewer")
        Checks.expect(mesh.textureCoordinates[centerIndex] == SIMD2(0.5, 0.5),
                      "The center of the complete video maps to the forward center")

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let position = mesh.positions[index], normal = mesh.normals[index]
                let uv = mesh.textureCoordinates[index]
                Checks.expect(position.x.isFinite && position.y.isFinite && position.z.isFinite,
                              "All geometry coordinates remain finite")
                Checks.expect(normal.x.isFinite && normal.y.isFinite && normal.z.isFinite,
                              "All normals remain finite")
                Checks.expect(abs(simd_length(position) - 3) < 0.00001,
                              "Every vertex lies on the same radius, without a flatter center or stretched corners")
                Checks.expect(abs(simd_length(normal) - 1) < 0.00001
                              && simd_dot(normal, position) < -2.9999,
                              "Normals are unit length and point radially inward")
                Checks.expect(uv.x.isFinite && uv.y.isFinite && (0...1).contains(uv.x) && (0...1).contains(uv.y),
                              "UVs stay inside the full finite image domain")
                if column == 0 { Checks.expect(uv.x == 0, "The left edge includes the first source column") }
                if column == columns - 1 { Checks.expect(uv.x == 1, "The right edge includes the last source column") }
                if row == 0 { Checks.expect(uv.y == 0, "The lower edge includes the first V coordinate") }
                if row == rows - 1 { Checks.expect(uv.y == 1, "The upper edge includes the last V coordinate") }
                if column > 0 {
                    let previous = mesh.textureCoordinates[index - 1]
                    Checks.expect(abs(uv.x - previous.x - 1 / Float(96)) < 0.000001 && uv.y == previous.y,
                                  "Horizontal UVs advance continuously without seams, cropping or mirroring")
                }
                if row > 0 {
                    let previous = mesh.textureCoordinates[index - columns]
                    Checks.expect(abs(uv.y - previous.y - 1 / Float(54)) < 0.000001 && uv.x == previous.x,
                                  "Vertical UVs advance continuously in the declared bottom-to-top convention")
                    Checks.expect(position.y > mesh.positions[index - columns].y,
                                  "Successive rows rise monotonically without pole wrapping")
                }
            }
        }

        let equator = 27 * columns
        let left = mesh.positions[equator], right = mesh.positions[equator + columns - 1]
        let observedHorizontal = (atan2(right.x, -right.z) - atan2(left.x, -left.z)) * 180 / .pi
        Checks.expect(abs(observedHorizontal - coverage) < 0.0001,
                      "The measured azimuth span equals the requested angular coverage, including beyond 180 degrees")
        let bottom = mesh.positions[48], top = mesh.positions[(rows - 1) * columns + 48]
        let observedVertical = (asin(top.y / 3) - asin(bottom.y / 3)) * 180 / .pi
        Checks.expect(abs(observedVertical - coverage * 9 / 16) < 0.0001,
                      "Measured elevation coverage preserves the declared 16:9 angular relationship")
        Checks.expect(left.x < 0 && right.x > 0 && bottom.y < 0 && top.y > 0,
                      "The surface has the expected left/right and lower/upper orientation")

        var edgeUses: [Edge: Int] = [:]
        var usedVertices = Set<UInt32>()
        for offset in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
            let indices = Array(mesh.triangleIndices[offset..<(offset + 3)])
            Checks.expect(indices.allSatisfy { $0 < UInt32(vertexCount) } && Set(indices).count == 3,
                          "Every triangle references three distinct valid vertices")
            let a = mesh.positions[Int(indices[0])]
            let b = mesh.positions[Int(indices[1])]
            let c = mesh.positions[Int(indices[2])]
            let cross = simd_cross(b - a, c - a)
            Checks.expect(simd_length_squared(cross) > 0.00000001,
                          "No triangle collapses at an edge or any supported coverage")
            Checks.expect(simd_dot(cross, -(a + b + c) / 3) > 0,
                          "Every triangle is counterclockwise when viewed from inside the sphere")
            let uvs = indices.map { mesh.textureCoordinates[Int($0)] }
            Checks.expect(uvs.map(\.x).max()! - uvs.map(\.x).min()! <= 1 / Float(96) + 0.000001
                          && uvs.map(\.y).max()! - uvs.map(\.y).min()! <= 1 / Float(54) + 0.000001,
                          "Triangles never bridge unrelated UV rows or columns")
            for (from, to) in [(indices[0], indices[1]), (indices[1], indices[2]), (indices[2], indices[0])] {
                edgeUses[Edge(from, to), default: 0] += 1
            }
            usedVertices.formUnion(indices)
        }
        Checks.expect(usedVertices.count == vertexCount, "The mesh has no detached or unused vertices")
        Checks.expect(edgeUses.values.allSatisfy { $0 == 1 || $0 == 2 },
                      "Edges belong to one boundary triangle or two interior triangles, never overlapping quads")
        Checks.expect(edgeUses.values.filter { $0 == 1 }.count == 2 * 96 + 2 * 54,
                      "Only the outer perimeter is open; the interior contains no cracks or wrapped seam")
    }
}
