import SwiftUI

@main
struct PocketInstrumentApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
                .tint(Theme.signal)
        }
    }
}
