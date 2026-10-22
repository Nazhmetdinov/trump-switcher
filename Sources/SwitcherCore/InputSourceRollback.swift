import Foundation

/// Ownership of a source switch before the edit is committed, independent of Carbon and AX.
/// Successful automatic edits keep their selected source; only refused preflights roll back.
/// Failure must never overwrite a later user source or destination change.
public struct InputSourceRollback {
    private let previous: KeyboardLayoutTable
    private let temporary: KeyboardLayoutTable
    private let startedAt: UInt64
    private let destinationPID: Int32

    public init?(previous: KeyboardLayoutTable, temporary: KeyboardLayoutTable, startedAt: UInt64, destinationPID: Int32) {
        guard previous.id != temporary.id else { return nil }
        self.previous = previous; self.temporary = temporary
        self.startedAt = startedAt; self.destinationPID = destinationPID
    }

    public func restore(preserving prior: QueuedLayoutTransition?, currentSource: () -> String?,
                        foregroundPID: () -> Int32?, selectPrevious: () -> Bool,
                        restoredAt: () -> UInt64) -> QueuedLayoutTransition? {
        guard prior?.canPreserveAdditionalWindow != false,
              currentSource() == temporary.id, foregroundPID() == destinationPID,
              selectPrevious(), currentSource() == previous.id, foregroundPID() == destinationPID else { return nil }
        return QueuedLayoutTransition(previous: temporary, target: previous, boundary: startedAt,
                                      selectedAt: restoredAt(), preserving: prior)
    }
}
