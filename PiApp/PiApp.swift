import SwiftUI

@main
struct PiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.theme.isDark ? .dark : .light)
        }
    }
}
