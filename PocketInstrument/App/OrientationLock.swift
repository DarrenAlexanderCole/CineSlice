import UIKit

/// CineSlice is a portrait instrument, but a 16:9 picture deserves the whole screen: Watch unlocks
/// landscape for horizontal projects and locks back to portrait when it closes. Info.plist lists
/// the landscape orientations so they can be unlocked; this mask decides what's allowed right now.
@MainActor
enum OrientationLock {
    private(set) static var allowed: UIInterfaceOrientationMask = .portrait

    /// Allows `mask`, turning the screen if its current orientation is no longer allowed.
    static func allow(_ mask: UIInterfaceOrientationMask) {
        guard mask != allowed else { return }
        allowed = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if mask == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask
    {
        OrientationLock.allowed
    }
}
