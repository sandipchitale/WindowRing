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
                // Role is checked before anything else is read: it rejects the
                // most elements (Finder's desktop, sheets, popovers, palettes)
                // and every further attribute is a separate cross-process
                // round trip, paid per element on the sweep the user is
                // waiting on.
                guard hasWindowRole(axWindow) else { continue }

                // Minimized state is part of deciding whether this counts as a
                // window at all, not just whether to show it.
                let minimized = (copyAttribute(axWindow, kAXMinimizedAttribute) as? Bool) ?? false
                if minimized && !includeMinimized { continue }
                guard hasWindowSubrole(axWindow, isMinimized: minimized) else { continue }

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

    /// The first half of "is this a window a user would switch to": it must
    /// actually be one. This is what keeps the Finder out of the ring when it
    /// has no windows open — the desktop is published in Finder's
    /// kAXWindowsAttribute as an AXScrollArea with no subrole at all, so the
    /// lenient subrole rules below would otherwise let it through.
    private static func hasWindowRole(_ element: AXUIElement) -> Bool {
        (copyAttribute(element, kAXRoleAttribute) as? String) == kAXWindowRole
    }

    /// The second half: filters out dialogs, palettes and sheets, which are
    /// windows by role but not things a user switches between.
    private static func hasWindowSubrole(_ element: AXUIElement, isMinimized: Bool) -> Bool {
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
