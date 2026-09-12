import SwiftUI
import MetalKit
import os

// Standalone device diagnostic: no application, PSN, decoder or metrics code.
@main
struct PresentationProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeScreen()
        }
        .defaultSize(width: 720, height: 500)
        .windowResizability(.contentSize)
    }
}

enum ProbeMode: String, CaseIterable, Identifiable, Sendable {
    case standard = "MTKView currentDrawable"
    case queuedLayer = "CAMetalLayer queued nextDrawable"
    var id: String { rawValue }
}

final class ProbeStats: @unchecked Sendable {
    struct Counts {
        var submitted = 0
        var gpuCompleted = 0
        var gpuFailed = 0
        var callbacks = 0
        var zero = 0
        var positive = 0
        var invalid = 0
        var noDrawable = 0
        var capacitySkips = 0
    }
    let mode: ProbeMode
    let run = UUID().uuidString
    private let lock = OSAllocatedUnfairLock(initialState: Counts())

    init(mode: ProbeMode) { self.mode = mode }
    func snapshot() -> Counts { lock.withLock { $0 } }
    func update(_ body: @Sendable (inout Counts) -> Void) { lock.withLock(body) }
    func log(_ message: String) {
        print("[PresentationProbe] run=\(run) mode=\(mode.rawValue) \(message)")
    }
    func presented(frame: Int, drawableID: Int, seconds: Double) {
        let counts = lock.withLock { state in
            state.callbacks += 1
            if seconds == 0 { state.zero += 1 }
            else if seconds.isFinite && seconds > 0 { state.positive += 1 }
            else { state.invalid += 1 }
            return state
        }
        if counts.callbacks <= 3 || counts.callbacks % 60 == 0 {
            log("frame=\(frame) drawable=\(drawableID) presentedSeconds=\(seconds) callbacks=\(counts.callbacks) zero=\(counts.zero) positive=\(counts.positive) invalid=\(counts.invalid) gpuCompleted=\(counts.gpuCompleted) gpuFailed=\(counts.gpuFailed)")
        }
    }
}

struct ProbeScreen: View {
    @State private var mode: ProbeMode = .standard
    @State private var stats = ProbeStats(mode: .standard)

    var body: some View {
        VStack(spacing: 16) {
            Text("Teste de apresentação Metal").font(.title2)
            Picker("Modo", selection: $mode) {
                ForEach(ProbeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, selected in stats = ProbeStats(mode: selected) }
            ProbeMetalView(stats: stats)
                .id(stats.run)
                .frame(width: 640, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let counts = stats.snapshot()
                Text("GPU: \(counts.gpuCompleted) · timestamps > 0: \(counts.positive) · zero: \(counts.zero)")
                    .monospacedDigit()
            }
            Text("Observe se a cor muda suavemente nos dois modos.")
            Text("O segundo modo inicia automaticamente após 20 segundos.")
                .font(.caption)
        }
        .padding(24)
        .task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            mode = .queuedLayer
        }
    }
}

struct ProbeMetalView: UIViewRepresentable {
    let stats: ProbeStats

    func makeCoordinator() -> Renderer { Renderer(stats: stats) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = context.coordinator
        if let layer = view.layer as? CAMetalLayer {
            let defaultTransaction = layer.presentsWithTransaction
            layer.presentsWithTransaction = false
            layer.maximumDrawableCount = 3
            layer.allowsNextDrawableTimeout = true
            stats.log("start defaultPresentsWithTransaction=\(defaultTransaction) presentsWithTransaction=\(layer.presentsWithTransaction) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {}
    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) {
        view.isPaused = true
        view.delegate = nil
        coordinator.stats.log("stop (in-flight callbacks may follow with original run ID)")
    }

    final class Renderer: NSObject, MTKViewDelegate, @unchecked Sendable {
        let stats: ProbeStats
        private let renderQueue = DispatchQueue(label: "presentation.probe.render")
        private let capacity = DispatchSemaphore(value: 2)
        private var commandQueue: MTLCommandQueue?
        private var sequence = 0
        private let started = CACurrentMediaTime()

        init(stats: ProbeStats) { self.stats = stats }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard capacity.wait(timeout: .now()) == .success else {
                stats.update { $0.capacitySkips += 1 }; return
            }
            if commandQueue == nil { commandQueue = view.device?.makeCommandQueue() }
            guard let queue = commandQueue else { capacity.signal(); return }
            switch stats.mode {
            case .standard:
                // Apple's normal delegate path, fully inside draw(in:).
                guard let pass = view.currentRenderPassDescriptor,
                      let drawable = view.currentDrawable else {
                    stats.update { $0.noDrawable += 1 }; capacity.signal(); return
                }
                encode(drawable: drawable, pass: pass, queue: queue)
            case .queuedLayer:
                guard let layer = view.layer as? CAMetalLayer else { capacity.signal(); return }
                renderQueue.async { [self] in
                    autoreleasepool {
                        guard let drawable = layer.nextDrawable() else {
                            stats.update { $0.noDrawable += 1 }; capacity.signal(); return
                        }
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = drawable.texture
                        encode(drawable: drawable, pass: pass, queue: queue)
                    }
                }
            }
        }

        private func encode(drawable: CAMetalDrawable, pass: MTLRenderPassDescriptor, queue: MTLCommandQueue) {
            let phase = (sin((CACurrentMediaTime() - started) * .pi / 3) + 1) / 2
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.15, green: 0.3 + phase * 0.3, blue: 0.6 - phase * 0.3, alpha: 1)
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                stats.update { $0.gpuFailed += 1 }; capacity.signal(); return
            }
            encoder.endEncoding()
            sequence += 1
            let frame = sequence
            stats.update { $0.submitted += 1 }
            let stats = stats
            let capacity = capacity
            command.addCompletedHandler { completed in
                capacity.signal()
                stats.update {
                    if completed.status == .completed { $0.gpuCompleted += 1 }
                    else { $0.gpuFailed += 1 }
                }
                if frame <= 3 {
                    stats.log("frame=\(frame) gpuStart=\(completed.gpuStartTime) gpuEnd=\(completed.gpuEndTime) status=\(completed.status.rawValue)")
                }
            }
            drawable.addPresentedHandler { presented in
                stats.presented(frame: frame, drawableID: presented.drawableID, seconds: presented.presentedTime)
                // One retained drawable per run, for 100 ms only. Check for a
                // late-filled property without treating callback time as display time.
                if frame == 3 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                        stats.log("lateRead frame=\(frame) drawable=\(presented.drawableID) presentedSeconds=\(presented.presentedTime)")
                    }
                }
            }
            command.present(drawable)
            command.commit()
        }
    }
}
