//
//  ControllerTutorialPanel.swift
//  VisionRemotePS5
//
//  v13.1 "Controller Test Range": the floating glass control panel shown in
//  the full-immersive test space. It hosts the 1st/3rd-person view-mode
//  toggle, the per-mode control map ("how to play"), the objective/score,
//  calibration controls, and a live HUD mirroring the raw controller state
//  (sticks, triggers, buttons) so the player can verify and adjust before
//  connecting to a PS5. All state is passed in by the owning immersive view;
//  this view only renders and forwards taps.
//

import SwiftUI
import simd

/// The two practice modes (first-person shooter / third-person runner).
enum TestRangeViewMode: String, CaseIterable {
    case firstPerson = "1st Person"
    case thirdPerson = "3rd Person"

    var systemImage: String {
        switch self {
        case .firstPerson: return "scope"
        case .thirdPerson: return "figure.run"
        }
    }

    var subtitle: String {
        switch self {
        case .firstPerson: return "Shooting range"
        case .thirdPerson: return "Runner"
        }
    }

    /// Control map shown as "how to play" for this mode.
    var controls: [(String, String)] {
        switch self {
        case .firstPerson:
            return [("Right stick", "Aim"), ("R2", "Shoot"), ("L2", "Steady aim"),
                    ("Left stick", "Move"), ("Square", "Respawn targets")]
        case .thirdPerson:
            return [("Left stick", "Run"), ("Cross", "Jump"),
                    ("Right stick", "Rotate camera"), ("Goal", "Collect the coins")]
        }
    }
}

/// Digital buttons shown as live chips in the HUD (triggers are shown as bars).
private let chipLayout: [(String, UInt32)] = [
    ("✕", PSButtonMask.cross), ("○", PSButtonMask.circle),
    ("□", PSButtonMask.square), ("△", PSButtonMask.triangle),
    ("L1", PSButtonMask.l1), ("R1", PSButtonMask.r1),
    ("L3", PSButtonMask.l3), ("R3", PSButtonMask.r3),
    ("↑", PSButtonMask.dpadUp), ("↓", PSButtonMask.dpadDown),
    ("←", PSButtonMask.dpadLeft), ("→", PSButtonMask.dpadRight),
    ("OPT", PSButtonMask.options), ("SHR", PSButtonMask.share),
    ("TP", PSButtonMask.touchpad), ("PS", PSButtonMask.ps)
]

struct ControllerTutorialPanel: View {
    let mode: TestRangeViewMode
    let sample: TrainingInputSample
    let score: Int
    let shots: Int
    let isTracking: Bool
    let cyborg: Bool
    let debug: HandGestureControllerService.Debug
    let onSelectMode: (TestRangeViewMode) -> Void
    let onToggleProfile: () -> Void
    let onRecalibrate: () -> Void
    let onReset: () -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            gripHint
            modePicker
            HStack(alignment: .top, spacing: 20) {
                controlMap
                objective
            }
            Divider()
            diagReadout
            liveHUD
            controlRow
        }
        .padding(26)
        .frame(width: 600)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Controller Test Range", systemImage: "gamecontroller.fill")
                .font(.title2).bold()
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(isTracking ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(isTracking ? "Hands tracked" : "Show both hands")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Grip hint

    private var gripHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "hands.and.sparkles.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            Text("Rest both hands palm-down on your desk or lap. Slide your thumb along your index finger — each part of the index is a button: right hand = ✕ ○ □ △, left hand = D-pad.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 12) {
            ForEach(TestRangeViewMode.allCases, id: \.self) { m in
                Button {
                    onSelectMode(m)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: m.systemImage).font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.rawValue).font(.headline)
                            Text(m.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(mode == m ? Color.blue.opacity(0.3) : Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Control map / objective

    private var controlMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to play").font(.caption).foregroundStyle(.secondary)
            ForEach(mode.controls, id: \.0) { input, action in
                HStack(spacing: 8) {
                    Text(input)
                        .font(.system(.subheadline, design: .rounded)).bold()
                        .frame(width: 92, alignment: .leading)
                        .foregroundStyle(.blue)
                    Text(action).font(.subheadline).foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var objective: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(mode == .firstPerson ? "HITS" : "COINS")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(score)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
            if mode == .firstPerson {
                Text("\(shots) shots").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 120)
    }

    // MARK: - Diagnostic readout (screenshot-friendly)

    /// v13.8: raw thumb-fretboard state on screen so it can be read from a
    /// screenshot (the console-log tunnel is unreliable). `rest` = palm-down
    /// pose detected; `down` = downness (>0.2 enters); `seg` = touched index
    /// segment (0=tip … 3=knuckle, - = none); `d` = thumb→segment distances in
    /// MM (a segment fires when its distance drops under ~32mm).
    private var diagReadout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DIAG  (thumb → index segments, distances in mm)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.yellow)
            diagLine("R", rest: debug.rRest, down: debug.rDown, seg: debug.rSeg, dist: debug.rDist)
            diagLine("L", rest: debug.lRest, down: debug.lDown, seg: debug.lSeg, dist: debug.lDist)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func diagLine(_ hand: String, rest: Bool, down: Float, seg: Int, dist: SIMD4<Float>) -> some View {
        let segName = seg < 0 ? "-" : ["tip□", "2✕", "3○", "knu△"][seg]
        let mm = (0..<4).map { String(format: "%3.0f", dist[$0] * 1000) }.joined(separator: " ")
        return Text("\(hand) rest=\(rest ? "Y" : "N") down=\(String(format: "%+.2f", down)) seg=\(segName)  d[\(mm)]")
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(rest ? .green : .orange)
    }

    // MARK: - Live HUD

    private var liveHUD: some View {
        VStack(spacing: 12) {
            HStack(spacing: 24) {
                stickReadout(title: "L STICK", value: sample.leftStick, tint: .cyan)
                stickReadout(title: "R STICK", value: sample.rightStick, tint: .green)
                triggerReadout(title: "L2", value: sample.leftTrigger, tint: .orange)
                triggerReadout(title: "R2", value: sample.rightTrigger, tint: .red)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(chipLayout, id: \.0) { label, mask in
                    let on = sample.isPressed(mask)
                    Text(label)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(on ? .black : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(on ? Color.green : Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func stickReadout(title: String, value: SIMD2<Float>, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%+.0f, %+.0f", value.x * 100, value.y * 100))
                .font(.system(.subheadline, design: .monospaced)).bold()
                .foregroundStyle(simd_length(value) > 0.05 ? tint : .secondary)
        }
        .frame(width: 96)
    }

    private func triggerReadout(title: String, value: Float, tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: Double(max(0, min(1, value)))).tint(tint).frame(width: 64)
            Text(String(format: "%.0f%%", value * 100))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(value > 0.02 ? tint : .secondary)
        }
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack(spacing: 12) {
            Button(action: onRecalibrate) {
                Label("Recalibrate", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)

            Button(action: onToggleProfile) {
                Label(cyborg ? "Paddles" : "Taps", systemImage: cyborg ? "keyboard.fill" : "hand.tap")
            }
            .buttonStyle(.bordered)

            Button(action: onReset) {
                Label("Reset", systemImage: "gobackward")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(action: onExit) {
                Label("Connect to PS5", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
