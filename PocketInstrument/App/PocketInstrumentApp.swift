import AVFoundation
import SwiftUI

@main
struct PocketInstrumentApp: App {
    init() {
        // The default session (.soloAmbient) obeys the ring/silent switch, so preview was mute on a
        // silenced iPhone while exported files played fine in Photos. An editor should always be heard.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .tint(Theme.signal)
        }
    }
}
