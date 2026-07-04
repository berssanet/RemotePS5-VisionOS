//
//  WheelButtonHotspots.swift
//  VisionRemotePS5
//
//  Creates invisible touch hotspots over the F1 wheel 3D model
//  These hotspots detect user gaze + tap and trigger button actions
//

import SwiftUI
import RealityKit

// MARK: - Wheel Button Hotspots Factory

@MainActor
class WheelButtonHotspotsFactory {
    
    /// Creates all button hotspot entities as children of a parent entity
    /// - Parameter parentEntity: The wheel root entity to attach hotspots to
    /// - Returns: Dictionary mapping button IDs to their entities
    static func createHotspots(attachedTo parentEntity: Entity) -> [WheelButtonID: Entity] {
        var hotspots: [WheelButtonID: Entity] = [:]
        
        for buttonId in WheelButtonID.allCases {
            let hotspot = createHotspot(for: buttonId)
            parentEntity.addChild(hotspot)
            hotspots[buttonId] = hotspot
            DebugLog.print("[WheelHotspots] ✅ Created hotspot: \(buttonId.displayName)")
        }
        
        DebugLog.print("[WheelHotspots] 🎯 Created \(hotspots.count) total hotspots")
        return hotspots
    }
    
    /// Creates a single button hotspot entity
    private static func createHotspot(for buttonId: WheelButtonID) -> Entity {
        let entity = Entity()
        entity.name = buttonId.rawValue
        
        // Position relative to wheel center
        entity.position = buttonId.position
        
        // Create invisible mesh for collision detection
        let size = buttonId.hotspotSize
        let mesh = MeshResource.generateBox(size: size, cornerRadius: 0.005)
        
        // VISIBLE blue material for debugging hotspot positions
        var material = UnlitMaterial()
        material.color = .init(tint: .systemBlue.withAlphaComponent(0.6))  // Visible for debugging
        
        let modelComponent = ModelComponent(mesh: mesh, materials: [material])
        entity.components.set(modelComponent)
        
        // Enable input targeting (required for hand/finger gesture detection)
        entity.components.set(InputTargetComponent())
        
        // Generate collision shape for the mesh
        let collision = CollisionComponent(shapes: [.generateBox(size: size)])
        entity.components.set(collision)
        
        // NOTE: HoverEffectComponent REMOVED - it caused selection by gaze instead of touch
        
        return entity
    }
    
    /// Updates hotspot visuals based on active state for debugging
    static func updateHotspotVisual(entity: Entity, isActive: Bool, isConfiguring: Bool) {
        guard var model = entity.components[ModelComponent.self] else { return }
        
        var material = UnlitMaterial()
        
        if isConfiguring {
            // Show hotspots during configuration
            material.color = .init(tint: isActive ? 
                .systemGreen.withAlphaComponent(0.6) : 
                .systemBlue.withAlphaComponent(0.3))
        } else if isActive {
            // Flash when pressed
            material.color = .init(tint: .systemGreen.withAlphaComponent(0.4))
        } else {
            // Invisible during normal gameplay
            material.color = .init(tint: .clear)
        }
        
        model.materials = [material]
        entity.components.set(model)
    }
}

// MARK: - Wheel Hotspots Manager

@MainActor
class WheelHotspotsManager: ObservableObject {
    static let shared = WheelHotspotsManager()
    
    private var hotspots: [WheelButtonID: Entity] = [:]
    private var wheelEntity: Entity?
    
    private init() {}
    
    /// Attaches hotspots to a wheel entity
    func attachToWheel(_ entity: Entity) {
        // Remove old hotspots if any
        for (_, hotspot) in hotspots {
            hotspot.removeFromParent()
        }
        
        wheelEntity = entity
        hotspots = WheelButtonHotspotsFactory.createHotspots(attachedTo: entity)
        
        DebugLog.print("[WheelHotspotsManager] ✅ Attached \(hotspots.count) hotspots to wheel")
    }
    
    /// Gets the button ID from an entity name
    func getButtonId(from entityName: String) -> WheelButtonID? {
        WheelButtonID(rawValue: entityName)
    }
    
    /// Gets the entity for a button ID
    func getEntity(for buttonId: WheelButtonID) -> Entity? {
        hotspots[buttonId]
    }
    
    /// Updates visual state of all hotspots
    func updateVisuals(mappingService: WheelButtonMappingService) {
        for (buttonId, entity) in hotspots {
            let isActive = mappingService.isButtonActive(buttonId)
            let isConfiguring = mappingService.isConfiguring
            WheelButtonHotspotsFactory.updateHotspotVisual(
                entity: entity,
                isActive: isActive,
                isConfiguring: isConfiguring
            )
        }
    }
    
    /// Shows all hotspots (for configuration mode)
    func showAllHotspots() {
        for (_, entity) in hotspots {
            WheelButtonHotspotsFactory.updateHotspotVisual(
                entity: entity,
                isActive: false,
                isConfiguring: true
            )
        }
    }
    
    /// Hides all hotspots (for normal gameplay)
    func hideAllHotspots() {
        for (_, entity) in hotspots {
            WheelButtonHotspotsFactory.updateHotspotVisual(
                entity: entity,
                isActive: false,
                isConfiguring: false
            )
        }
    }
    
    /// Returns all hotspot entities for gesture handling
    var allHotspotEntities: [Entity] {
        Array(hotspots.values)
    }
    
    /// Cleanup
    func reset() {
        for (_, hotspot) in hotspots {
            hotspot.removeFromParent()
        }
        hotspots.removeAll()
        wheelEntity = nil
        DebugLog.print("[WheelHotspotsManager] 🔄 Reset")
    }
}
