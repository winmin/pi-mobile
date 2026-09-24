import SwiftUI

@main
struct PiApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.theme.isDark ? .dark : .light)
                .task {
                    // Refresh the account-scoped Codex picker on launch without
                    // blocking the UI. Cached/bundled models remain available
                    // when the network is offline.
                    if case .oauth? = model.providerStore.credential(for: "openai") {
                        _ = try? await model.providerStore.refreshCodexModels()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        model.applicationDidEnterBackground()
                    } else if phase == .active {
                        model.applicationDidBecomeActive()
                    }
                }
        }
    }
}
