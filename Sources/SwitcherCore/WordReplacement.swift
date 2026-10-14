import Foundation

/// A replacement refers only to the complete word immediately before a collapsed
/// caret. The caller supplies a bounded read, never the document's AXValue.
public struct WordReplacementPlan {
    public let original: String
    public let replacement: String
    public let initialSelection: NSRange
    public let target: NSRange
    public let resultRange: NSRange
    public let resultSelection: NSRange

    public init?(original: String, replacement: String, selection: NSRange,
                 beforeCaret: String, afterCaret: String?) {
        let length = original.utf16.count
        guard (1...128).contains(length), (1...128).contains(replacement.utf16.count),
              original != replacement, selection.location != NSNotFound,
              selection.location >= length, selection.length == 0,
              selection.location <= Int.max - replacement.utf16.count,
              ReplacementContext.matches(original: original, beforeCaret: beforeCaret,
                  afterCaret: afterCaret, selectionLength: selection.length) else { return nil }
        self.original = original; self.replacement = replacement
        initialSelection = selection
        target = NSRange(location: selection.location - length, length: length)
        resultRange = NSRange(location: target.location, length: replacement.utf16.count)
        resultSelection = NSRange(location: NSMaxRange(resultRange), length: 0)
    }
}

public enum WordReplacementResult: Equatable {
    /// No operation was attempted; a different transport may be used.
    case unsupported
    /// Context changed before the text write. Never retry against another field.
    case refused
    case confirmed
    /// A write was attempted but was not acknowledged. Never delete/type again.
    case unconfirmed
    /// A selection request/write may still own the word. Passing a boundary
    /// could erase it. Automatic callers must not use mutable-selection
    /// transports unless they can also hold subsequent input safely.
    case unsafeSelection
}

public enum WordReplacementRequestResult: Equatable {
    /// The API accepted the request. Readback must still confirm its effect.
    case accepted
    /// The API definitively rejected the request without queuing a mutation.
    case rejected
    /// A timeout/failure is not proof that the mutation will never arrive.
    case uncertain
}

/// A manual AXTextOperation may intentionally select the replacement (WebKit).
/// This read-only plan distinguishes that exact selection from an unrelated
/// cursor change. It preserves an explicitly selected phrase, or restores a
/// caret when the operation started there. No unreplaced text is collapsed.
public struct MarkerReplacementPlan {
    /// `collapse` requests the verified final selection shape. Its range is
    /// collapsed for caret conversion and nonempty for a selected phrase.
    public enum State: Equatable { case waiting, complete, collapse(NSRange), changed }
    public let initialCaret: NSRange
    public let originalRange: NSRange
    public let replacementRange: NSRange
    public let finalCaret: NSRange
    public let finalSelection: NSRange
    private let before: String
    private let after: String

    public init?(initialCaret: NSRange, target: NSRange, before: String, after: String) {
        let limit = initialCaret.length == 0 ? 128 : 4096
        guard initialCaret.location != NSNotFound, initialCaret.location >= 0, initialCaret.length >= 0,
              target.location != NSNotFound, target.location >= 0, (1...limit).contains(target.length),
              target.location <= Int.max - target.length,
              before.utf16.count == target.length, (1...limit).contains(after.utf16.count), before != after else { return nil }
        let caretBase: Int
        if initialCaret.length == 0 {
            guard target.location <= initialCaret.location, target.length <= initialCaret.location - target.location,
                  initialCaret.location - target.location <= 128 else { return nil }
            caretBase = initialCaret.location - target.length
        } else {
            // A selected conversion may replace only that exact selection,
            // never a guessed word, subrange, or adjacent text. Its existing
            // 4096-unit manual bound requires no traversal from a caret.
            guard initialCaret == target else { return nil }
            caretBase = target.location
        }
        guard caretBase <= Int.max - after.utf16.count else { return nil }
        self.initialCaret = initialCaret; originalRange = target
        replacementRange = NSRange(location: target.location, length: after.utf16.count)
        finalCaret = NSRange(location: caretBase + after.utf16.count, length: 0)
        finalSelection = initialCaret.length == 0 ? finalCaret : replacementRange
        self.before = before; self.after = after
    }

    public func state(selection: NSRange, originalText: String?, replacementText: String?) -> State {
        if replacementText == after {
            if selection == finalSelection { return .complete }
            let convertibleSelection = initialCaret.length == 0 ? replacementRange : finalCaret
            if selection == convertibleSelection { return .collapse(finalSelection) }
            return .changed
        }
        if originalText == before && (selection == initialCaret || selection == originalRange) { return .waiting }
        return .changed
    }
}

/// A single content write, guarded at both ends. All closures operate on one
/// editor/field captured by the platform adapter, with a shared time budget.
/// A timeout is not evidence that a write failed: no second transport is allowed.
public enum WordReplacement {
    public static func perform(_ plan: WordReplacementPlan, needsSelection: Bool,
                               // Identity/safety only, deliberately independent
                               // of the operation budget used by mayContinue.
                               isCurrent: () -> Bool,
                               selection: () -> NSRange?, read: (NSRange) -> String?,
                               select: (NSRange) -> WordReplacementRequestResult,
                               write: () -> WordReplacementRequestResult,
                               awaitSelection: (NSRange) -> Bool,
                               awaitResult: () -> Bool,
                               mayContinue: () -> Bool = { true },
                               awaitRestoration: ((NSRange) -> Bool)? = nil) -> WordReplacementResult {
        guard mayContinue(), isCurrent(), selection() == plan.initialSelection,
              read(plan.target) == plan.original else { return .refused }

        // Use only before a write, or after a definitively rejected write.
        // Restoring after an uncertain SelectedText write would let that late
        // write insert text at the restored caret instead of replacing its word.
        func restore(observedSelection: Bool, definitivelyRejected: Bool = false) -> WordReplacementResult {
            guard isCurrent() else { return .refused } // Boundary now belongs to another field.
            let current = selection()
            if current == plan.initialSelection && (observedSelection || definitivelyRejected) {
                return .refused
            }
            // Do not overwrite a selection/text change made by the editor or
            // assume a timed-out select cannot arrive after an unchanged read.
            guard current == plan.target, read(plan.target) == plan.original else { return .unsafeSelection }
            guard select(plan.initialSelection) == .accepted else { return .unsafeSelection }
            if let awaitRestoration { _ = awaitRestoration(plan.initialSelection) }
            else { _ = awaitSelection(plan.initialSelection) }
            guard isCurrent() else { return .refused }
            guard selection() == plan.initialSelection, read(plan.target) == plan.original else { return .unsafeSelection }
            return .refused
        }

        if needsSelection {
            let request = select(plan.target)
            guard request != .rejected else { return restore(observedSelection: false, definitivelyRejected: true) }
            let acknowledged = awaitSelection(plan.target)
            let observed = isCurrent() && selection() == plan.target
            guard acknowledged, observed, mayContinue(), read(plan.target) == plan.original else {
                return restore(observedSelection: observed)
            }
        } else {
            guard mayContinue(), isCurrent(), selection() == plan.initialSelection,
                  read(plan.target) == plan.original else { return .refused }
        }
        // Point of no retry, including when an AX request reports a timeout.
        let request = write()
        if request == .rejected {
            return needsSelection ? restore(observedSelection: true) : .refused
        }
        _ = awaitResult()
        guard isCurrent() else { return .unconfirmed }
        // A final matching read is proof even if the wait loop exhausted its
        // budget just before the renderer's acknowledgement arrived.
        if selection() == plan.resultSelection, read(plan.resultRange) == plan.replacement {
            return .confirmed
        }
        // A selection-free range write does not leave a selected word for the
        // physical boundary to erase. A SelectedText write may still be pending;
        // do not move its selection and do not release input into that selection.
        return needsSelection ? .unsafeSelection : .unconfirmed
    }
}
