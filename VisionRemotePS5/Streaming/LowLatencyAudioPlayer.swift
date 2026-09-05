import Foundation
import AVFoundation

/// One stereo source keeps both channels aligned, including overload recovery.
final class LowLatencyAudioPlayer {
    private let sampleRate: Int
    private let channels: Int
    private let ring: AudioRingBuffer
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var targetSamples: Int
    private let maximumRenderFrames = 8192
    private let scratch: UnsafeMutablePointer<Int16>
    private var receivedSamples = 0

    init(sampleRate: Int, channels: Int) {
        precondition(channels == 2)
        self.sampleRate = sampleRate
        self.channels = channels
        targetSamples = sampleRate * channels * 40 / 1000
        // Hard bound even when the audio service stops consuming.
        ring = AudioRingBuffer(capacity: sampleRate * channels / 5, alignment: channels)
        scratch = .allocate(capacity: 8192 * channels)
    }
    deinit { engine?.stop(); scratch.deallocate() }

    /// Configure before start; callback state remains immutable during playback.
    func setTargetLatency(milliseconds: Double) {
        guard engine == nil, milliseconds.isFinite else { return }
        targetSamples = Int(Double(sampleRate) * min(80, max(20, milliseconds)) / 1000) * channels
    }

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setPreferredSampleRate(Double(sampleRate))
            try session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2) else { return }
            let engine = AVAudioEngine()
            let source = AVAudioSourceNode(format: format) { [weak self] silence, _, frames, buffers in
                guard let self else { return noErr }
                let output = UnsafeMutableAudioBufferListPointer(buffers)
                guard frames <= self.maximumRenderFrames else {
                    for buffer in output { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                    silence.pointee = true
                    return noErr
                }
                let count = Int(frames) * self.channels
                let read = self.ring.read(self.scratch, count: count,
                    maximumBuffered: self.sampleRate * self.channels / 10,
                    targetBuffered: self.targetSamples)
                for (channel, buffer) in output.enumerated() {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let available = min(Int(frames), Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    for frame in 0..<available {
                        data[frame] = channel < self.channels ? Float(self.scratch[frame * self.channels + channel]) / 32768 : 0
                    }
                }
                silence.pointee = ObjCBool(read == 0)
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
            self.engine = engine
            self.source = source
            try engine.start()
            DebugLog.print("[Audio] Stereo source started; queue ceiling=200ms, catch-up threshold=100ms")
        } catch {
            engine?.stop(); engine = nil; source = nil
            DebugLog.print("[Audio] Start failed: \(error)")
        }
    }
    func enqueueSamples(_ data: Data, sampleCount: Int) {
        guard sampleCount > 0, sampleCount <= data.count / 2, sampleCount % channels == 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            ring.write(base.assumingMemoryBound(to: Int16.self), count: sampleCount)
        }
        receivedSamples += sampleCount
        if receivedSamples >= sampleRate * channels * 2 {
            receivedSamples = 0
            let milliseconds = Double(ring.availableSamples) * 1000 / Double(sampleRate * channels)
            DebugLog.print("[Audio] queued=\(String(format: "%.1f", milliseconds))ms discardedStereoFrames=\(ring.discardedSamples / channels)")
        }
    }
    /// The session joins native callbacks before calling stop.
    func stop() {
        engine?.stop(); engine = nil; source = nil
        ring.reset()
    }
}
