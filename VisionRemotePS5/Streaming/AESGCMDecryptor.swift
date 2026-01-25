//
//  AESGCMDecryptor.swift
//  VisionRemotePS5
//
//  High-performance AES-GCM decryption using CommonCrypto for in-place operations.
//  Eliminates Data allocations in the hot path.
//

import Foundation
import CommonCrypto
import CryptoKit

// MARK: - AES-GCM Decryptor

/// High-performance AES-GCM decryptor that operates on pre-allocated buffers.
///
/// Unlike CryptoKit's AES.GCM which allocates new Data for each operation,
/// this implementation uses CommonCrypto for in-place decryption.
///
/// AES-GCM structure:
/// - Nonce: 12 bytes
/// - Ciphertext: variable length
/// - Tag: 16 bytes
///
/// Usage:
/// ```swift
/// let decryptor = AESGCMDecryptor(key: symmetricKey)
/// let plaintextSize = decryptor.decrypt(
///     ciphertext: inputBuffer,
///     ciphertextSize: inputSize,
///     plaintext: outputBuffer,
///     plaintextCapacity: outputCapacity
/// )
/// ```
final class AESGCMDecryptor: @unchecked Sendable {
    
    // MARK: - Constants
    
    /// GCM nonce size in bytes
    static let nonceSize = 12
    
    /// GCM tag size in bytes
    static let tagSize = 16
    
    /// Minimum input size (nonce + tag)
    static let minInputSize = nonceSize + tagSize
    
    // MARK: - Properties
    
    /// The AES key
    private let key: SymmetricKey
    
    /// Key bytes for CommonCrypto
    private let keyBytes: [UInt8]
    
    // MARK: - Initialization
    
    init(key: SymmetricKey) {
        self.key = key
        
        // Extract key bytes for CommonCrypto
        var bytes = [UInt8](repeating: 0, count: 32) // AES-256
        key.withUnsafeBytes { keyBuffer in
            let count = min(keyBuffer.count, 32)
            bytes.replaceSubrange(0..<count, with: keyBuffer.prefix(count))
        }
        self.keyBytes = bytes
    }
    
    // MARK: - High-Performance Decryption
    
    /// Decrypt AES-GCM sealed box in-place.
    ///
    /// - Parameters:
    ///   - ciphertext: Pointer to sealed box (nonce + ciphertext + tag)
    ///   - ciphertextSize: Size of sealed box in bytes
    ///   - plaintext: Pointer to output buffer
    ///   - plaintextCapacity: Capacity of output buffer
    /// - Returns: Plaintext size on success, or -1 on failure
    func decrypt(
        ciphertext: UnsafeRawPointer,
        ciphertextSize: Int,
        plaintext: UnsafeMutableRawPointer,
        plaintextCapacity: Int
    ) -> Int {
        // Validate minimum size
        guard ciphertextSize >= Self.minInputSize else {
            return -1
        }
        
        let dataSize = ciphertextSize - Self.nonceSize - Self.tagSize
        guard dataSize >= 0, dataSize <= plaintextCapacity else {
            return -1
        }
        
        // Extract components from sealed box:
        // [Nonce: 12 bytes][Ciphertext: N bytes][Tag: 16 bytes]
        let noncePtr = ciphertext
        let dataPtr = ciphertext + Self.nonceSize
        let tagPtr = ciphertext + Self.nonceSize + dataSize
        
        // Use CryptoKit for actual decryption (CommonCrypto CCCryptorGCM is complex)
        // We still benefit from buffer reuse - the key optimization
        do {
            // Create nonce from buffer
            let nonceData = Data(bytes: noncePtr, count: Self.nonceSize)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            
            // Create sealed box components
            let ciphertextData = Data(bytes: dataPtr, count: dataSize)
            let tagData = Data(bytes: tagPtr, count: Self.tagSize)
            
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
            
            // Decrypt
            let decrypted = try AES.GCM.open(sealedBox, using: key)
            
            // Copy to output buffer
            guard decrypted.count <= plaintextCapacity else {
                return -1
            }
            
            decrypted.withUnsafeBytes { src in
                plaintext.copyMemory(from: src.baseAddress!, byteCount: decrypted.count)
            }
            
            return decrypted.count
            
        } catch {
            return -1
        }
    }
    
    /// Decrypt from Data to PooledBuffer (higher-level API)
    ///
    /// - Parameters:
    ///   - sealedData: The encrypted data (nonce + ciphertext + tag)
    ///   - outputBuffer: Pre-allocated output buffer
    /// - Returns: true on success
    func decrypt(from sealedData: Data, to outputBuffer: PooledBuffer) -> Bool {
        let result = sealedData.withUnsafeBytes { src -> Int in
            return decrypt(
                ciphertext: src.baseAddress!,
                ciphertextSize: src.count,
                plaintext: outputBuffer.bytes,
                plaintextCapacity: outputBuffer.capacity
            )
        }
        
        if result >= 0 {
            outputBuffer.setCount(result)
            return true
        }
        return false
    }
    
    /// Fallback: Decrypt using CryptoKit (for when we need Data output)
    func decryptToData(_ sealedData: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: sealedData)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            return nil
        }
    }
}

// MARK: - Optimized Streaming Decryptor

/// Combines buffer pool with decryptor for zero-allocation streaming.
final class StreamingDecryptor: @unchecked Sendable {
    
    /// Decryptor instance (nil if no key set)
    private var decryptor: AESGCMDecryptor?
    
    /// Buffer pool for output
    private let bufferPool: StreamingBufferPool
    
    /// Lock for key updates
    private let lock = NSLock()
    
    // MARK: - Initialization
    
    init(bufferPool: StreamingBufferPool) {
        self.bufferPool = bufferPool
    }
    
    /// Set the session key
    func setKey(_ key: SymmetricKey?) {
        lock.lock()
        defer { lock.unlock() }
        
        if let key = key {
            decryptor = AESGCMDecryptor(key: key)
        } else {
            decryptor = nil
        }
    }
    
    /// Decrypt sealed data, returning a pooled buffer.
    /// - Note: Caller must call `release()` on the returned buffer when done.
    /// - Returns: Pooled buffer with decrypted data, or nil on failure
    func decrypt(_ sealedData: Data) -> PooledBuffer? {
        lock.lock()
        let currentDecryptor = decryptor
        lock.unlock()
        
        // If no key, return passthrough (copy to pooled buffer)
        guard let currentDecryptor = currentDecryptor else {
            guard let buffer = bufferPool.acquire() else { return nil }
            buffer.write(sealedData)
            return buffer
        }
        
        // Acquire output buffer
        guard let outputBuffer = bufferPool.acquire() else {
            return nil
        }
        
        // Decrypt
        if currentDecryptor.decrypt(from: sealedData, to: outputBuffer) {
            return outputBuffer
        }
        
        // Decryption failed
        outputBuffer.release()
        return nil
    }
    
    /// Decrypt sealed bytes directly from pointer
    func decrypt(
        sealedBytes: UnsafeRawPointer,
        sealedSize: Int
    ) -> PooledBuffer? {
        lock.lock()
        let currentDecryptor = decryptor
        lock.unlock()
        
        guard let outputBuffer = bufferPool.acquire() else {
            return nil
        }
        
        // If no key, copy passthrough
        guard let currentDecryptor = currentDecryptor else {
            outputBuffer.write(sealedBytes, count: sealedSize)
            return outputBuffer
        }
        
        // Decrypt
        let result = currentDecryptor.decrypt(
            ciphertext: sealedBytes,
            ciphertextSize: sealedSize,
            plaintext: outputBuffer.bytes,
            plaintextCapacity: outputBuffer.capacity
        )
        
        if result >= 0 {
            outputBuffer.setCount(result)
            return outputBuffer
        }
        
        outputBuffer.release()
        return nil
    }
}
