//
//  ConsoleStorageService.swift
//  VisionRemotePS5
//
//  Persistent storage for registered PS5 consoles using Swift Actor.
//  Uses actor isolation for thread-safe access to UserDefaults and Keychain.
//

import Foundation
import Security

// MARK: - Console Storage Actor

/// Actor for persisting registered console data with thread-safe isolation.
///
/// This actor guarantees:
/// - **State isolation**: All properties are protected by actor isolation
/// - **Serialized access**: Concurrent read/write operations are serialized automatically
/// - **No data races**: Swift compiler enforces isolation at compile time
///
/// Usage:
/// ```swift
/// await ConsoleStorageService.shared.saveRegisteredConsole(console)
/// let consoles = await ConsoleStorageService.shared.getRegisteredConsoles()
/// ```
actor ConsoleStorageService {
    
    // MARK: - Singleton
    
    /// Shared instance of the storage service
    static let shared = ConsoleStorageService()
    
    // MARK: - Storage Keys
    
    private let registeredConsolesKey = "registered_consoles"
    private let keychainServicePrefix = "com.visionremote.ps5"
    
    // MARK: - Cached State
    
    /// In-memory cache of registered consoles to avoid repeated disk reads
    private var cachedConsoles: [Console]?
    
    // MARK: - UserDefaults (accessed from actor context)
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Initialization
    
    private init() {
        print("[ConsoleStorage] Actor initialized")
    }
    
    // MARK: - Public API
    
    /// Save a registered console with all its data.
    /// - Parameter console: The console to save
    func saveRegisteredConsole(_ console: Console) {
        var consoles = loadConsolesFromDisk()
        
        // Update or add console
        if let index = consoles.firstIndex(where: { $0.id == console.id || $0.ipAddress == console.ipAddress }) {
            consoles[index] = console
            print("[ConsoleStorage] Updated existing console: \(console.name)")
        } else {
            consoles.append(console)
            print("[ConsoleStorage] Added new console: \(console.name)")
        }
        
        // Save to UserDefaults
        saveConsolesToDisk(consoles)
        
        // Update cache
        cachedConsoles = consoles
        
        // Save RP-Key securely in Keychain
        if let rpKey = console.rpKey {
            saveRPKeyToKeychain(rpKey, for: console)
        }
    }
    
    /// Get all registered consoles.
    /// - Returns: Array of registered consoles with RP-Keys loaded
    func getRegisteredConsoles() -> [Console] {
        // Return cached if available
        if let cached = cachedConsoles {
            return cached
        }
        
        // Load from disk and cache
        let consoles = loadConsolesFromDisk()
        cachedConsoles = consoles
        return consoles
    }
    
    /// Get a specific registered console by IP address.
    /// - Parameter ip: The IP address to search for
    /// - Returns: The console if found
    func getRegisteredConsole(byIP ip: String) -> Console? {
        return getRegisteredConsoles().first { $0.ipAddress == ip }
    }
    
    /// Get a specific registered console by ID.
    /// - Parameter id: The UUID to search for
    /// - Returns: The console if found
    func getRegisteredConsole(byID id: UUID) -> Console? {
        return getRegisteredConsoles().first { $0.id == id }
    }
    
    /// Remove a registered console.
    /// - Parameter console: The console to remove
    func removeRegisteredConsole(_ console: Console) {
        var consoles = getRegisteredConsoles()
        consoles.removeAll { $0.id == console.id || $0.ipAddress == console.ipAddress }
        
        saveConsolesToDisk(consoles)
        cachedConsoles = consoles
        
        // Remove RP-Key from Keychain
        deleteRPKeyFromKeychain(for: console)
        
        print("[ConsoleStorage] Removed console: \(console.name)")
    }
    
    /// Check if a console is registered with valid credentials.
    /// - Parameter ip: The IP address to check
    /// - Returns: True if console is registered with RP-Key
    func isConsoleRegistered(ip: String) -> Bool {
        return getRegisteredConsoles().contains { $0.ipAddress == ip && $0.rpKey != nil }
    }
    
    /// Clear all registered consoles and their credentials.
    func clearAllConsoles() {
        let consoles = getRegisteredConsoles()
        for console in consoles {
            deleteRPKeyFromKeychain(for: console)
        }
        
        defaults.removeObject(forKey: registeredConsolesKey)
        cachedConsoles = []
        
        print("[ConsoleStorage] Cleared all consoles")
    }
    
    /// Invalidate the cache, forcing a reload from disk on next access.
    func invalidateCache() {
        cachedConsoles = nil
    }
    
    // MARK: - Private: Disk Operations
    
    private func loadConsolesFromDisk() -> [Console] {
        guard let data = defaults.data(forKey: registeredConsolesKey) else {
            return []
        }
        
        do {
            var consoles = try JSONDecoder().decode([Console].self, from: data)
            
            // Load RP-Keys from Keychain for each console
            for i in 0..<consoles.count {
                consoles[i].rpKey = getRPKeyFromKeychain(for: consoles[i])
            }
            
            return consoles
        } catch {
            print("[ConsoleStorage] Failed to decode consoles: \(error)")
            return []
        }
    }
    
    private func saveConsolesToDisk(_ consoles: [Console]) {
        do {
            // Create copies without rpKey (stored separately in Keychain for security)
            var consolesToSave = consoles
            for i in 0..<consolesToSave.count {
                consolesToSave[i].rpKey = nil
            }
            
            let data = try JSONEncoder().encode(consolesToSave)
            defaults.set(data, forKey: registeredConsolesKey)
            print("[ConsoleStorage] Saved \(consoles.count) consoles")
        } catch {
            print("[ConsoleStorage] Failed to encode consoles: \(error)")
        }
    }
    
    // MARK: - Private: Keychain Operations
    
    private func saveRPKeyToKeychain(_ rpKey: Data, for console: Console) {
        let service = "\(keychainServicePrefix).rpkey"
        let account = console.ipAddress
        
        // Delete existing key
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add new key
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: rpKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            print("[ConsoleStorage] RP-Key saved to Keychain for \(console.ipAddress)")
        } else {
            print("[ConsoleStorage] Failed to save RP-Key: \(status)")
        }
    }
    
    private func getRPKeyFromKeychain(for console: Console) -> Data? {
        let service = "\(keychainServicePrefix).rpkey"
        let account = console.ipAddress
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            return data
        }
        return nil
    }
    
    private func deleteRPKeyFromKeychain(for console: Console) {
        let service = "\(keychainServicePrefix).rpkey"
        let account = console.ipAddress
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        SecItemDelete(query as CFDictionary)
        print("[ConsoleStorage] RP-Key deleted from Keychain for \(console.ipAddress)")
    }
}

// MARK: - Console Extension for Async Loading

extension Console {
    /// Create a console from stored data with RP-Key from Keychain
    /// - Parameter ip: IP address to load
    /// - Returns: Console if found in storage
    static func loadFromStorage(ip: String) async -> Console? {
        return await ConsoleStorageService.shared.getRegisteredConsole(byIP: ip)
    }
}

// MARK: - Synchronous Bridge (for non-async contexts)

/// Provides synchronous access to ConsoleStorageService for legacy code paths.
/// Use sparingly - prefer async/await syntax.
extension ConsoleStorageService {
    
    /// Synchronously save a console (blocks calling thread).
    /// - Warning: Use only when async is not possible.
    nonisolated func saveRegisteredConsoleSync(_ console: Console) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await self.saveRegisteredConsole(console)
            semaphore.signal()
        }
        semaphore.wait()
    }
    
    /// Synchronously get all registered consoles (blocks calling thread).
    /// - Warning: Use only when async is not possible.
    nonisolated func getRegisteredConsolesSync() -> [Console] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [Console] = []
        Task {
            result = await self.getRegisteredConsoles()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
    
    /// Synchronously check if console is registered (blocks calling thread).
    /// - Warning: Use only when async is not possible.
    nonisolated func isConsoleRegisteredSync(ip: String) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        Task {
            result = await self.isConsoleRegistered(ip: ip)
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
