import AppKit
import SwiftUI

@main
struct LitheApp: App {
    @NSApplicationDelegateAdaptor(LitheAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            LitheSettingsView()
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class LitheAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: SessionCoordinator?
    private var pendingURLs: [URL] = []
    private var settingsController: LitheSettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LitheDefaults.register()
        SessionFileStore.cleanAbandonedSessions()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let coordinator = try SessionCoordinator()
            self.coordinator = coordinator
            if !pendingURLs.isEmpty {
                coordinator.receive(urls: pendingURLs)
                pendingURLs.removeAll()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.coordinator?.hasActiveSession != true else { return }
                    self.showSettings()
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let coordinator {
            coordinator.receive(urls: urls)
            settingsController?.close()
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator?.prepareForTermination()
        return .terminateNow
    }

    private func showSettings() {
        if let settingsController {
            NSApp.activate(ignoringOtherApps: true)
            settingsController.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = LitheSettingsWindowController { [weak self] in
            guard let self else { return }
            self.settingsController = nil
            if self.coordinator?.hasActiveSession != true {
                NSApp.terminate(nil)
            }
        }
        settingsController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }
}

@MainActor
private final class LitheSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Lithe 设置"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LitheSettingsView())
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose() }
}
