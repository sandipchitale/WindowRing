import AppKit
import ApplicationServices

/// Enumerates individual windows via the Accessibility API.
///
/// Deliberately does NOT use `CGWindowListCopyWindowInfo`: since macOS
/// Catalina, that API only returns another process's window *title*
/// (`kCGWindowName`) if the caller has Screen Recording permission. The AX
/// API gives us titles, minimized state, and everything else we need with
/// just Accessibility trust — one less permission to ask the user for.
enum WindowDiscovery {
    static func discoverWindows(includeMinimized: Bool, includeHidden: Bool) -> [WindowInfo] {
        var results: [WindowInfo] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            guard app.processIdentifier != myPID else { continue }
            if app.isHidden && !includeHidden { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let axWindows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }

            for axWindow in axWindows {
                // Read minimized state first: it's part of deciding whether
                // this counts as a window at all, not just whether to show it.
                let minimized = (copyAttribute(axWindow, kAXMinimizedAttribute) as? Bool) ?? false
                guard isRingWorthyWindow(axWindow, isMinimized: minimized) else { continue }
                if minimized && !includeMinimized { continue }

                let rawTitle = (copyAttribute(axWindow, kAXTitleAttribute) as? String) ?? ""
                let title = rawTitle.isEmpty ? (app.localizedName ?? "Window") : rawTitle

                results.append(
                    WindowInfo(
                        id: WindowIdentity(element: axWindow),
                        axElement: axWindow,
                        pid: app.processIdentifier,
                        appName: app.localizedName ?? "",
                        icon: app.icon,
                        title: title,
                        isMinimized: minimized
                    )
                )
            }
        }
        return results
    }

    /// Filters out palettes, sheets, and other non-window AX elements so the
    /// ring only shows things a user would recognize as "a window".
    private static func isRingWorthyWindow(_ element: AXUIElement, isMinimized: Bool) -> Bool {
        // The role check is what keeps the Finder out of the ring when it has
        // no windows open: the desktop is published in Finder's
        // kAXWindowsAttribute as an AXScrollArea with no subrole at all, so
        // the lenient subrole rules below would otherwise let it through.
        guard let role = copyAttribute(element, kAXRoleAttribute) as? String, role == kAXWindowRole else {
            return false
        }
        guard let subrole = copyAttribute(element, kAXSubroleAttribute) as? String else {
            // Some apps (older Java/cross-platform toolkits) omit subrole entirely;
            // don't punish them for it.
            return true
        }
        if subrole == kAXStandardWindowSubrole {
            return true
        }
        // Once minimized, most apps stop reporting AXStandardWindow and report
        // AXDialog instead — Calendar, Notes and System Settings all do it for
        // their plain main window, though Chrome doesn't. Insisting on
        // AXStandardWindow therefore hid exactly the minimized windows the
        // ring exists to get back to. Anything already minimized is by
        // definition a window the user put away and may want to restore, so
        // subrole is not worth second-guessing in that state; real dialogs and
        // palettes are still excluded while they're actually on screen.
        return isMinimized
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }
}
