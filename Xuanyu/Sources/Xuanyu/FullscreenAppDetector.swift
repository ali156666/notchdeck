import AppKit
import CoreGraphics

enum FullscreenAppDetector {
    private static let geometryTolerance: CGFloat = 4

    static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        let selfBundleIdentifier = Bundle.main.bundleIdentifier
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        if let frontmostApp,
           frontmostApp.bundleIdentifier != selfBundleIdentifier,
           hasAccessibilityFullscreenWindow(for: frontmostApp) {
            return true
        }

        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let frontmostApp,
           frontmostApp.bundleIdentifier != selfBundleIdentifier {
            let appWindows = windows.filter { ownerPID(in: $0) == frontmostApp.processIdentifier }
            return hasFullscreenWindow(in: appWindows, on: screen)
        }

        let windowsByOwner = Dictionary(grouping: windows) { window in
            ownerPID(in: window) ?? 0
        }
        return windowsByOwner.contains { pid, appWindows in
            pid != 0 && pid != selfPID && hasFullscreenWindow(in: appWindows, on: screen)
        }
    }

    private static func hasFullscreenWindow(in windows: [[String: Any]], on screen: NSScreen) -> Bool {
        if windows.contains(where: { window in
            guard alpha(in: window) > 0.01, let bounds = bounds(in: window) else { return false }
            return isPhysicalFullscreen(bounds: bounds, on: screen)
        }) {
            return true
        }

        return hasFullscreenSpaceSurfaces(windows, on: screen)
    }

    private static func hasAccessibilityFullscreenWindow(for app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else {
            return false
        }

        return windows.contains { window in
            var fullscreenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue) == .success,
                  let isFullscreen = fullscreenValue as? Bool
            else {
                return false
            }
            return isFullscreen
        }
    }

    private static func isPhysicalFullscreen(bounds: CGRect, on screen: NSScreen) -> Bool {
        let screenSize = screen.frame.size
        let widthMatches = bounds.width >= screenSize.width - geometryTolerance
        let heightMatches = bounds.height >= screenSize.height - geometryTolerance
        return widthMatches && heightMatches
    }

    private static func hasFullscreenSpaceSurfaces(_ windows: [[String: Any]], on screen: NSScreen) -> Bool {
        let screenWidth = screen.frame.width
        let visibleFrameInWindowCoordinates = visibleFrameInCGWindowCoordinates(for: screen)
        let hasMaximizedMainWindow = windows.contains { window in
            guard layer(in: window) == 0,
                  alpha(in: window) > 0.01,
                  let bounds = bounds(in: window)
            else {
                return false
            }

            let matchesVisibleFrame = abs(bounds.minY - visibleFrameInWindowCoordinates.minY) <= geometryTolerance &&
            abs(bounds.width - visibleFrameInWindowCoordinates.width) <= geometryTolerance &&
            abs(bounds.height - visibleFrameInWindowCoordinates.height) <= geometryTolerance
            return matchesVisibleFrame
        }

        guard hasMaximizedMainWindow else { return false }

        let hasFullscreenControlsSurface = windows.contains { window in
            guard layer(in: window) == 0,
                  alpha(in: window) > 0.01,
                  let bounds = bounds(in: window)
            else {
                return false
            }

            let isFullWidth = bounds.width >= screenWidth - geometryTolerance
            let isOffscreenVerticalStrip = bounds.minY < screen.frame.minY - 8 && bounds.height <= 80
            let isTopOverlay = abs(bounds.minY - visibleFrameInWindowCoordinates.minY) <= geometryTolerance && (80...180).contains(bounds.height)
            return isFullWidth && (isOffscreenVerticalStrip || isTopOverlay)
        }

        let hasHiddenFullscreenMenuSurface = windows.contains { window in
            guard layer(in: window) >= 20,
                  alpha(in: window) <= 0.01,
                  let bounds = bounds(in: window)
            else {
                return false
            }

            return bounds.width >= screenWidth - geometryTolerance &&
            bounds.height <= 40 &&
            abs(bounds.minY - screen.frame.minY) <= geometryTolerance
        }

        return hasHiddenFullscreenMenuSurface || hasFullscreenControlsSurface
    }

    private static func visibleFrameInCGWindowCoordinates(for screen: NSScreen) -> CGRect {
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        return CGRect(
            x: screen.visibleFrame.minX,
            y: screen.frame.minY + topInset,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
    }

    private static func ownerPID(in window: [String: Any]) -> pid_t? {
        if let pid = window[kCGWindowOwnerPID as String] as? pid_t {
            return pid
        }
        if let number = window[kCGWindowOwnerPID as String] as? NSNumber {
            return pid_t(number.int32Value)
        }
        return nil
    }

    private static func layer(in window: [String: Any]) -> Int {
        if let layer = window[kCGWindowLayer as String] as? Int {
            return layer
        }
        if let number = window[kCGWindowLayer as String] as? NSNumber {
            return number.intValue
        }
        return 0
    }

    private static func alpha(in window: [String: Any]) -> Double {
        if let alpha = window[kCGWindowAlpha as String] as? Double {
            return alpha
        }
        if let number = window[kCGWindowAlpha as String] as? NSNumber {
            return number.doubleValue
        }
        return 1
    }

    private static func bounds(in window: [String: Any]) -> CGRect? {
        guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(dictionary, &bounds) else {
            return nil
        }
        return bounds
    }
}
