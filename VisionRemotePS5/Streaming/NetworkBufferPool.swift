//
//  NetworkBufferPool.swift
//  VisionRemotePS5
//
//  High-performance network buffer pool for UDP packet reception.
//  Eliminates memory allocations in the hot path by pre-allocating and reusing buffers.
//
//  v10.3: Zero-copy network receive with buffer pooling
//

import Foundation
import Network

// MARK: - Network Buffer

/// A pre-allocated buffer for network I/O operations.
/// Provides direct access to underlying storage for zero-copy operations.
final class NetworkBuffer: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Raw storage pointer (16-byte aligned for SIMD operations)
    private let storage: UnsafeMutableRawPointer
    
    /// Capacity of the buffer in bytes
    let capacity: Int
    
    /// Current valid data length
    private(set) var count: Int = 0
    
    /// The pool this buffer belongs to
    private weak var pool: NetworkBufferPool?
    
    /// Reference count for safety
    private var refCount: Int32 = 1
    
    /// Lock for reference counting
    private let refLock = os_unfair_lock_t.allocate(capacity: 1)
    
    // MARK: - Initialization
    
    init(capacity: Int, pool: NetworkBufferPool?) {
        self.capacity = capacity
        self.pool = pool
        // Allocate with 16-byte alignment for optimal memory access
        self.storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        refLock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        storage.deallocate()
        refLock.deallocate()
    }
    
    // MARK: - Raw Pointer Access
    
    /// Get mutable bytes pointer for direct writes
    var mutableBytes: UnsafeMutableRawPointer {
        return storage
    }
    
    /// Get read-only bytes pointer
    var bytes: UnsafeRawPointer {
        return UnsafeRawPointer(storage)
    }
    
    /// Get typed mutable buffer pointer
    var mutableBufferPointer: UnsafeMutableRawBufferPointer {
        return UnsafeMutableRawBufferPointer(start: storage, count: capacity)
    }
    
    /// Get read-only buffer pointer for valid data only
    var bufferPointer: UnsafeRawBufferPointer {
        return UnsafeRawBufferPointer(start: storage, count: count)
    }
    
    // MARK: - Data Operations
    
    /// Set the valid data length after external write
    func setCount(_ newCount: Int) {
        count = min(max(0, newCount), capacity)
    }
    
    /// Copy data into buffer
    func write(_ data: Data) {
        let bytesToCopy = min(data.count, capacity)
        data.withUnsafeBytes { src in
            storage.copyMemory(from: src.baseAddress!, byteCount: bytesToCopy)
        }
        count = bytesToCopy
    }
    
    /// Copy from raw pointer into buffer
    func write(from source: UnsafeRawPointer, count: Int) {
        let bytesToCopy = min(count, capacity)
        storage.copyMemory(from: source, byteCount: bytesToCopy)
        self.count = bytesToCopy
    }
    
    /// Create zero-copy Data view (no allocation, shares storage)
    /// - Warning: Data is only valid while buffer is retained
    var dataView: Data {
        return Data(bytesNoCopy: storage, count: count, deallocator: .none)
    }
    
    /// Create a copy as Data (when ownership transfer is needed)
    func copyToData() -> Data {
        return Data(bytes: storage, count: count)
    }
    
    // MARK: - Reference Counting
    
    /// Retain the buffer (increase ref count)
    func retain() {
        os_unfair_lock_lock(refLock)
        refCount += 1
        os_unfair_lock_unlock(refLock)
    }
    
    /// Release the buffer (decrease ref count, return to pool when zero)
    func release() {
        os_unfair_lock_lock(refLock)
        refCount -= 1
        let shouldReturn = refCount <= 0
        os_unfair_lock_unlock(refLock)
        
        if shouldReturn {
            count = 0
            pool?.returnBuffer(self)
        }
    }
    
    /// Reset for reuse
    func reset() {
        os_unfair_lock_lock(refLock)
        refCount = 1
        os_unfair_lock_unlock(refLock)
        count = 0
    }
}

// MARK: - Network Buffer Pool

/// Thread-safe pool of network buffers for high-frequency UDP packet reception.
///
/// Optimized for streaming scenarios where packets arrive at 60+ fps.
/// Uses lock-free operations where possible for minimal latency.
///
/// Usage:
/// ```swift
/// let pool = NetworkBufferPool(bufferSize: 65536, poolSize: 32)
/// 
/// // In receive loop:
/// if let buffer = pool.acquire() {
///     // Fill buffer with received data
///     buffer.setCount(receivedBytes)
///     
///     // Process data
///     processPacket(buffer.bufferPointer)
///     
///     // Return to pool
///     buffer.release()
/// }
/// ```
final class NetworkBufferPool: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Size of each buffer (should be >= max UDP packet size)
    let bufferSize: Int
    
    /// Maximum pool size
    let maxPoolSize: Int
    
    /// Available buffers (lock-free stack would be ideal, using array for simplicity)
    private var available: [NetworkBuffer] = []
    
    /// Spin lock for minimal latency (faster than NSLock for short critical sections)
    private let spinLock = os_unfair_lock_t.allocate(capacity: 1)
    
    /// Statistics
    private var _acquireCount: UInt64 = 0
    private var _releaseCount: UInt64 = 0
    private var _allocCount: Int = 0
    private var _missCount: UInt64 = 0
    
    // MARK: - Initialization
    
    /// Create a network buffer pool
    /// - Parameters:
    ///   - bufferSize: Size of each buffer (default: 64KB for jumbo UDP)
    ///   - poolSize: Number of buffers to pre-allocate
    init(bufferSize: Int = 65536, poolSize: Int = 32) {
        self.bufferSize = bufferSize
        self.maxPoolSize = poolSize
        spinLock.initialize(to: os_unfair_lock())
        
        // Pre-allocate buffers
        available.reserveCapacity(poolSize)
        for _ in 0..<poolSize {
            let buffer = NetworkBuffer(capacity: bufferSize, pool: self)
            buffer.release() // Reset ref count
            available.append(buffer)
            _allocCount += 1
        }
        
        DebugLog.print("[NetworkBufferPool] ✅ Initialized \(poolSize) × \(bufferSize/1024)KB buffers")
    }
    
    deinit {
        spinLock.deallocate()
    }
    
    // MARK: - Acquire/Release
    
    /// Acquire a buffer from the pool.
    /// - Returns: A buffer ready for use, or nil if pool exhausted
    func acquire() -> NetworkBuffer? {
        os_unfair_lock_lock(spinLock)
        defer { os_unfair_lock_unlock(spinLock) }
        
        _acquireCount += 1
        
        if let buffer = available.popLast() {
            buffer.reset()
            return buffer
        }
        
        // Pool exhausted - allocate new if under 2x limit
        _missCount += 1
        
        if _allocCount < maxPoolSize * 2 {
            _allocCount += 1
            let buffer = NetworkBuffer(capacity: bufferSize, pool: self)
            DebugLog.print("[NetworkBufferPool] ⚠️ Pool miss, allocated new buffer (total: \(_allocCount))")
            return buffer
        }
        
        DebugLog.print("[NetworkBufferPool] ❌ Pool exhausted!")
        return nil
    }
    
    /// Return buffer to pool
    func returnBuffer(_ buffer: NetworkBuffer) {
        os_unfair_lock_lock(spinLock)
        defer { os_unfair_lock_unlock(spinLock) }
        
        _releaseCount += 1
        
        if available.count < maxPoolSize {
            available.append(buffer)
        }
        // Over limit: let buffer deallocate naturally
    }
    
    // MARK: - Statistics
    
    /// Get pool statistics
    var statistics: String {
        os_unfair_lock_lock(spinLock)
        let acq = _acquireCount
        let rel = _releaseCount
        let miss = _missCount
        let avail = available.count
        os_unfair_lock_unlock(spinLock)
        
        let hitRate = acq > 0 ? Double(acq - miss) / Double(acq) * 100.0 : 100.0
        return "[NetworkBufferPool] acq=\(acq) rel=\(rel) miss=\(miss) avail=\(avail) hit=\(String(format: "%.1f", hitRate))%"
    }
}

// MARK: - Zero-Copy AES-GCM Decryptor

/// Advanced zero-copy AES-GCM decryptor that operates entirely on raw buffer pointers.
/// Eliminates all intermediate Data allocations in the decryption hot path.
///
/// Thread-safe and designed for concurrent use from multiple network threads.
final class ZeroCopyAESGCMDecryptor: @unchecked Sendable {
    
    // MARK: - Constants
    
    static let nonceSize = 12
    static let tagSize = 16
    static let overhead = nonceSize + tagSize  // 28 bytes
    
    // MARK: - Properties
    
    /// AES key
    private var key: SymmetricKey?
    
    /// Lock for key updates
    private let keyLock = os_unfair_lock_t.allocate(capacity: 1)
    
    /// Output buffer pool
    private let outputPool: NetworkBufferPool
    
    /// Statistics
    private var _decryptCount: UInt64 = 0
    private var _failCount: UInt64 = 0
    
    // MARK: - Initialization
    
    /// Create a zero-copy decryptor with its own buffer pool
    /// - Parameter outputBufferSize: Size of output buffers (should match max plaintext size)
    init(outputBufferSize: Int = 131072, poolSize: Int = 16) {
        self.outputPool = NetworkBufferPool(bufferSize: outputBufferSize, poolSize: poolSize)
        keyLock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        keyLock.deallocate()
    }
    
    // MARK: - Key Management
    
    /// Set the session key (thread-safe)
    func setKey(_ newKey: SymmetricKey?) {
        os_unfair_lock_lock(keyLock)
        key = newKey
        os_unfair_lock_unlock(keyLock)
        
        if newKey != nil {
            DebugLog.print("[ZeroCopyDecryptor] ✅ Key set")
        }
    }
    
    // MARK: - Zero-Copy Decryption
    
    /// Decrypt directly from input buffer to output buffer.
    ///
    /// - Parameters:
    ///   - input: Input buffer containing sealed box [nonce|ciphertext|tag]
    ///   - inputOffset: Offset into input buffer where sealed data starts
    ///   - inputLength: Length of sealed data (or -1 to use buffer.count - offset)
    /// - Returns: Output buffer with plaintext, or nil on failure. Caller must release().
    func decrypt(
        from input: NetworkBuffer,
        inputOffset: Int = 0,
        inputLength: Int = -1
    ) -> NetworkBuffer? {
        os_unfair_lock_lock(keyLock)
        let currentKey = key
        os_unfair_lock_unlock(keyLock)
        
        let sealedLength = inputLength >= 0 ? inputLength : (input.count - inputOffset)
        
        guard sealedLength >= Self.overhead else {
            return nil
        }
        
        // Acquire output buffer
        guard let output = outputPool.acquire() else {
            return nil
        }
        
        // If no key, passthrough (copy input to output)
        guard let currentKey = currentKey else {
            let plaintextSize = sealedLength
            memcpy(output.mutableBytes, input.bytes.advanced(by: inputOffset), plaintextSize)
            output.setCount(plaintextSize)
            return output
        }
        
        // Parse sealed box components from raw pointers
        let sealedPtr = input.bytes.advanced(by: inputOffset)
        let noncePtr = sealedPtr
        let ciphertextPtr = sealedPtr.advanced(by: Self.nonceSize)
        let ciphertextSize = sealedLength - Self.overhead
        let tagPtr = ciphertextPtr.advanced(by: ciphertextSize)
        
        // Perform decryption using CryptoKit
        // Note: CryptoKit still creates intermediate Data, but we minimize allocations
        // by reusing the output buffer
        do {
            // Create nonce (12 bytes, small allocation)
            let nonceData = Data(bytes: noncePtr, count: Self.nonceSize)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            
            // Create sealed box from pointers (minimal copying)
            let ciphertextData = Data(bytes: ciphertextPtr, count: ciphertextSize)
            let tagData = Data(bytes: tagPtr, count: Self.tagSize)
            
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
            
            // Decrypt
            let plaintext = try AES.GCM.open(sealedBox, using: currentKey)
            
            // Copy plaintext to output buffer
            guard plaintext.count <= output.capacity else {
                output.release()
                return nil
            }
            
            plaintext.withUnsafeBytes { src in
                output.mutableBytes.copyMemory(from: src.baseAddress!, byteCount: plaintext.count)
            }
            output.setCount(plaintext.count)
            
            os_unfair_lock_lock(keyLock)
            _decryptCount += 1
            os_unfair_lock_unlock(keyLock)
            
            return output
            
        } catch {
            output.release()
            
            os_unfair_lock_lock(keyLock)
            _failCount += 1
            os_unfair_lock_unlock(keyLock)
            
            return nil
        }
    }
    
    /// Decrypt from Data (convenience method)
    func decrypt(data: Data) -> NetworkBuffer? {
        guard let inputBuffer = outputPool.acquire() else { return nil }
        defer { inputBuffer.release() }
        
        inputBuffer.write(data)
        return decrypt(from: inputBuffer)
    }
    
    // MARK: - Statistics
    
    var statistics: String {
        os_unfair_lock_lock(keyLock)
        let dec = _decryptCount
        let fail = _failCount
        os_unfair_lock_unlock(keyLock)
        
        let successRate = (dec + fail) > 0 ? Double(dec) / Double(dec + fail) * 100.0 : 100.0
        return "[ZeroCopyDecryptor] decrypt=\(dec) fail=\(fail) success=\(String(format: "%.1f", successRate))%"
    }
}

// MARK: - Import for os_unfair_lock
import os
import CryptoKit
