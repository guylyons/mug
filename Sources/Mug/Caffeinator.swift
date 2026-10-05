import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion that keeps the display (and therefore the system) awake,
/// optionally releasing it after a fixed duration.
final class Caffeinator {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?
    private var jiggleTimer: Timer?

    /// Also nudge the mouse while active, so apps that watch for input (Teams, Slack) don't go idle.
    var movesMouse = false {
        didSet { updateJiggle() }
    }

    /// When the current session ends, or nil if running indefinitely / inactive.
    private(set) var endDate: Date?

    var isActive: Bool { assertionID != 0 }

    var onChange: (() -> Void)?

    /// Starts keeping the Mac awake. Pass nil for indefinitely.
    func start(duration: TimeInterval?) {
        stop(notify: false)

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Mug is keeping this Mac awake" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            assertionID = 0
            onChange?()
            return
        }

        if let duration {
            endDate = Date().addingTimeInterval(duration)
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                self?.stop()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        updateJiggle()
        onChange?()
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        timer?.invalidate()
        timer = nil
        endDate = nil
        jiggleTimer?.invalidate()
        jiggleTimer = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if notify { onChange?() }
    }

    private func updateJiggle() {
        jiggleTimer?.invalidate()
        jiggleTimer = nil
        guard movesMouse, isActive else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { _ in Caffeinator.jiggle() }
        RunLoop.main.add(timer, forMode: .common)
        jiggleTimer = timer
    }

    /// Moves the cursor 1pt and back, only if the user has been idle, so it never fights real input.
    /// Posting events needs Accessibility permission; without it the events are silently dropped.
    private static func jiggle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= 55, let here = CGEvent(source: nil)?.location else { return }
        for point in [CGPoint(x: here.x + 1, y: here.y), here] {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }
}
