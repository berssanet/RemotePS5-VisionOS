//
//  ConsoleStorageService.swift
//  VisionRemotePS5
//
//  Persistent storage for registered PS5 consoles
//  Stores all necessary data to reconnect without re-pairing
//

import Foundation
import Security

/// Service for persisting registered console data
final class ConsoleStorageService {
    
    // MARK: - Singleton
    
    static let shared = ConsoleStorageService()
    
    // MARK: - Storage Keys
    
    private let registeredConsolesKey = "registered_consoles"
    private let keychainServicePrefix = "com.visionremote.ps5"
    
    // MARK: - UserDefaults
    
    private let defaults = UserDefaults.standard
    
    // MARK: - Initialization
    
    private init() {
        print("[ConsoleStorage] Service initialized")
    }
    
    // MARK: - Public Methods
    
    /// Save a registered console with all its data
    func saveRegisteredConsole(_ console: Console) {
        var consoles = getRegisteredConsoles()
        
        // Update or add console
        if let index = consoles.firstIndex(where: { $0.id == console.id || $0.ipAddress == console.ipAddress }) {
            consoles[index] = console
            print("[ConsoleStorage] Updated existing console: \(console.name)")
        } else {
            consoles.append(console)
            print("[ConsoleStorage] Added new console: \(console.name)")
        }
        
        // Save to UserDefaults
        saveConsoleList(consoles)
        
        // Save RP-Key securely in Keychain
        if let rpKey = console.rpKey {
            saveRPKeyToKeychain(rpKey, for: console)
        }
    }
    
    /// Get all registered consoles
    func getRegisteredConsoles() -> [Console] {
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
    
    /// Get a specific registered console by IP
    func getRegisteredConsole(byIP ip: String) -> Console? {
        return getRegisteredConsoles().first { $0.ipAddress == ip }
    }
    
    /// Get a specific registered console by ID
    func getRegisteredConsole(byID id: UUID) -> Console? {
        return getRegisteredConsoles().first { $0.id == id }
    }
    
    /// Remove a registered console
    func removeRegisteredConsole(_ console: Console) {
        var consoles = getRegisteredConsoles()
        consoles.removeAll { $0.id == console.id || $0.ipAddress == console.ipAddress }
        saveConsoleList(consoles)
        
        // Remove RP-Key from Keychain
        deleteRPKeyFromKeychain(for: console)
        
        print("[ConsoleStorage] Removed console: \(console.name)")
    }
    
    /// Check if a console is registered
    func isConsoleRegistered(ip: String) -> Bool {
        return getRegisteredConsoles().contains { $0.ipAddress == ip && $0.rpKey != nil }
    }
    
    /// Clear all registered consoles
    func clearAllConsoles() {
        let consoles = getRegisteredConsoles()
        for console in consoles {
            deleteRPKeyFromKeychain(for: console)
        }
        defaults.removeObject(forKey: registeredConsolesKey)
        print("[ConsoleStorage] Cleared all consoles")
    }
    
    // MARK: - Private Methods
    
    private func saveConsoleList(_ consoles: [Console]) {
        do {
            // Create copies without rpKey (stored separately in Keychain for security)
            var consolesToSave = consoles
            for i in 0..<consolesToSave.count {
                consolesToSave[i].rpKey = nil // Don't store RP-Key in UserDefaults
            }
            
            let data = try JSONEncoder().encode(consolesToSave)
            defaults.set(data, forKey: registeredConsolesKey)
            print("[ConsoleStorage] Saved \(consoles.count) consoles")
        } catch {
            print("[ConsoleStorage] Failed to encode consoles: \(error)")
        }
    }
    
    // MARK: - Keychain Operations
    
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

// MARK: - Console Extension for Codable Support

extension Console {
    /// Create a console from stored data with RP-Key from Keychain
    static func loadFromStorage(ip: String) -> Console? {
        return ConsoleStorageService.shared.getRegisteredConsole(byIP: ip)
    }
}
