import Foundation
import AVFoundation
import Combine

/// Decodes Opus audio and plays through AVAudioEngine
class AudioDecoder: ObservableObject {
    @Published var isPlaying = false
    @Published var volume: Float = 1.0 {
        didSet {
            playerNode.volume = volume
        }
    }
    @Published var isMuted = false {
        didSet {
            playerNode.volume = isMuted ? 0 : volume
        }
    }
    
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    
    // Opus decoder state (placeholder - real implementation needs libopus)
    private var opusDecoder: OpaquePointer?
    private let sampleRate: Double = 48000
    private let channels: UInt32 = 2
    private let frameSize: Int = 960 // 20ms at 48kHz
    
    init() {
        setupAudioEngine()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public Methods
    
    func start() throws {
        guard !isPlaying else { return }
        
        try configureAudioSession()
        try audioEngine.start()
        playerNode.play()
        isPlaying = true
    }
    
    func stop() {
        playerNode.stop()
        audioEngine.stop()
        isPlaying = false
    }
    
    /// Decode and play Opus audio packet
    func decodeAndPlay(_ opusData: Data) {
        // Decode Opus to PCM (placeholder implementation)
        guard let pcmData = decodeOpus(opusData) else { return }
        
        // Create audio buffer
        guard let format = audioFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize)) else {
            return
        }
        
        buffer.frameLength = AVAudioFrameCount(frameSize)
        
        // Copy PCM data to buffer
        if let channelData = buffer.floatChannelData {
            pcmData.withUnsafeBytes { ptr in
                guard let samples = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                
                for channel in 0..<Int(channels) {
                    for frame in 0..<frameSize {
                        channelData[channel][frame] = samples[frame * Int(channels) + channel]
                    }
                }
            }
        }
        
        // Schedule buffer for playback
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    // MARK: - Private Methods
    
    private func setupAudioEngine() {
        // Create audio format for output
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )
        
        // Attach and connect nodes
        audioEngine.attach(playerNode)
        
        if let format = audioFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        }
        
        // Configure for spatial audio on Vision Pro
        let mixerNode = audioEngine.mainMixerNode
        mixerNode.renderingAlgorithm = .sphericalHead
        mixerNode.sourceMode = .spatializeIfMono
    }
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
        )
        
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.02) // 20ms
        try session.setActive(true)
    }
    
    private func decodeOpus(_ data: Data) -> Data? {
        // Placeholder: Real implementation requires libopus
        // This simulates decoding by generating silence
        
        let samplesPerFrame = frameSize * Int(channels)
        let pcmData = Data(count: samplesPerFrame * MemoryLayout<Float>.size)
        
        // In real implementation:
        // 1. Call opus_decode_float()
        // 2. Handle any decoding errors
        // 3. Return actual decoded PCM data
        
        return pcmData
    }
}

// MARK: - Audio Capture for Voice Chat

class AudioCapture: ObservableObject {
    @Published var isCapturing = false
    @Published var inputLevel: Float = 0
    
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    
    private var captureCallback: ((Data) -> Void)?
    
    init() {}
    
    deinit {
        stop()
    }
    
    /// Start capturing microphone audio
    func start(onCapture: @escaping (Data) -> Void) throws {
        guard !isCapturing else { return }
        
        captureCallback = onCapture
        
        try configureAudioSession()
        
        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else {
            throw AudioCaptureError.noInputNode
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        try audioEngine.start()
        isCapturing = true
    }
    
    /// Stop capturing
    func stop() {
        inputNode?.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
        captureCallback = nil
    }
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )
        
        try session.setActive(true)
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Calculate input level
        var sum: Float = 0
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) {
                sum += abs(channelData[i])
            }
        }
        
        DispatchQueue.main.async {
            self.inputLevel = sum / Float(buffer.frameLength)
        }
        
        // Convert to Opus and send (placeholder)
        let opusData = encodeToOpus(buffer)
        captureCallback?(opusData)
    }
    
    private func encodeToOpus(_ buffer: AVAudioPCMBuffer) -> Data {
        // Placeholder: Real implementation requires libopus
        // This simulates encoding
        
        // In real implementation:
        // 1. Resample if needed (to 48kHz)
        // 2. Call opus_encode_float()
        // 3. Return encoded Opus packet
        
        return Data()
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputNode
    case configurationFailed
    
    var errorDescription: String? {
        switch self {
        case .noInputNode:
            return "No audio input available"
        case .configurationFailed:
            return "Failed to configure audio capture"
        }
    }
}
