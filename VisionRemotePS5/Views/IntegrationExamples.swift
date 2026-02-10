//
//  IntegrationExamples.swift
//  VisionRemotePS5
//
//  Exemplos práticos de como integrar as otimizações GPU
//  no código existente do app
//

import SwiftUI
import RealityKit
import Metal

// MARK: - EXEMPLO 1: Modificar StreamingImmersiveView

/*
 
 LOCALIZAÇÃO: StreamingImmersiveView.swift
 
 CÓDIGO ATUAL (aproximadamente linha 150-180):
 
 ```swift
 struct StreamingImmersiveView: View {
     @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
     
     var body: some View {
         if upscalingPipeline.isEnabled,
            let texture4K = upscalingPipeline.upscaledTexture {
             Immersive4KSurface(texture: texture4K)
         }
     }
 }
 ```
 
 NOVO CÓDIGO (com otimizações GPU):
 
 */

/*
struct StreamingImmersiveViewEnhanced: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var upscalingPipeline = UpscalingPipeline.shared
    
    // 🆕 ADICIONAR: GPU Processor
    @StateObject private var gpuProcessor = GPUProcessor()
    @StateObject private var thermalMonitor = ThermalStateMonitor()
    
    @State private var showPerformanceHUD = false
    @State private var selectedPreset: GPUPreset = .auto
    
    var body: some View {
        ZStack {
            // Vídeo principal com processamento GPU
            RealityView { content in
                await setupOptimizedVideo(in: content)
            } update: { content in
                if let texture = upscalingPipeline.upscaledTexture {
                    await updateWithGPUProcessing(texture: texture, in: content)
                }
            }
            
            // HUD de performance (toggle com gesto)
            if showPerformanceHUD {
                VStack {
                    Spacer()
                    PerformanceHUD(
                        fps: gpuProcessor.currentFPS,
                        thermalState: thermalMonitor.thermalState,
                        gpuUsage: gpuProcessor.gpuUsage
                    )
                    .padding()
                }
            }
        }
        .gesture(
            // Tap duplo para mostrar/esconder HUD
            TapGesture(count: 2).onEnded {
                showPerformanceHUD.toggle()
            }
        )
        .onChange(of: selectedPreset) { _, newPreset in
            applyPreset(newPreset)
        }
        .onChange(of: thermalMonitor.recommendedQuality) { _, quality in
            if selectedPreset == .auto {
                adjustForThermalState(quality)
            }
        }
        .task {
            // Detectar tipo de jogo automáticamente (se possível)
            // Por enquanto, usar auto
            selectedPreset = .auto
        }
    }
    
    @MainActor
    private func setupOptimizedVideo(in content: RealityViewContent) async {
        // Criar entity com tela curva
        let videoEntity = OptimizedVideoEntity(
            width: 6.0,
            height: 3.375,
            curved: true
        )
        content.add(videoEntity.getEntity())
    }
    
    @MainActor
    private func updateWithGPUProcessing(
        texture: MTLTexture,
        in content: RealityViewContent
    ) async {
        // Processar frame com GPU pipeline
        guard let enhanced = await gpuProcessor.processFrame(texture) else {
            return
        }
        
        // Atualizar entity
        if let entity = content.entities.first(where: { 
            $0.name == "OptimizedVideoPlane" 
        }) as? ModelEntity {
            await updateEntityTexture(entity, with: enhanced)
        }
    }
    
    @MainActor
    private func updateEntityTexture(_ entity: ModelEntity, with texture: MTLTexture) async {
        do {
            let descriptor = LowLevelTexture.Descriptor(
                pixelFormat: texture.pixelFormat,
                width: texture.width,
                height: texture.height,
                depth: 1,
                mipmapLevelCount: 1,
                textureUsage: [.shaderRead]
            )
            
            let llTexture = try LowLevelTexture(descriptor: descriptor)
            
            // Copiar texture content
            if let queue = texture.device.makeCommandQueue(),
               let cmdBuffer = queue.makeCommandBuffer(),
               let blitEncoder = cmdBuffer.makeBlitCommandEncoder() {
                
                let destTexture = llTexture.replace(using: cmdBuffer)
                blitEncoder.copy(from: texture, to: destTexture)
                blitEncoder.endEncoding()
                cmdBuffer.commit()
                cmdBuffer.waitUntilCompleted()
            }
            
            let resource = try await TextureResource(from: llTexture)
            
            var material = UnlitMaterial()
            material.color = .init(texture: .init(resource))
            entity.model?.materials = [material]
            
        } catch {
            print("[Enhanced] ❌ Erro ao atualizar texture: \\(error)")
        }
    }
    
    private func applyPreset(_ preset: GPUPreset) {
        switch preset {
        case .auto:
            // Usar thermal monitoring
            break
        case .racing:
            gpuProcessor.settings = .racingPreset
        case .fps:
            gpuProcessor.settings = .fpsPreset
        case .rpg:
            gpuProcessor.settings = .rpgPreset
        case .cinematic:
            gpuProcessor.settings = .cinematicPreset
        }
    }
    
    private func adjustForThermalState(_ quality: ThermalStateMonitor.Quality) {
        switch quality {
        case .ultra:
            gpuProcessor.settings.sharpeningIntensity = 0.3
            gpuProcessor.settings.enableColorGrading = true
            gpuProcessor.settings.reduceMotionBlur = true
        case .high:
            gpuProcessor.settings.sharpeningIntensity = 0.2
            gpuProcessor.settings.enableColorGrading = true
            gpuProcessor.settings.reduceMotionBlur = false
        case .medium:
            gpuProcessor.settings.sharpeningIntensity = 0.1
            gpuProcessor.settings.enableColorGrading = false
            gpuProcessor.settings.reduceMotionBlur = false
        case .low:
            gpuProcessor.settings.sharpeningIntensity = 0.0
            gpuProcessor.settings.enableColorGrading = false
            gpuProcessor.settings.reduceMotionBlur = false
        }
    }
}
*/

enum GPUPreset: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case racing = "Racing"
    case fps = "FPS"
    case rpg = "RPG"
    case cinematic = "Cinematic"
    
    var id: String { rawValue }
}

// MARK: - EXEMPLO 2: Adicionar no MenuBarWindow

/*
 
 LOCALIZAÇÃO: MenuBarWindow.swift
 
 ADICIONAR novo botão para abrir settings de GPU:
 
 */

/*
extension MenuBarWindow {
    
    var enhancedMenuBar: some View {
        HStack(spacing: 16) {
            // ... botões existentes ...
            
            // 🆕 NOVO: GPU Settings
            Button(action: {
                openWindow(id: "GPUSettingsWindow")
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "cpu.fill")
                    Text("GPU")
                        .font(.caption)
                }
                .foregroundColor(.cyan)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
        }
    }
}
*/

// MARK: - EXEMPLO 3: Nova Window para GPU Settings

/*
 
 LOCALIZAÇÃO: VisionRemotePS5App.swift
 
 ADICIONAR nova WindowGroup:
 
 */

/*
extension VisionRemotePS5App {
    
    var gpuSettingsWindow: some SwiftUI.Scene {
        WindowGroup(id: "GPUSettingsWindow") {
            GPUSettingsWindowView()
                .environmentObject(appState)
        }
        .windowStyle(.plain)
        .defaultSize(width: 500, height: 600)
    }
}
*/

struct GPUSettingsWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var gpuProcessor = GPUProcessor()
    @State private var selectedPreset: GPUPreset = .auto
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    Picker("Tipo de Jogo", selection: $selectedPreset) {
                        ForEach(GPUPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Text(presetDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section("Visual Quality") {
                    Toggle("HDR", isOn: $gpuProcessor.settings.enableHDR)
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Sharpening")
                            Spacer()
                            Text("\(Int(gpuProcessor.settings.sharpeningIntensity * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $gpuProcessor.settings.sharpeningIntensity,
                            in: 0...1
                        )
                    }
                    
                    Toggle("Color Grading", isOn: $gpuProcessor.settings.enableColorGrading)
                    Toggle("Motion Blur Reduction", isOn: $gpuProcessor.settings.reduceMotionBlur)
                }
                
                Section("Advanced") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Color Saturation")
                            Spacer()
                            Text("\(Int((gpuProcessor.settings.saturationBoost - 1.0) * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $gpuProcessor.settings.saturationBoost,
                            in: 0.8...1.4
                        )
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Contrast")
                            Spacer()
                            Text("\(Int((gpuProcessor.settings.contrastBoost - 1.0) * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $gpuProcessor.settings.contrastBoost,
                            in: 0.9...1.3
                        )
                    }
                }
                
                Section("Performance") {
                    HStack {
                        Text("Current FPS")
                        Spacer()
                        Text("\(Int(gpuProcessor.currentFPS))")
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    HStack {
                        Text("GPU Usage")
                        Spacer()
                        Text("\(Int(gpuProcessor.gpuUsage * 100))%")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            .navigationTitle("GPU Settings")
            .onChange(of: selectedPreset) { _, newPreset in
                applyPreset(newPreset)
            }
        }
    }
    
    private var presetDescription: String {
        switch selectedPreset {
        case .auto:
            return "Ajusta automaticamente baseado em thermal state"
        case .racing:
            return "Otimizado para jogos de corrida - motion blur reduction máximo"
        case .fps:
            return "Otimizado para FPS - latência mínima, sharpening alto"
        case .rpg:
            return "Otimizado para RPG - visual cinematográfico"
        case .cinematic:
            return "Máxima qualidade visual - ideal para cutscenes"
        }
    }
    
    private func applyPreset(_ preset: GPUPreset) {
        switch preset {
        case .auto:
            // Deixar thermal monitor decidir
            break
        case .racing:
            gpuProcessor.settings = .racingPreset
        case .fps:
            gpuProcessor.settings = .fpsPreset
        case .rpg:
            gpuProcessor.settings = .rpgPreset
        case .cinematic:
            gpuProcessor.settings = .cinematicPreset
        }
    }
}

// MARK: - EXEMPLO 4: Quick Toggle no Controller

/*
 
 LOCALIZAÇÃO: ControllerOverlayView.swift ou qualquer controller view
 
 ADICIONAR botão rápido para alternar presets:
 
 */

struct GPUQuickToggle: View {
    @Binding var currentPreset: GPUPreset
    
    var body: some View {
        Menu {
            ForEach(GPUPreset.allCases) { preset in
                Button(action: {
                    currentPreset = preset
                }) {
                    Label(preset.rawValue, systemImage: iconForPreset(preset))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconForPreset(currentPreset))
                    .font(.caption)
                Text(currentPreset.rawValue)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
        }
    }
    
    private func iconForPreset(_ preset: GPUPreset) -> String {
        switch preset {
        case .auto: return "sparkles.rectangle.stack"
        case .racing: return "steeringwheel"
        case .fps: return "scope"
        case .rpg: return "shield.fill"
        case .cinematic: return "film.fill"
        }
    }
}

// MARK: - EXEMPLO 5: Debug Overlay

struct GPUDebugOverlay: View {
    @ObservedObject var processor: GPUProcessor
    @ObservedObject var thermal: ThermalStateMonitor
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // FPS Graph
            HStack(spacing: 4) {
                Text("FPS")
                    .font(.caption2)
                    .frame(width: 40, alignment: .leading)
                
                // Mini graph (last 60 frames)
                // TODO: Implementar histórico de FPS
                
                Text("\(Int(processor.currentFPS))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(fpsColor)
            }
            
            // Thermal State
            HStack(spacing: 4) {
                Text("Thermal")
                    .font(.caption2)
                    .frame(width: 40, alignment: .leading)
                
                Rectangle()
                    .fill(thermalGradient)
                    .frame(height: 4)
                    .cornerRadius(2)
                
                Text(thermalEmoji)
                    .font(.caption2)
            }
            
            // Active Effects
            VStack(alignment: .leading, spacing: 2) {
                Text("Effects")
                    .font(.caption2)
                
                HStack(spacing: 6) {
                    effectBadge("Sharp", active: processor.settings.sharpeningIntensity > 0)
                    effectBadge("Color", active: processor.settings.enableColorGrading)
                    effectBadge("MBR", active: processor.settings.reduceMotionBlur)
                    effectBadge("HDR", active: processor.settings.enableHDR)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
    
    private var fpsColor: Color {
        if processor.currentFPS >= 55 { return .green }
        if processor.currentFPS >= 40 { return .yellow }
        return .red
    }
    
    private var thermalGradient: LinearGradient {
        let colors: [Color]
        switch thermal.thermalState {
        case .nominal:
            colors = [.green, .green]
        case .fair:
            colors = [.green, .yellow]
        case .serious:
            colors = [.yellow, .orange]
        case .critical:
            colors = [.orange, .red]
        @unknown default:
            colors = [.gray, .gray]
        }
        
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
    
    private var thermalEmoji: String {
        switch thermal.thermalState {
        case .nominal: return "❄️"
        case .fair: return "🌡️"
        case .serious: return "🔥"
        case .critical: return "🌋"
        @unknown default: return "❓"
        }
    }
    
    private func effectBadge(_ name: String, active: Bool) -> some View {
        Text(name)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(active ? Color.green.opacity(0.3) : Color.gray.opacity(0.2))
            .cornerRadius(3)
    }
}

// MARK: - EXEMPLO 6: Integração com UpscalingPipeline existente

/*
 
 LOCALIZAÇÃO: UpscalingPipeline.swift
 
 MODIFICAR método de upscaling para chamar GPU processor depois:
 
 */

/*
extension UpscalingPipeline {
    
    func upscaleWithEnhancement(
        _ inputTexture: MTLTexture,
        gpuProcessor: GPUProcessor?
    ) async -> MTLTexture? {
        
        // 1. MetalFX Upscaling (já existente)
        guard let upscaled = await upscale(inputTexture) else {
            return nil
        }
        
        // 2. GPU Post-Processing (novo)
        if let processor = gpuProcessor {
            return await processor.processFrame(upscaled)
        }
        
        return upscaled
    }
}
*/

// MARK: - EXEMPLO 7: Persistent Settings

class GPUSettingsManager {
    static let shared = GPUSettingsManager()
    
    private let defaults = UserDefaults.standard
    
    func save(_ settings: ProcessingSettings, for preset: GPUPreset) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(settings) {
            defaults.set(data, forKey: "gpu_preset_\(preset.rawValue)")
        }
    }
    
    func load(for preset: GPUPreset) -> ProcessingSettings? {
        guard let data = defaults.data(forKey: "gpu_preset_\(preset.rawValue)") else {
            return nil
        }
        
        let decoder = JSONDecoder()
        return try? decoder.decode(ProcessingSettings.self, from: data)
    }
    
    func saveCurrentPreset(_ preset: GPUPreset) {
        defaults.set(preset.rawValue, forKey: "current_gpu_preset")
    }
    
    func loadCurrentPreset() -> GPUPreset {
        guard let rawValue = defaults.string(forKey: "current_gpu_preset"),
              let preset = GPUPreset(rawValue: rawValue) else {
            return .auto
        }
        return preset
    }
}

// ProcessingSettings já é Codable na sua declaração (GPUOptimizationGuide.swift)

// MARK: - CHECKLIST DE IMPLEMENTAÇÃO

/*
 
 ✅ PASSO A PASSO PARA INTEGRAR:
 
 1. ☐ Adicionar arquivos ao projeto:
    - GPUOptimizationGuide.swift
    - Shaders.metal
    - EnhancedStreamingView.swift
    - IntegrationExamples.swift (este arquivo)
 
 2. ☐ Verificar Build Settings:
    - Shaders.metal está em "Compile Sources"
    - Metal Standard Library incluída
 
 3. ☐ Modificar StreamingImmersiveView:
    - Adicionar @StateObject var gpuProcessor
    - Adicionar @StateObject var thermalMonitor
    - Substituir update closure com processamento GPU
 
 4. ☐ Adicionar GPU Settings Window:
    - Nova WindowGroup em App.swift
    - GPUSettingsWindowView
 
 5. ☐ Adicionar botão no MenuBar:
    - Botão "GPU" que abre settings
 
 6. ☐ (Opcional) Adicionar debug overlay:
    - Toggle com double-tap
    - Mostrar FPS, thermal, effects ativos
 
 7. ☐ Testar presets:
    - Racing preset em F1 2024
    - FPS preset em Call of Duty
    - RPG preset em Horizon
 
 8. ☐ Verificar thermal throttling:
    - Jogar 30 minutos
    - Observar ajuste automático de qualidade
 
 9. ☐ Benchmarking:
    - Medir latência antes/depois
    - Medir FPS antes/depois
    - Comparar qualidade visual
 
 10. ☐ User defaults:
     - Salvar preset favorito
     - Salvar configurações customizadas
 
 */

