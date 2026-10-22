import Foundation

/// A short startup burst followed by a cooldown, rather than a lifetime ban.
/// Driven by foreground preparation; does not poll or wake an inactive app.
public struct RetryBudget {
    private var attempts = 0
    private var last: TimeInterval?
    public init() {}
    public var shouldRetrySoon: Bool { attempts < 3 }
    public mutating func begin(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        if let last {
            let elapsed = now - last
            guard elapsed >= (attempts >= 3 ? 15 : 1) else { return false }
            if attempts >= 3 { attempts = 0 }
        }
        attempts += 1; last = now
        return true
    }
}
