import Foundation

/// Thread-safe lock-free ring buffer for single producer/single consumer audio streaming
/// Uses atomic operations for thread-safety without locks
final class AudioRingBuffer {
    let capacity: Int
    private let buffer: UnsafeMutablePointer<Int16>
    
    // Atomic read/write positions using memory barriers
    private var _readPosition: Int = 0
    private var _writePosition: Int = 0
    
    /// Number of samples currently available to read
    var availableSamples: Int {
        let write = _writePosition
        let read = _readPosition
        
        if write >= read {
            return write - read
        } else {
            return capacity - read + write
        }
    }
    
    /// Number of samples that can be written
    var availableSpace: Int {
        return capacity - availableSamples - 1  // -1 to distinguish full from empty
    }
    
    /// Initialize with capacity in number of samples (not bytes)
    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }
    
    deinit {
        buffer.deallocate()
    }
    
    /// Write samples to the buffer (called from producer thread)
    /// - Returns: Number of samples actually written
    @discardableResult
    func write(_ samples: UnsafePointer<Int16>, count: Int) -> Int {
        let space = availableSpace
        let toWrite = min(count, space)
        
        guard toWrite > 0 else { return 0 }
        
        let writePos = _writePosition
        let firstPart = min(toWrite, capacity - writePos)
        let secondPart = toWrite - firstPart
        
        // Copy first part (from writePos to end of buffer)
        memcpy(buffer.advanced(by: writePos), samples, firstPart * MemoryLayout<Int16>.size)
        
        // Copy second part (from start of buffer, if wrap around)
        if secondPart > 0 {
            memcpy(buffer, samples.advanced(by: firstPart), secondPart * MemoryLayout<Int16>.size)
        }
        
        // Memory barrier before updating write position
        OSMemoryBarrier()
        _writePosition = (writePos + toWrite) % capacity
        
        return toWrite
    }
    
    /// Write from Data (convenience method)
    @discardableResult
    func write(_ data: Data) -> Int {
        return data.withUnsafeBytes { rawBuffer in
            guard let samples = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return 0
            }
            let sampleCount = rawBuffer.count / MemoryLayout<Int16>.size
            return write(samples, count: sampleCount)
        }
    }
    
    /// Read samples from the buffer (called from consumer thread)
    /// - Returns: Number of samples actually read
    @discardableResult
    func read(_ destination: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        let available = availableSamples
        let toRead = min(count, available)
        
        guard toRead > 0 else {
            // Fill with silence if nothing available
            memset(destination, 0, count * MemoryLayout<Int16>.size)
            return 0
        }
        
        let readPos = _readPosition
        let firstPart = min(toRead, capacity - readPos)
        let secondPart = toRead - firstPart
        
        // Copy first part
        memcpy(destination, buffer.advanced(by: readPos), firstPart * MemoryLayout<Int16>.size)
        
        // Copy second part (if wrap around)
        if secondPart > 0 {
            memcpy(destination.advanced(by: firstPart), buffer, secondPart * MemoryLayout<Int16>.size)
        }
        
        // Memory barrier before updating read position
        OSMemoryBarrier()
        _readPosition = (readPos + toRead) % capacity
        
        // If we didn't read enough, fill rest with silence
        if toRead < count {
            memset(destination.advanced(by: toRead), 0, (count - toRead) * MemoryLayout<Int16>.size)
        }
        
        return toRead
    }
    
    /// Reset the buffer (must be called when both threads are stopped)
    func reset() {
        _readPosition = 0
        _writePosition = 0
    }
}
