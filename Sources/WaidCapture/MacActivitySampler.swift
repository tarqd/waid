#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import WaidCore

/// Samples the frontmost app, its focused window's title and document, the
/// active browser tab's URL, and the time since last input.
///
/// Needs the Accessibility permission for window titles and documents, and
/// Automation permission (per browser) for URLs. Without them it degrades to
/// app-level tracking. Must be called on the main thread (NSAppleScript).
public final class MacActivitySampler {
    /// Browsers whose URL we can read via AppleScript, keyed by bundle id.
    static let browserScripts: [String: String] = {
        let chromium = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
                        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser"]
        var scripts = ["com.apple.Safari": "tell application id \"com.apple.Safari\" to get URL of front document"]
        for id in chromium {
            scripts[id] = "tell application id \"\(id)\" to get URL of active tab of front window"
        }
        return scripts
    }()

    private var compiled: [String: NSAppleScript] = [:]
    /// Apps that refused Automation access; don't ask again this run.
    private var urlDenied: Set<String> = []

    public init() {}

    /// Whether we have Accessibility access. With `prompt`, macOS shows the
    /// system dialog pointing the user at System Settings.
    @discardableResult
    public static func accessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    public func sample() -> ActivitySample? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var sample = ActivitySample(
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            idleSeconds: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: CGEventType(rawValue: ~0)!))

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if let window = element(axApp, kAXFocusedWindowAttribute as String) {
            sample.title = string(window, kAXTitleAttribute as String)
            if let document = string(window, kAXDocumentAttribute as String),
               let url = URL(string: document), url.isFileURL {
                sample.path = url.path
            }
        }
        if let bundleID = app.bundleIdentifier, Self.browserScripts[bundleID] != nil {
            sample.url = browserURL(bundleID: bundleID)
        }
        return sample
    }

    private func browserURL(bundleID: String) -> String? {
        guard !urlDenied.contains(bundleID), let source = Self.browserScripts[bundleID] else { return nil }
        let script = compiled[bundleID] ?? NSAppleScript(source: source)
        compiled[bundleID] = script
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            // -1743: the user denied Automation access to this browser.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 { urlDenied.insert(bundleID) }
            return nil
        }
        return result?.stringValue
    }

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}
#endif
