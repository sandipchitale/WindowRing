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
                guard isStandardWindow(axWindow) else { continue }

                let minimized = (copyAttribute(axWindow, kAXMinimizedAttribute) as? Bool) ?? false
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

    /// Filters out palettes, sheets, and other non-standard AX windows so the
    /// ring only shows things a user would recognize as "a window".
    private static func isStandardWindow(_ element: AXUIElement) -> Bool {
        // The role check is what keeps the Finder out of the ring when it has
        // no windows open: the desktop is published in Finder's
        // kAXWindowsAttribute as an AXScrollArea with no subrole at all, so
        // the lenient subrole fallback below would otherwise let it through.
        guard let role = copyAttribute(element, kAXRoleAttribute) as? String, role == kAXWindowRole else {
            return false
        }
        guard let subrole = copyAttribute(element, kAXSubroleAttribute) as? String else {
            // Some apps (older Java/cross-platform toolkits) omit subrole entirely;
            // don't punish them for it.
            return true
        }
        return subrole == kAXStandardWindowSubrole
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }
}
