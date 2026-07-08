import SwiftUI

@main
struct BardApp: App {
    init() {
        NotificationService.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Kept generously above the sum of the sidebar's + detail panels'
                // own minimums (~860pt) so the layout never has to fight over the
                // last few points of width — that's what caused visible glitches
                // at anything less than a very large window.
                .frame(minWidth: 1100, minHeight: 660)
                .font(.system(.body, design: .serif))
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView(viewModel: SettingsViewModel())
                .font(.system(.body, design: .serif))
        }
    }
}
