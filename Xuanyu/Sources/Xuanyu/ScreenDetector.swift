import AppKit

enum ScreenDetector {
    static var preferredScreen: NSScreen {
        NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    static func screenHasNotch(_ screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
    }

    static func topBarHeight(for screen: NSScreen) -> CGFloat {
        let safeAreaHeight = screen.safeAreaInsets.top
        if safeAreaHeight > 0 { return safeAreaHeight }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBarHeight > 5 ? menuBarHeight : 25
    }

    static func notchWidth(for screen: NSScreen) -> CGFloat {
        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        if leftWidth > 0 || rightWidth > 0 {
            return screen.frame.width - leftWidth - rightWidth
        }
        return 190
    }

    static func defaultCollapsedIslandWidth(for screen: NSScreen) -> CGFloat {
        let minimumWidth: CGFloat = screenHasNotch(screen) ? 220 : 190
        return min(max(notchWidth(for: screen), minimumWidth), screen.frame.width - 24)
    }

    static func collapsedIslandWidth(for screen: NSScreen) -> CGFloat {
        defaultCollapsedIslandWidth(for: screen)
    }

    static func collapsedDropdownHeight(for screen: NSScreen, usesTallDropdown: Bool) -> CGFloat {
        guard screenHasNotch(screen) else { return 0 }
        return usesTallDropdown ? 44 : 36
    }

    static func idleCollapsedDropdownHeight(for screen: NSScreen) -> CGFloat {
        collapsedDropdownHeight(for: screen, usesTallDropdown: false) * 0.5
    }

    static func collapsedIslandHeight(for screen: NSScreen, usesTallDropdown: Bool) -> CGFloat {
        topBarHeight(for: screen) + collapsedDropdownHeight(for: screen, usesTallDropdown: usesTallDropdown)
    }

    static func collapsedIslandHeight(for screen: NSScreen, usesTallDropdown: Bool, isIdle: Bool) -> CGFloat {
        let dropdownHeight = isIdle ? idleCollapsedDropdownHeight(for: screen) : collapsedDropdownHeight(for: screen, usesTallDropdown: usesTallDropdown)
        return topBarHeight(for: screen) + dropdownHeight
    }
}
