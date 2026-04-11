import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var viewModel: QuickViewModel?
    private var panel: NSPanel?
    private var welcomePanel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var statusItem: NSStatusItem?

    private let serverManager = ServerManager()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vm = QuickViewModel()
        self.viewModel = vm

        Task {
            await bootstrap(viewModel: vm)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor  { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseMonitor  { NSEvent.removeMonitor(monitor) }
        serverManager.stop()
    }

    // MARK: - Bootstrap

    private func bootstrap(viewModel: QuickViewModel) async {
        // a. Load settings from UserDefaults
        let settings = QuickSettings.load()

        // b. Update viewModel.settings
        viewModel.settings = settings

        // c. Create NSPanel with OverlayView hosted in NSHostingController
        let panel = makePanel(viewModel: viewModel)
        self.panel = panel

        // d. Register global hotkey (Ctrl+Space)
        registerGlobalHotkey()

        // e. Register local mouse monitor for click-outside dismissal
        registerMouseDismissMonitor()

        // f. Setup status bar item if settings.showMenuBar
        if settings.showMenuBar {
            setupStatusItem()
        }

        // Listen for Escape / dismiss notifications from OverlayView
        NotificationCenter.default.addObserver(
            forName: .dismissOverlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideOverlay() }
        }

        // g. Start ServerManager → on success, inject ApfelQuickService into viewModel
        if let port = await serverManager.start() {
            viewModel.service = ApfelQuickService(port: port)
        }

        // h. Show WelcomeOverlayView if !settings.hasSeenWelcome
        if !settings.hasSeenWelcome {
            showWelcomePanel()
        }

        // i. Check for update silently if settings.checkForUpdatesOnLaunch
        if settings.checkForUpdatesOnLaunch {
            await viewModel.checkForUpdateSilently()
        }
    }

    // MARK: - Panel construction

    private func makePanel(viewModel: QuickViewModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Center on active screen, upper third
        if let screen = NSScreen.main {
            let x = screen.frame.midX - 310
            let y = screen.frame.maxY - screen.frame.height * 0.35
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingController = NSHostingController(rootView: OverlayView(viewModel: viewModel))
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 56)
        panel.contentViewController = hostingController

        return panel
    }

    // MARK: - Show / Hide / Toggle

    func showOverlay() {
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hideOverlay() {
        guard let panel else { return }
        panel.orderOut(nil)
        viewModel?.input = ""
        viewModel?.clearOutput()
    }

    func toggleOverlay() {
        guard let panel else { return }
        if panel.isVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    // MARK: - Global hotkey (Ctrl+Space)

    private func registerGlobalHotkey() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
                  event.keyCode == 49 else { return }  // 49 = space
            Task { @MainActor [weak self] in self?.toggleOverlay() }
        }
    }

    // MARK: - Click-outside dismissal

    private func registerMouseDismissMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let clickPoint = event.locationInWindow
                // Convert screen-space click to panel coordinates
                let screenPoint: NSPoint
                if let window = event.window {
                    screenPoint = window.convertPoint(toScreen: clickPoint)
                } else {
                    screenPoint = clickPoint
                }
                if !panel.frame.contains(screenPoint) {
                    self.hideOverlay()
                }
            }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: "apfel-quick"
        )
        statusItem?.button?.action = #selector(handleStatusItemClick)
        statusItem?.button?.target = self
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleOverlay()
            return
        }
        if event.type == .rightMouseUp {
            let menu = buildContextMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            toggleOverlay()
        }
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Show apfel-quick",
            action: #selector(showOverlayFromMenu),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit apfel-quick",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }

    @objc private func showOverlayFromMenu() {
        showOverlay()
    }

    // MARK: - Welcome panel

    private func showWelcomePanel() {
        let welcomePanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        welcomePanel.title = "Welcome"
        welcomePanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 2)
        welcomePanel.isReleasedWhenClosed = false
        welcomePanel.center()

        let hostingController = NSHostingController(
            rootView: WelcomeOverlayView(onContinue: { [weak self, weak welcomePanel] in
                Task { @MainActor [weak self, weak welcomePanel] in
                    guard let self else { return }
                    self.viewModel?.settings.hasSeenWelcome = true
                    self.viewModel?.settings.save()
                    welcomePanel?.orderOut(nil)
                    self.welcomePanel = nil
                }
            })
        )
        welcomePanel.contentViewController = hostingController
        self.welcomePanel = welcomePanel
        welcomePanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - QuickViewModel extensions

extension QuickViewModel {

    // MARK: Silent update check

    /// Fetches latest release tag from GitHub and calls handleUpdateCheck.
    /// Never surfaces errors to the user.
    func checkForUpdateSilently() async {
        guard let url = URL(string: "https://api.github.com/repos/Arthur-Ficial/apfel-quick/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                await handleUpdateCheck(remoteVersion: tag)
            }
        } catch {
            // Silent — ignore network errors
        }
    }

}
