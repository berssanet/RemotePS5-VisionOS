import Foundation

// MARK: - Lock-Free SPSC Ring Buffer

/// High-performance lock-free ring buffer for single producer/single consumer audio streaming.
///
/// Design principles:
/// - **True lock-free**: Uses volatile-like access patterns optimized for SPSC
/// - **SPSC optimized**: Single producer (audio callback) and single consumer (render thread)
/// - **Minimal critical path**: No locks, only memory barriers at position updates
/// - **Zero-copy memcpy**: Direct memory operations for minimal latency
///
/// Thread safety:
/// - `write()`: Only called from producer thread (chiaki audio callback)
/// - `read()`: Only called from consumer thread (AVAudioSourceNode render callback)
/// - `availableSamples`: Safe to read from any thread
/// - `reset()`: Only call when both threads are stopped
final class AudioRingBuffer: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Total capacity in samples
    let capacity: Int
    
    /// Raw audio buffer storage
    private let buffer: UnsafeMutablePointer<Int16>
    
    // MARK: - Position Indices
    
    /// Read position (consumer-owned, read by producer)
    /// Using UnsafeMutablePointer for atomic-like access patterns
    private let readPosition: UnsafeMutablePointer<Int>
    
    /// Write position (producer-owned, read by consumer)
    private let writePosition: UnsafeMutablePointer<Int>
    
    // MARK: - Statistics
    
    /// Number of samples currently available to read (thread-safe)
    var availableSamples: Int {
        // volatile-style reads with compiler barrier
        let write = loadAcquire(writePosition)
        let read = loadAcquire(readPosition)
        
        if write >= read {
            return write - read
        } else {
            return capacity - read + write
        }
    }
    
    /// Number of samples that can be written (thread-safe)
    var availableSpace: Int {
        // -1 to distinguish full from empty
        return capacity - availableSamples - 1
    }
    
    // MARK: - Initialization
    
    /// Initialize with capacity in number of samples (not bytes)
    init(capacity: Int) {
        self.capacity = capacity
        
        // Allocate audio buffer
        self.buffer = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
        
        // Allocate position storage
        self.readPosition = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        self.writePosition = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        
        readPosition.initialize(to: 0)
        writePosition.initialize(to: 0)
    }
    
    deinit {
        buffer.deallocate()
        readPosition.deallocate()
        writePosition.deallocate()
    }
    
    // MARK: - Producer API (Audio Callback Thread)
    
    /// Write samples to the buffer.
    /// **Thread safety**: Only call from producer thread.
    /// - Parameters:
    ///   - samples: Pointer to source samples
    ///   - count: Number of samples to write
    /// - Returns: Number of samples actually written
    @discardableResult
    @inline(__always)
    func write(_ samples: UnsafePointer<Int16>, count: Int) -> Int {
        // Load current read position (acquire - see consumer's writes)
        let readPos = loadAcquire(readPosition)
        // Local load of our own position (no barrier needed - we own it)
        let writePos = writePosition.pointee
        
        // Calculate available space
        let available: Int
        if writePos >= readPos {
            available = capacity - (writePos - readPos) - 1
        } else {
            available = readPos - writePos - 1
        }
        
        let toWrite = min(count, available)
        guard toWrite > 0 else { return 0 }
        
        // Calculate wrap-around parts
        let firstPart = min(toWrite, capacity - writePos)
        let secondPart = toWrite - firstPart
        
        // Copy data - main work
        memcpy(buffer.advanced(by: writePos), samples, firstPart * MemoryLayout<Int16>.stride)
        
        if secondPart > 0 {
            memcpy(buffer, samples.advanced(by: firstPart), secondPart * MemoryLayout<Int16>.stride)
        }
        
        // Update write position with release semantics
        // Consumer will see all buffer writes before this position update
        let newWritePos = (writePos + toWrite) % capacity
        storeRelease(writePosition, value: newWritePos)
        
        return toWrite
    }
    
    /// Write from Data (convenience method)
    @discardableResult
    @inline(__always)
    func write(_ data: Data) -> Int {
        return data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return 0
            }
            let sampleCount = rawBuffer.count / MemoryLayout<Int16>.stride
            return write(samples, count: sampleCount)
        }
    }
    
    // MARK: - Consumer API (Render Thread)
    
    /// Read samples from the buffer.
    /// **Thread safety**: Only call from consumer thread.
    /// - Parameters:
    ///   - destination: Pointer to destination buffer
    ///   - count: Number of samples requested
    /// - Returns: Number of samples actually read
    @discardableResult
    @inline(__always)
    func read(_ destination: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        // Load current write position (acquire - see producer's writes)
        let writePos = loadAcquire(writePosition)
        // Local load of our own position
        let readPos = readPosition.pointee
        
        // Calculate available samples
        let available: Int
        if writePos >= readPos {
            available = writePos - readPos
        } else {
            available = capacity - readPos + writePos
        }
        
        let toRead = min(count, available)
        
        if toRead == 0 {
            // Fill with silence - critical for audio continuity
            memset(destination, 0, count * MemoryLayout<Int16>.stride)
            return 0
        }
        
        // Calculate wrap-around parts
        let firstPart = min(toRead, capacity - readPos)
        let secondPart = toRead - firstPart
        
        // Copy data
        memcpy(destination, buffer.advanced(by: readPos), firstPart * MemoryLayout<Int16>.stride)
        
        if secondPart > 0 {
            memcpy(destination.advanced(by: firstPart), buffer, secondPart * MemoryLayout<Int16>.stride)
        }
        
        // Fill remaining with silence if needed
        if toRead < count {
            memset(destination.advanced(by: toRead), 0, (count - toRead) * MemoryLayout<Int16>.stride)
        }
        
        // Update read position with release semantics
        let newReadPos = (readPos + toRead) % capacity
        storeRelease(readPosition, value: newReadPos)
        
        return toRead
    }
    
    // MARK: - Control
    
    /// Reset the buffer. **Only call when both threads are stopped.**
    func reset() {
        readPosition.pointee = 0
        writePosition.pointee = 0
    }
    
    /// Skip samples without reading them (fast discard for drift correction).
    /// **Thread safety**: Only call from consumer thread.
    /// - Parameter count: Number of samples to skip
    /// - Returns: Number of samples actually skipped
    @discardableResult
    @inline(__always)
    func skip(_ count: Int) -> Int {
        // Load current write position (acquire - see producer's writes)
        let writePos = loadAcquire(writePosition)
        let readPos = readPosition.pointee
        
        // Calculate available samples
        let available: Int
        if writePos >= readPos {
            available = writePos - readPos
        } else {
            available = capacity - readPos + writePos
        }
        
        let toSkip = min(count, available)
        guard toSkip > 0 else { return 0 }
        
        // Update read position with release semantics
        let newReadPos = (readPos + toSkip) % capacity
        storeRelease(readPosition, value: newReadPos)
        
        return toSkip
    }
    
    /// Emergency fast discard for latency spike recovery.
    /// Keeps only `keepSamples` in buffer, discards the rest.
    /// **Thread safety**: Only call from consumer thread.
    /// - Parameter keepSamples: Number of samples to keep (target buffer level)
    /// - Returns: Number of samples discarded
    @discardableResult
    func fastDiscard(keepSamples: Int) -> Int {
        let available = availableSamples
        let toDiscard = max(0, available - keepSamples)
        
        if toDiscard > 0 {
            return skip(toDiscard)
        }
        return 0
    }
    
    /// Get buffer level as percentage (0.0-1.0)
    var fillLevel: Float {
        return Float(availableSamples) / Float(max(capacity - 1, 1))
    }
    
    /// Get buffer level in milliseconds (for sample rate)
    func bufferMs(sampleRate: Int) -> Double {
        return Double(availableSamples) / Double(sampleRate) * 1000.0
    }
    
    // MARK: - Private: Memory Ordering Primitives
    
    /// Load with acquire semantics - ensures subsequent reads see prior writes from other thread.
    /// On ARM64 (Apple Silicon), this compiles to LDAR instruction.
    @inline(__always)
    private func loadAcquire(_ ptr: UnsafeMutablePointer<Int>) -> Int {
        // Compiler barrier + atomic load
        // Swift's pointer access is already sequentially consistent on Apple platforms,
        // but we add explicit barrier for clarity and safety
        let value = ptr.pointee
        
        // Acquire barrier: no loads/stores after this can be reordered before
        // On ARM64, this is a dmb ishld (data memory barrier, inner shareable, load)
        OSMemoryBarrier()
        
        return value
    }
    
    /// Store with release semantics - ensures prior writes are visible before this store.
    /// On ARM64 (Apple Silicon), this compiles to STLR instruction.
    @inline(__always)
    private func storeRelease(_ ptr: UnsafeMutablePointer<Int>, value: Int) {
        // Release barrier: no loads/stores before this can be reordered after
        // On ARM64, this is a dmb ish (data memory barrier, inner shareable)
        OSMemoryBarrier()
        
        // Store the value
        ptr.pointee = value
    }
}
