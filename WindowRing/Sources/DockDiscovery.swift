import AppKit
import ApplicationServices

/// Enumerates the actual Dock's contents (pinned apps, in Dock order, plus
/// any other running regular app not pinned) — this ring is a Dock
/// replacement/app launcher, not a window switcher: a pinned app that isn't
/// running gets launched on confirm, exactly like clicking it in the Dock.
///
/// Reads the Dock's own `persistent-apps` preference (the same "com.apple.dock"
/// domain the Dock itself is backed by) — a plain preference read, not a
/// private API call. `WindowInfo` is reused as the shared item shape for both
/// rings; `axElement`/`isMinimized` are unused here, and `pid` is `-1` for a
/// pinned-but-not-running app, since it has none yet.
enum DockDiscovery {
    struct Entry {
        let info: WindowInfo
        /// Where to launch this app from if it isn't already running.
        let launchURL: URL?
    }

    static func discoverDockApps() -> [Entry] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let runningByBundleID: [String: NSRunningApplication] = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPID }
                .compactMap { app in app.bundleIdentifier.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )

        var seenBundleIDs = Set<String>()
        var entries: [Entry] = []
        // Every non-running entry needs its own distinct (fake) pid: passing
        // the same pid (e.g. 0) to AXUIElementCreateApplication for more than
        // one entry produces AXUIElements that compare CFEqual, colliding as
        // the same WindowIdentity — fatal when used as a dictionary key.
        var nextSyntheticPID: pid_t = -2

        let persistentApps = (UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]]) ?? []
        for item in persistentApps {
            guard let tileData = item["tile-data"] as? [String: Any] else { continue }

            var bundleURL: URL?
            let bundleID = tileData["bundle-identifier"] as? String
            if let bundleID {
                bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            }
            if bundleURL == nil,
               let fileData = tileData["file-data"] as? [String: Any],
               let urlString = fileData["_CFURLString"] as? String {
                bundleURL = URL(string: urlString)
            }
            guard let url = bundleURL else { continue }

            let resolvedBundleID = bundleID ?? Bundle(url: url)?.bundleIdentifier
            if let resolvedBundleID {
                guard !seenBundleIDs.contains(resolvedBundleID) else { continue }
                seenBundleIDs.insert(resolvedBundleID)
            }

            let runningApp = resolvedBundleID.flatMap { runningByBundleID[$0] }
            let name = (tileData["file-label"] as? String) ?? FileManager.default.displayName(atPath: url.path)
            let icon = runningApp?.icon ?? NSWorkspace.shared.icon(forFile: url.path)
            let pid: pid_t
            if let runningApp {
                pid = runningApp.processIdentifier
            } else {
                pid = nextSyntheticPID
                nextSyntheticPID -= 1
            }
            let axElement = AXUIElementCreateApplication(pid > 0 ? pid : abs(pid))

            entries.append(Entry(
                info: WindowInfo(
                    id: WindowIdentity(element: axElement),
                    axElement: axElement,
                    pid: pid,
                    appName: name,
                    icon: icon,
                    title: name,
                    isMinimized: false
                ),
                launchURL: url
            ))
        }

        // Any other running regular app that isn't pinned in the Dock still
        // shows up, appended after the pinned set — same as the real Dock.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPID {
            guard let bundleID = app.bundleIdentifier, !seenBundleIDs.contains(bundleID) else { continue }
            seenBundleIDs.insert(bundleID)
            let axElement = AXUIElementCreateApplication(app.processIdentifier)
            entries.append(Entry(
                info: WindowInfo(
                    id: WindowIdentity(element: axElement),
                    axElement: axElement,
                    pid: app.processIdentifier,
                    appName: app.localizedName ?? "",
                    icon: app.icon,
                    title: app.localizedName ?? "",
                    isMinimized: false
                ),
                launchURL: nil
            ))
        }

        return entries
    }
}
