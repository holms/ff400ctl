import SwiftUI
import AppKit
import OSLog
import ServiceManagement
import CoreAudio
import FFCore
import FFModel

private let trayLog = Logger(subsystem: "net.holms.fftray", category: "ui")

@main
struct FFTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Persistent status item + popover live in AppDelegate — the
        // panel is built once, not per-click like MenuBarExtra(.window).
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var presenceWatcher: PresenceWatcher?
    private let detachController = DetachWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Dock/Cmd-Tab icon for an LSUIElement app that flips to
        // .regular can come from a stale LaunchServices cache — set it
        // explicitly from the bundled AppIcon.icns.
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        let t0 = Date()
        let hosting = NSHostingController(
            rootView: ContentView().environmentObject(model))
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.contentViewController = hosting
        // Prewarm: size + lay out the whole view once at launch so even
        // the first click is fast. `ms` is what MenuBarExtra paid per open.
        hosting.view.frame = NSRect(origin: .zero, size: hosting.view.fittingSize)
        hosting.view.layoutSubtreeIfNeeded()
        pop.contentSize = hosting.view.fittingSize
        popover = pop

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "slider.horizontal.3",
                              accessibilityDescription: "FF400")
            b.imagePosition = .imageLeading
            b.title = "FF400"
            b.target = self
            b.action = #selector(togglePopover)
        }
        statusItem = item

        model.onDetach = { [weak pop] in pop?.performClose(nil) }
        model.onOpenDetached = { [weak self] in
            guard let self else { return }
            self.detachController.open(model: self.model)
        }
        model.syncLaunchAtLogin()

        // Re-apply the mix when the FF400 returns from a power cycle.
        let watcher = PresenceWatcher { [weak model] in
            guard let model, model.autoReapply else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak model] in
                model?.deviceReappeared()
            }
        }
        presenceWatcher = watcher

        trayLog.notice("panel built in \(Date().timeIntervalSince(t0) * 1000, privacy: .public) ms")
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushAndSave()
    }

    @objc private func togglePopover() {
        guard let pop = popover, let button = statusItem.button else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Launch-at-login toggle (SMAppService needs a bundled app, so it
/// lives in the app target, not FFModel).
extension MixerModel {
    func syncLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Register/unregister FFTray as a login item (macOS 13+ SMAppService).
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Watches the CoreAudio device list; fires `onReappear` once per
/// absent→present edge of the FF400 (a power cycle wipes mixer RAM, so
/// the mix needs re-applying). All CoreAudio code stays in the app.
final class PresenceWatcher {
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var tracker: DevicePresence.Tracker

    init(onReappear: @escaping () -> Void) {
        tracker = DevicePresence.Tracker(present: Self.firefacePresent())
        var addr = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            if self.tracker.update(present: Self.firefacePresent()) {
                onReappear()
            }
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    deinit {
        if let block = deviceListenerBlock {
            var addr = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                DispatchQueue.main, block)
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// True when any CoreAudio device name matches the Fireface 400.
    private static func firefacePresent() -> Bool {
        var addr = devicesAddress
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr
        else { return false }
        var ids = [AudioDeviceID](repeating: 0,
                                count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr
        else { return false }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        for id in ids {
            var name: CFString = "" as CFString
            var ns = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &ns, &name) == noErr,
               DevicePresence.isFireface400(name: name as String) { return true }
        }
        return false
    }
}

/// Owns the persistent, movable mixer window opened by Detach.
final class DetachWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Open the same UI in a persistent titled window that survives focus
    /// changes (the menu-bar panel auto-closes whenever it loses focus).
    func open(model: MixerModel) {
        if window == nil {
            let host = NSHostingController(
                rootView: ContentView(detached: true).environmentObject(model))
            let w = NSWindow(contentViewController: host)
            w.title = "Fireface 400 Mixer"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 660,
                                      height: host.view.fittingSize.height)
            w.delegate = self
            w.center()
            window = w
            // Make the window Cmd-Tab reachable while it's open.
            NSApp.setActivationPolicy(.regular)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
