//
//  WheelConfigurationView.swift
//  VisionRemotePS5
//
//  Configuration overlay for F1 wheel button mappings
//  Shows default mappings and allows user to confirm or edit
//

import SwiftUI

struct WheelConfigurationView: View {
    @ObservedObject var mappingService: WheelButtonMappingService
    @State private var selectedButton: WheelButtonID?
    @State private var showActionPicker = false
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header
                headerView
                
                // Button mappings grid
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        ForEach(mappingService.mappings) { mapping in
                            buttonMappingCard(mapping)
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 400)
                
                // Action buttons
                actionButtons
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
            )
            .frame(maxWidth: 700)
        }
        .sheet(isPresented: $showActionPicker) {
            if let button = selectedButton {
                actionPickerSheet(for: button)
            }
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "steeringwheel")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            
            Text("Configuração do Volante F1")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Confirme o mapeamento padrão ou toque em um botão para alterar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Button Mapping Card
    
    private func buttonMappingCard(_ mapping: WheelButtonMapping) -> some View {
        Button {
            selectedButton = mapping.buttonId
            showActionPicker = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mapping.buttonId.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack(spacing: 6) {
                        Image(systemName: mapping.action.icon)
                            .foregroundStyle(.blue)
                        Text(mapping.action.displayName)
                            .fontWeight(.medium)
                    }
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 16) {
            // Reset to defaults
            Button {
                mappingService.resetToDefaults()
            } label: {
                Label("Resetar", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            // Cancel
            Button {
                mappingService.cancelConfiguration()
            } label: {
                Text("Cancelar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            // Confirm
            Button {
                mappingService.saveConfiguration()
            } label: {
                Label("Confirmar", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    // MARK: - Action Picker Sheet
    
    private func actionPickerSheet(for buttonId: WheelButtonID) -> some View {
        NavigationView {
            List {
                Section("Triggers & Bumpers") {
                    actionRow(.r2, for: buttonId)
                    actionRow(.l2, for: buttonId)
                    actionRow(.r1, for: buttonId)
                    actionRow(.l1, for: buttonId)
                }
                
                Section("Botões de Face") {
                    actionRow(.cross, for: buttonId)
                    actionRow(.circle, for: buttonId)
                    actionRow(.triangle, for: buttonId)
                    actionRow(.square, for: buttonId)
                }
                
                Section("D-Pad") {
                    actionRow(.dpadUp, for: buttonId)
                    actionRow(.dpadDown, for: buttonId)
                    actionRow(.dpadLeft, for: buttonId)
                    actionRow(.dpadRight, for: buttonId)
                }
                
                Section("Sistema") {
                    actionRow(.options, for: buttonId)
                    actionRow(.share, for: buttonId)
                    actionRow(.ps, for: buttonId)
                    actionRow(.touchpad, for: buttonId)
                }
                
                Section("Analógicos") {
                    actionRow(.l3, for: buttonId)
                    actionRow(.r3, for: buttonId)
                }
                
                Section("Desativar") {
                    actionRow(.none, for: buttonId)
                }
            }
            .navigationTitle(buttonId.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        showActionPicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private func actionRow(_ action: PS5ControllerAction, for buttonId: WheelButtonID) -> some View {
        let currentAction = mappingService.getAction(for: buttonId)
        
        return Button {
            mappingService.setAction(action, for: buttonId)
            showActionPicker = false
        } label: {
            HStack {
                Image(systemName: action.icon)
                    .foregroundStyle(.blue)
                    .frame(width: 30)
                
                Text(action.displayName)
                
                Spacer()
                
                if currentAction == action {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

// MARK: - Compact Configuration Badge (for quick access)

struct WheelConfigBadge: View {
    @ObservedObject var mappingService: WheelButtonMappingService
    
    var body: some View {
        Button {
            mappingService.startConfiguration()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .padding(12)
                .background(Circle().fill(.ultraThinMaterial))
        }
    }
}

// MARK: - Preview

#Preview {
    WheelConfigurationView(mappingService: WheelButtonMappingService.shared)
}
