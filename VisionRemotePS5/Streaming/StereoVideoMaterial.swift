import Foundation
import RealityKit

/// Displays a side-by-side video texture with one half for each eye.
///
/// The caller keeps its LowLevelTexture and updates it with `replace(using:)`;
/// the TextureResource and material are created once for that texture's lifetime.
/// The texture must have one mip level so filtering cannot combine the two eyes
/// in a lower-resolution mip. Its sRGB pixel format supplies the color conversion.
@available(visionOS 2.0, macOS 15.0, iOS 18.0, *)
@MainActor
enum StereoVideoMaterial {
    enum MaterialError: LocalizedError {
        case missingResource
        case invalidStereoTexture

        var errorDescription: String? {
            switch self {
            case .missingResource:
                return "The stereoscopic cinema material is unavailable."
            case .invalidStereoTexture:
                return "The stereoscopic cinema texture has an unsupported layout."
            }
        }
    }

    /// Left eye: x = 0..<width/2. Right eye: x = width/2..<width.
    /// A monoscopic render uses the left image. Both halves have the same UV
    /// orientation as the existing video plane; no vertical flip is introduced.
    static func make(
        texture: TextureResource,
        stereoWidth: Int,
        bundle: Bundle = .main
    ) async throws -> ShaderGraphMaterial {
        guard stereoWidth >= 2, stereoWidth.isMultiple(of: 2),
              texture.width == stereoWidth, texture.height > 0,
              texture.mipmapLevelCount == 1 else {
            throw MaterialError.invalidStereoTexture
        }
        guard let url = bundle.url(forResource: "StereoVideo", withExtension: "usda") else {
            throw MaterialError.missingResource
        }

        var material = try await ShaderGraphMaterial(named: "/Root/StereoVideo", from: url)
        try Task.checkCancellation()
        try material.setParameter(name: "StereoTexture", value: .textureResource(texture))

        // Half a texel in a single eye's normalized coordinates. Clamp before
        // packing the UV into its half of the texture to prevent seam bleeding.
        let eyeInset = 1 / Float(stereoWidth)
        try material.setParameter(name: "EyeUVMin", value: .simd2Float([eyeInset, 0]))
        try material.setParameter(name: "EyeUVMax", value: .simd2Float([1 - eyeInset, 1]))
        material.faceCulling = .none
        return material
    }
}
