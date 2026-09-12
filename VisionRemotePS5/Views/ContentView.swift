import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    /// Navigation path shared with HomeView / PairingView (PairingView resets it to pop home).
    @State private var navigationPath: NavigationPath = NavigationPath()
    
    var body: some View {
        Group {
            if appState.presentationState == .terminating {
                ProgressView("Ending session…")
                    .frame(width: 300, height: 120)
                    .glassBackgroundEffect()
            } else if appState.isInStreamingSession {
                // The launch window stays out of the way while the dedicated
                // streaming surface owns presentation.
                Color.clear
                    .frame(minWidth: 1, maxWidth: 1, minHeight: 1, maxHeight: 1)
                    .fixedSize()
                    .opacity(0)
                    .allowsHitTesting(false)
            } else {
                NavigationStack(path: $navigationPath) {
                    HomeView(navigationPath: $navigationPath)
                }
                // contentSize follows these limits when returning from the
                // hidden streaming state, including restored tiny windows.
                .frame(minWidth: 760, idealWidth: 840, maxWidth: 1000,
                       minHeight: 580, idealHeight: 660, maxHeight: 900)
                .glassBackgroundEffect()
            }
        }
        .persistentSystemOverlays(appState.isInStreamingSession ? .hidden : .automatic)
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environmentObject(AppState())
}
