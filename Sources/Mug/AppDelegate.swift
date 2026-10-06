import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let caffeinator = Caffeinator()
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let offItem = NSMenuItem(title: "Turn Off", action: #selector(turnOff), keyEquivalent: "")
    private let mouseItem = NSMenuItem(title: "Also Move Mouse", action: #selector(toggleMouse), keyEquivalent: "")
    private let workHoursItem = NSMenuItem(title: "", action: #selector(chooseWorkHours), keyEquivalent: "")
    private var workHoursTimer: Timer?
    private var workHours = false

    /// Work hours as minutes since midnight. Defaults to 9–5.
    private var workStart: Int { UserDefaults.standard.object(forKey: "workStart") as? Int ?? 9 * 60 }
    private var workEnd: Int { UserDefaults.standard.object(forKey: "workEnd") as? Int ?? 17 * 60 }

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
        setWorkHours(UserDefaults.standard.bool(forKey: "workHours"))
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
        workHoursItem.target = self
        menu.addItem(workHoursItem)
        let editItem = NSMenuItem(title: "Set Work Hours…", action: #selector(editWorkHours), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        menu.addItem(.separator())
        mouseItem.target = self
        mouseItem.toolTip = "Nudges the cursor every minute you're idle, so chat apps don't mark you away"
        menu.addItem(mouseItem)
        offItem.target = self
        menu.addItem(offItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Mug", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        let icons = [
            (workHoursItem, "briefcase"), (editItem, "clock"),
            (mouseItem, "cursorarrow.motionlines"), (offItem, "power"), (quitItem, "xmark.circle"),
        ]
        for (item, symbol) in icons {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        setWorkHours(false)
        selectedIndex = sender.tag
        let minutes = options[sender.tag].minutes
        caffeinator.start(duration: minutes.map { TimeInterval($0 * 60) })
    }

    @objc private func turnOff() {
        setWorkHours(false)
        caffeinator.stop()
    }

    @objc private func chooseWorkHours() {
        setWorkHours(true)
    }

    /// Work-hours mode: keeps the Mac awake on weekdays between workStart and workEnd, checking every minute.
    private func setWorkHours(_ on: Bool) {
        workHours = on
        UserDefaults.standard.set(on, forKey: "workHours")
        workHoursTimer?.invalidate()
        workHoursTimer = nil
        guard on else { return refresh() }

        caffeinator.stop() // drop any other session, or one sized to old hours
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.checkWorkHours() }
        RunLoop.main.add(timer, forMode: .common)
        workHoursTimer = timer
        checkWorkHours()
    }

    private func checkWorkHours() {
        if let left = workSecondsLeft() {
            if !caffeinator.isActive { caffeinator.start(duration: left) }
        } else if caffeinator.isActive {
            caffeinator.stop()
        }
        refresh()
    }

    /// Seconds left in today's work hours, or nil if we're outside them (weekends count as outside).
    private func workSecondsLeft(at now: Date = Date()) -> TimeInterval? {
        let cal = Calendar.current
        guard !cal.isDateInWeekend(now),
              let start = cal.date(bySettingHour: workStart / 60, minute: workStart % 60, second: 0, of: now),
              let end = cal.date(bySettingHour: workEnd / 60, minute: workEnd % 60, second: 0, of: now),
              (start..<end).contains(now)
        else { return nil }
        return end.timeIntervalSince(now)
    }

    @objc private func editWorkHours() {
        let pickers = [workStart, workEnd].map { minutes -> NSDatePicker in
            let picker = NSDatePicker()
            picker.datePickerElements = .hourMinute
            picker.datePickerStyle = .textFieldAndStepper
            picker.dateValue = time(minutes)
            return picker
        }
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "From"), pickers[0], NSTextField(labelWithString: "to"), pickers[1],
        ])
        stack.frame.size = stack.fittingSize

        let alert = NSAlert()
        alert.messageText = "Work Hours"
        alert.informativeText = "Mug keeps your Mac awake between these times on weekdays."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true) // menu bar apps aren't frontmost, so the alert would hide
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let minutes = pickers.map { picker -> Int in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
            return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
        // ponytail: same-day hours only; overnight shifts (e.g. 10 PM–6 AM) would need wraparound in workSecondsLeft
        guard minutes[0] < minutes[1] else { return NSSound.beep() }
        UserDefaults.standard.set(minutes[0], forKey: "workStart")
        UserDefaults.standard.set(minutes[1], forKey: "workEnd")
        setWorkHours(true)
    }

    /// Today at the given minutes since midnight.
    private func time(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private func workHoursLabel() -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(f.string(from: time(workStart)))–\(f.string(from: time(workEnd)))"
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
        offItem.isEnabled = active || workHours
        workHoursItem.title = "During Work Hours (\(workHoursLabel()))"
        workHoursItem.state = workHours ? .on : .off
        mouseItem.state = caffeinator.movesMouse ? .on : .off
        statusLine.title = statusText()
    }

    private func statusText() -> String {
        guard caffeinator.isActive else {
            return workHours ? "Waiting for work hours — Mac can sleep" : "Mug is empty — Mac can sleep"
        }
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
