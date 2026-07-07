import SwiftUI

@main
struct BardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 560)
        }

        Settings {
            SettingsView(viewModel: SettingsViewModel())
        }
    }
}
