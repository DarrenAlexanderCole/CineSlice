import UIKit

/// CineSlice is a portrait instrument; turning the phone sideways inside a project reveals the
/// LIGHTBOX editing table, and Watch fills the screen with a 16:9 picture. Info.plist lists the
/// landscape orientations so they can be unlocked; this mask decides what's allowed right now.
@MainActor
enum OrientationLock {
    private(set) static var allowed: UIInterfaceOrientationMask = .portrait
    /// What the current screen allows when nothing is overriding it: portrait in the library,
    /// portrait and landscape in a project. Watch and Done return here.
    private(set) static var base: UIInterfaceOrientationMask = .portrait
    private static var portraitObserver: NSObjectProtocol?

    /// Allows `mask`, turning the screen if its current orientation is no longer allowed.
    static func allow(_ mask: UIInterfaceOrientationMask) {
        guard mask != allowed else { return }
        allowed = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if mask == .portrait { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
    }

    /// Sets what this screen allows and applies it.
    static func setBase(_ mask: UIInterfaceOrientationMask) {
        stopWaitingForPortrait()
        base = mask
        allow(mask)
    }

    /// Goes back to `base` (after Watch).
    static func restoreBase() { allow(base) }

    /// Turns the screen to portrait while the phone is still held sideways (LIGHTBOX's Done), and
    /// unlocks landscape again only once the phone itself has been turned upright, so it doesn't
    /// spin straight back.
    static func returnToPortrait() {
        allow(.portrait)
        guard base != .portrait, portraitObserver == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        portraitObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard UIDevice.current.orientation == .portrait else { return }
                stopWaitingForPortrait()
                allow(base)
            }
        }
    }

    private static func stopWaitingForPortrait() {
        guard let portraitObserver else { return }
        NotificationCenter.default.removeObserver(portraitObserver)
        self.portraitObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask
    {
        OrientationLock.allowed
    }
}
