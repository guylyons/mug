import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let caffeinator = Caffeinator()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let offItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
    private let mouseItem = NSMenuItem(title: "Also Move Mouse", action: #selector(toggleMouse), keyEquivalent: "")

    /// Durations offered in the menu, in minutes. nil means indefinitely.
    private let options: [(title: String, minutes: Int?)] = [
        ("Indefinitely", nil),
        ("5 Minutes", 5),
        ("10 Minutes", 10),
        ("15 Minutes", 15),
        ("30 Minutes", 30),
        ("1 Hour", 60),
        ("2 Hours", 120),
    ]
    private var selectedIndex: Int?
    private var optionItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = buildMenu()

        caffeinator.onChange = { [weak self] in self?.refresh() }
        caffeinator.movesMouse = UserDefaults.standard.bool(forKey: "movesMouse")
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        caffeinator.stop()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            optionItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        mouseItem.target = self
        mouseItem.toolTip = "Nudges the cursor every minute you're idle, so chat apps don't mark you away"
        menu.addItem(mouseItem)
        offItem.target = self
        menu.addItem(offItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        selectedIndex = sender.tag
        let minutes = options[sender.tag].minutes
        caffeinator.start(duration: minutes.map { TimeInterval($0 * 60) })
    }

    @objc private func turnOff() {
        caffeinator.stop()
    }

    @objc private func toggleMouse() {
        caffeinator.movesMouse.toggle()
        UserDefaults.standard.set(caffeinator.movesMouse, forKey: "movesMouse")
        if caffeinator.movesMouse {
            // Prompts for Accessibility permission if not yet granted.
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        refresh()
    }

    private func refresh() {
        let active = caffeinator.isActive
        if !active { selectedIndex = nil }

        statusItem.button?.image = MugIcon.image(steaming: active)
        statusItem.button?.toolTip = active ? "Mug: keeping your Mac awake" : "Mug: off"

        for item in optionItems {
            item.state = (item.tag == selectedIndex) ? .on : .off
        }
        offItem.isEnabled = active
        mouseItem.state = caffeinator.movesMouse ? .on : .off
        statusLine.title = statusText()
    }

    private func statusText() -> String {
        guard caffeinator.isActive else { return "Mug is empty — Mac can sleep" }
        guard let end = caffeinator.endDate else { return "Keeping awake indefinitely" }

        let remaining = max(0, end.timeIntervalSinceNow)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return "Keeping awake — \(formatter.string(from: remaining) ?? "") left"
    }

    // Refresh the countdown each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        statusLine.title = statusText()
    }
}
