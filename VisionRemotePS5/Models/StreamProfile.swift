import Foundation

/// Requested Chiaki source presets. These values configure the console encoder;
/// the actual received dimensions are read from decoded frames by the renderer.
enum StreamProfile: String, CaseIterable, Identifiable {
    case minimum = "360p"
    case low = "540p"
    case standard = "720p"
    case reference = "1080p"

    static let preferenceKey = "stream_source_profile_v1"
    static var selected: StreamProfile {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .minimum
    }

    var id: Self { self }
    var width: Int {
        switch self {
        case .minimum: 640
        case .low: 960
        case .standard: 1280
        case .reference: 1920
        }
    }
    var height: Int {
        switch self {
        case .minimum: 360
        case .low: 540
        case .standard: 720
        case .reference: 1080
        }
    }
    var bitrateKbps: Int {
        switch self {
        case .minimum: 2000
        case .low: 6000
        case .standard: 10000
        case .reference: 15000
        }
    }
    // Preserve source cadence while testing bandwidth and spatial upscaling.
    var framesPerSecond: Int { 60 }
    var title: String { "\(rawValue) · \(bitrateKbps / 1000) Mbps" }
    var summary: String { "\(rawValue) · 60 fps · \(bitrateKbps / 1000) Mbps requested" }
}
