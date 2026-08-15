import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@main
struct IPTVWallApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                #if os(macOS)
                .background(MacWindowCloseTerminator())
                #endif
        }
    }
}

#if os(iOS)
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .all
    }
}
#endif

#if os(macOS)
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct MacWindowCloseTerminator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            attachDelegate(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            attachDelegate(from: nsView)
        }
    }

    private func attachDelegate(from view: NSView) {
        guard let window = view.window else { return }
        if window.delegate !== MacWindowCloseDelegate.shared {
            window.delegate = MacWindowCloseDelegate.shared
        }
        MacWindowCloseDelegate.shared.zoomOnFirstAppearance(window)
    }
}

private final class MacWindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = MacWindowCloseDelegate()
    private var zoomedWindows = Set<ObjectIdentifier>()

    func zoomOnFirstAppearance(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard zoomedWindows.insert(identifier).inserted else { return }
        DispatchQueue.main.async {
            guard window.isVisible, !window.isZoomed else { return }
            window.zoom(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
#endif
