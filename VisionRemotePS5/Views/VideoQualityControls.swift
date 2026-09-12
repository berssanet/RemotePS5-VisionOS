import SwiftUI

/// The same image controls in the window and spatial cinema.
struct VideoQualityControls: View {
    @ObservedObject private var pipeline = UpscalingPipeline.shared
    @ObservedObject private var service = StreamingService.shared
    @State private var inspectionExpanded = false
    var onInteraction: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Text("PS5 source: \(service.requestedVideoDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Image filter", selection: $pipeline.upscalerType) {
                ForEach(UpscalerType.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if pipeline.upscalerType == .metalFX {
                Text("Output size is an upscale, not native source detail.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            }

            if pipeline.upscalerType == .enhanced {
                HStack {
                    Text("Sharpness")
                    Slider(value: $pipeline.sharpenStrength, in: 0...1) { _ in onInteraction() }
                    Text(pipeline.sharpenStrength, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44)
                }
            }

            if pipeline.upscalerType != .native {
                Toggle("Compare with original", isOn: $pipeline.comparisonEnabled)
            }
            if pipeline.comparisonEnabled && pipeline.upscalerType != .native {
                HStack {
                    Text("Original")
                    Slider(value: $pipeline.comparisonPosition, in: 0.05...0.95) { _ in onInteraction() }
                    Text(pipeline.upscalerType.rawValue)
                }
                Text("Move the divider to compare the same image.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Inspect image detail", isExpanded: $inspectionExpanded) {
                VStack(spacing: 10) {
                    HStack {
                        Button {
                            pipeline.setInspectionFrozen(!pipeline.inspectionFrozen)
                            onInteraction()
                        } label: {
                            Label(pipeline.inspectionFrozen ? "Resume image" : "Pause image",
                                  systemImage: pipeline.inspectionFrozen ? "play.fill" : "pause.fill")
                        }
                        Spacer()
                        Button("Live / 1×") {
                            pipeline.setInspectionFrozen(false)
                            pipeline.inspectionZoom = 1
                            pipeline.inspectionCenter = SIMD2<Float>(repeating: 0.5)
                            onInteraction()
                        }
                    }
                    Picker("Detail zoom", selection: $pipeline.inspectionZoom) {
                        Text("1×").tag(Float(1))
                        Text("2×").tag(Float(2))
                        Text("4×").tag(Float(4))
                    }
                    .pickerStyle(.segmented)
                    if pipeline.inspectionZoom > 1 {
                        HStack(spacing: 14) {
                            Text("Detail area")
                            Spacer()
                            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                                ForEach(0..<3) { row in
                                    GridRow {
                                        ForEach(0..<3) { column in
                                            let center = SIMD2<Float>(Float(column) / 2, Float(row) / 2)
                                            Button {
                                                pipeline.inspectionCenter = center
                                                onInteraction()
                                            } label: {
                                                Image(systemName: areaSymbol(row: row, column: column))
                                                    .frame(width: 24, height: 22)
                                            }
                                            .accessibilityLabel(areaLabel(row: row, column: column))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text("Zoom enlarges the same area on both sides; it does not add source detail.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            if pipeline.inspectionFrozen {
                HStack {
                    Text("Image paused — the game, audio and controls continue.")
                        .font(.caption)
                    Spacer()
                    Button("Resume") {
                        pipeline.setInspectionFrozen(false)
                        onInteraction()
                    }
                }
                .foregroundStyle(.orange)
            }
        }
        .onChange(of: pipeline.upscalerType) { _, _ in onInteraction() }
        .onChange(of: pipeline.comparisonEnabled) { _, _ in onInteraction() }
        .onChange(of: pipeline.inspectionZoom) { _, _ in onInteraction() }
        .onChange(of: inspectionExpanded) { _, _ in onInteraction() }
    }

    private func areaSymbol(row: Int, column: Int) -> String {
        let symbols = [["arrow.up.left", "arrow.up", "arrow.up.right"],
                       ["arrow.left", "scope", "arrow.right"],
                       ["arrow.down.left", "arrow.down", "arrow.down.right"]]
        return symbols[row][column]
    }

    private func areaLabel(row: Int, column: Int) -> String {
        let labels = [["Top left", "Top", "Top right"],
                      ["Left", "Center", "Right"],
                      ["Bottom left", "Bottom", "Bottom right"]]
        return labels[row][column] + " detail"
    }
}
