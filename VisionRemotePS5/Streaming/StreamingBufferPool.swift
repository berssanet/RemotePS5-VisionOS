//
//  StreamingBufferPool.swift
//  VisionRemotePS5
//
//  High-performance buffer pooling for streaming video/audio data.
//  Eliminates garbage collection pressure by reusing pre-allocated buffers.
//

import Foundation

// MARK: - Pooled Buffer

/// A buffer from the pool that automatically returns to the pool when released.
/// Use `data` property to access the underlying bytes.
final class PooledBuffer: @unchecked Sendable {
    
    /// The underlying storage
    private let storage: UnsafeMutableRawPointer
    
    /// Capacity of the buffer in bytes
    let capacity: Int
    
    /// Current valid data length (set after writing data)
    private(set) var count: Int = 0
    
    /// The pool this buffer belongs to (weak to avoid retain cycles)
    private weak var pool: StreamingBufferPool?
    
    /// Whether this buffer is currently in use
    private(set) var isInUse: Bool = true
    
    // MARK: - Initialization
    
    init(capacity: Int, pool: StreamingBufferPool?) {
        self.capacity = capacity
        self.pool = pool
        self.storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }
    
    deinit {
        storage.deallocate()
    }
    
    // MARK: - Data Access
    
    /// Get raw pointer to the buffer storage
    var bytes: UnsafeMutableRawPointer {
        return storage
    }
    
    /// Get typed pointer for convenience
    func withUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        return try body(UnsafeMutableRawBufferPointer(start: storage, count: capacity))
    }
    
    /// Copy data into this buffer
    func write(_ data: Data) {
        let bytesToCopy = min(data.count, capacity)
        data.withUnsafeBytes { src in
            storage.copyMemory(from: src.baseAddress!, byteCount: bytesToCopy)
        }
        count = bytesToCopy
    }
    
    /// Copy from raw bytes into this buffer
    func write(_ source: UnsafeRawPointer, count: Int) {
        let bytesToCopy = min(count, capacity)
        storage.copyMemory(from: source, byteCount: bytesToCopy)
        self.count = bytesToCopy
    }
    
    /// Set the valid data length (after external writes)
    func setCount(_ newCount: Int) {
        count = min(newCount, capacity)
    }
    
    /// Create a Data view of the valid portion (zero-copy if possible)
    var data: Data {
        return Data(bytesNoCopy: storage, count: count, deallocator: .none)
    }
    
    /// Return this buffer to the pool for reuse
    func release() {
        guard isInUse else { return }
        isInUse = false
        count = 0
        pool?.returnBuffer(self)
    }
    
    /// Reset for reuse
    func reset() {
        count = 0
        isInUse = true
    }
}

// MARK: - Buffer Pool

/// Thread-safe pool of reusable buffers for high-frequency streaming data.
///
/// Typical usage:
/// ```swift
/// let pool = StreamingBufferPool(bufferSize: 65536, poolSize: 16)
/// 
/// // In receive loop:
/// if let buffer = pool.acquire() {
///     defer { buffer.release() }
///     buffer.write(receivedData)
///     processData(buffer.data)
/// }
/// ```
final class StreamingBufferPool: @unchecked Sendable {
    
    /// Size of each buffer in the pool
    let bufferSize: Int
    
    /// Maximum number of buffers in the pool
    let maxPoolSize: Int
    
    /// Available buffers ready for use
    private var availableBuffers: [PooledBuffer] = []
    
    /// Lock for thread-safe access
    private let lock = NSLock()
    
    /// Statistics
    private(set) var allocatedCount: Int = 0
    private(set) var acquireCount: UInt64 = 0
    private(set) var releaseCount: UInt64 = 0
    private(set) var missCount: UInt64 = 0  // Times we had to allocate new buffer
    
    // MARK: - Initialization
    
    /// Create a buffer pool
    /// - Parameters:
    ///   - bufferSize: Size of each buffer in bytes (default: 64KB for UDP MTU)
    ///   - poolSize: Number of buffers to pre-allocate (default: 16)
    init(bufferSize: Int = 65536, poolSize: Int = 16) {
        self.bufferSize = bufferSize
        self.maxPoolSize = poolSize
        
        // Pre-allocate buffers
        for _ in 0..<poolSize {
            let buffer = PooledBuffer(capacity: bufferSize, pool: self)
            buffer.release() // Mark as available
            availableBuffers.append(buffer)
            allocatedCount += 1
        }
        
        DebugLog.print("[BufferPool] Initialized with \(poolSize) buffers of \(bufferSize) bytes")
    }
    
    // MARK: - Acquire/Release
    
    /// Acquire a buffer from the pool.
    /// Returns nil only if the pool and allocation limit are exhausted (should never happen).
    func acquire() -> PooledBuffer? {
        lock.lock()
        defer { lock.unlock() }
        
        acquireCount += 1
        
        // Try to get from pool
        if let buffer = availableBuffers.popLast() {
            buffer.reset()
            return buffer
        }
        
        // Pool exhausted - allocate new buffer if under limit
        missCount += 1
        
        if allocatedCount < maxPoolSize * 2 {
            // Allow up to 2x pool size for burst handling
            allocatedCount += 1
            let buffer = PooledBuffer(capacity: bufferSize, pool: self)
            DebugLog.print("[BufferPool] ⚠️ Pool miss #\(missCount), allocated new buffer (total: \(allocatedCount))")
            return buffer
        }
        
        // Absolutely out of buffers - this shouldn't happen in normal operation
        DebugLog.print("[BufferPool] ❌ Pool exhausted!")
        return nil
    }
    
    /// Return a buffer to the pool
    func returnBuffer(_ buffer: PooledBuffer) {
        lock.lock()
        defer { lock.unlock() }
        
        releaseCount += 1
        
        // Only keep up to maxPoolSize buffers
        if availableBuffers.count < maxPoolSize {
            availableBuffers.append(buffer)
        }
        // If over limit, let the buffer deallocate naturally
    }
    
    /// Get pool statistics
    var statistics: String {
        lock.lock()
        defer { lock.unlock() }
        
        let hitRate = acquireCount > 0 ? 
            Double(acquireCount - missCount) / Double(acquireCount) * 100.0 : 100.0
        
        return "[BufferPool] acquired: \(acquireCount), released: \(releaseCount), " +
               "misses: \(missCount), hit rate: \(String(format: "%.1f", hitRate))%"
    }
}

// MARK: - Crypto Buffer Pool

/// Specialized buffer pool for decryption operations.
/// Provides a pair of buffers for ciphertext and plaintext.
final class CryptoBufferPool: @unchecked Sendable {
    
    /// Pool for ciphertext input
    let inputPool: StreamingBufferPool
    
    /// Pool for plaintext output
    let outputPool: StreamingBufferPool
    
    init(bufferSize: Int = 65536, poolSize: Int = 8) {
        self.inputPool = StreamingBufferPool(bufferSize: bufferSize, poolSize: poolSize)
        self.outputPool = StreamingBufferPool(bufferSize: bufferSize, poolSize: poolSize)
    }
    
    /// Acquire a pair of buffers for crypto operation
    func acquire() -> (input: PooledBuffer, output: PooledBuffer)? {
        guard let input = inputPool.acquire(),
              let output = outputPool.acquire() else {
            return nil
        }
        return (input, output)
    }
}
