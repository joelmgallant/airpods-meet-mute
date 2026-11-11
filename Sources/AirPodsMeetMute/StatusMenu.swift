import AppKit

/// Builds the status-item menu. AppDelegate owns the state and the actions.
enum StatusMenu {
    static func build(
        statusLine: String,
        problems: [String],
        launchAtLoginEnabled: Bool,
        actionTarget: AnyObject,
        toggleLaunchAtLogin: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(statusLine))
        for problem in problems {
            menu.addItem(disabledItem("⚠️ " + problem))
        }
        menu.addItem(.separator())
        let loginItem = NSMenuItem(title: "Launch at Login", action: toggleLaunchAtLogin, keyEquivalent: "")
        loginItem.target = actionTarget
        loginItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit AirPods Meet Mute", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
