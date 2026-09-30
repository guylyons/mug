import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion that keeps the display (and therefore the system) awake,
/// optionally releasing it after a fixed duration.
final class Caffeinator {
    private var assertionID: IOPMAssertionID = 0
    private var timer: Timer?

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
        onChange?()
    }

    func stop() {
        stop(notify: true)
    }

    private func stop(notify: Bool) {
        timer?.invalidate()
        timer = nil
        endDate = nil
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        if notify { onChange?() }
    }
}
