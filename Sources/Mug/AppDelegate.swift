import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let caffeinator = Caffeinator()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let offItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")

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

    private func refresh() {
        let active = caffeinator.isActive
        if !active { selectedIndex = nil }

        statusItem.button?.image = MugIcon.image(steaming: active)
        statusItem.button?.toolTip = active ? "Mug: keeping your Mac awake" : "Mug: off"

        for item in optionItems {
            item.state = (item.tag == selectedIndex) ? .on : .off
        }
        offItem.isEnabled = active
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
