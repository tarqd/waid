#if os(macOS)
import AppKit
import ApplicationServices

/// Reports when what is in front may have changed, so the daemon can sample at
/// the moment of a switch instead of up to one heartbeat later.
///
/// Four signals count as a change: another app came to the front
/// (`NSWorkspace`), or the front app's focused window, main window or focused
/// window's title changed (Accessibility notifications). Bursts within
/// `debounce` collapse into one `onChange`, since a page load posts several
/// titles in a row, and a sample taken after the burst sees the one that stuck.
///
/// Without the Accessibility permission only app switches are reported. Must
/// be started on the main thread; `onChange` is called there too.
public final class FocusChangeObserver {
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var activationObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    /// The Accessibility observer for the front app, and what it watches.
    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?

    private static let appNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]
    /// Handed to Accessibility so the callback can find us; `stop()` runs
    /// before we go away, so the pointer never outlives `self`.
    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    public init(debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.watch(pid: app?.processIdentifier)
            self.changed()
        }
        watch(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    public func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        pending?.cancel()
        pending = nil
        watch(pid: nil)
    }

    /// Schedules `onChange` once the burst of notifications has settled.
    private func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.onChange()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// Moves the Accessibility observer to the app with `pid`, or drops it.
    private func watch(pid: pid_t?) {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedApp = nil
        observedWindow = nil
        guard let pid else { return }

        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(pid)
        for name in Self.appNotifications {
            // Fails without Accessibility access; app switches still arrive.
            _ = AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedApp = app
        watchFocusedWindowTitle()
    }

    /// Title changes are posted by the window, not the app, so the observer
    /// follows the focused window as it changes.
    private func watchFocusedWindowTitle() {
        guard let observer, let app = observedApp else { return }
        if let window = observedWindow {
            _ = AXObserverRemoveNotification(observer, window, kAXTitleChangedNotification as CFString)
        }
        observedWindow = nil
        guard let window = MacActivitySampler.element(app, kAXFocusedWindowAttribute as String) else { return }
        if AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon) == .success {
            observedWindow = window
        }
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let observer = Unmanaged<FocusChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
        if (notification as String) != kAXTitleChangedNotification {
            observer.watchFocusedWindowTitle()
        }
        observer.changed()
    }
}
#endif
