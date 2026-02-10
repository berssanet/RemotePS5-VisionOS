import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        Group {
            if appState.isInStreamingSession {
                // v10.5.2: Minimize window to smallest possible size during streaming
                // Using Color.clear with fixedSize to force minimum dimensions
                Color.clear
                    .frame(minWidth: 1, maxWidth: 1, minHeight: 1, maxHeight: 1)
                    .fixedSize()
                    .opacity(0)
                    .allowsHitTesting(false)
            } else {
                NavigationStack {
                    HomeView()
                }
                .ornament(attachmentAnchor: .scene(.bottom)) {
                    ConnectionStatusBar()
                }
            }
        }
        // v10.5.2: Also hide system overlays during streaming
        .persistentSystemOverlays(appState.isInStreamingSession ? .hidden : .automatic)
    }
}

/// Bottom status bar showing connection state
struct ConnectionStatusBar: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 16) {
            // Connection indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(appState.connectionStatus.rawValue)
                    .font(.caption)
            }
            
            if appState.isConnected {
                Divider()
                    .frame(height: 16)
                
                // Quality indicator
                Text(appState.streamQuality.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackgroundEffect()
    }
    
    private var statusColor: Color {
        switch appState.connectionStatus {
        case .disconnected:
            return .gray
        case .connecting:
            return .yellow
        case .connected, .streaming:
            return .green
        case .error:
            return .red
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environmentObject(AppState())
}
