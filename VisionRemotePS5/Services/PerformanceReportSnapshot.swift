import Foundation

/// Explicit numeric allowlist. The connection configuration itself, account,
/// console identifiers, credentials, endpoints and raw logs never enter export.
struct PerformanceReportConfiguration: Sendable {
    let session: MetricSessionID
    let width: Int
    let height: Int
    let framesPerSecond: Int
    let bitrateKbps: Int
}

struct PerformanceDecoderSnapshot: Sendable {
    let session: MetricSessionID
    let accepted: UInt64
    let rejectedNew: UInt64
    let outputs: UInt64
    let errors: UInt64
    let admittedSubmissions: Int
    let peakAdmittedSubmissions: Int
    let admittedPayloadBytes: Int
    let peakAdmittedPayloadBytes: Int
    let rejectedInvalid: UInt64
    let rejectedStopped: UInt64
    let cancelledBeforeDecode: UInt64
    /// An ended session can retain this observation after its decoder is released.
    var capturedAt: MetricTimestamp? = nil
}

/// Immutable capture for off-main formatting and an explicit user-selected save.
/// Each domain is copied independently; this is not an atomic pipeline snapshot.
struct PerformanceReportSnapshot: Sendable {
    let capturedAt: MetricTimestamp?
    let video: MetricSessionSnapshot
    var configuration: PerformanceReportConfiguration? = nil
    var input: InputMetricsSnapshot? = nil
    var renderer: VideoQueueMetrics.Snapshot? = nil
    var mailbox: VideoFrameMailbox.Diagnostics? = nil
    var decoder: PerformanceDecoderSnapshot? = nil
    var audioThermal: AudioThermalMetrics.Snapshot? = nil
}

enum PerformanceReportError: Error {
    case noSession
    case inconsistentSession
    case collectionDisabled
}
