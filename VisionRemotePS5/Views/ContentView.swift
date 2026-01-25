import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationStack {
            // Use SimpleTestView for direct PS5 connection testing
            SimpleTestView()
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            ConnectionStatusBar()
        }
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
