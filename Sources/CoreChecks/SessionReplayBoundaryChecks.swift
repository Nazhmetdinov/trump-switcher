import SwitcherCore

func sessionReplayBoundaryChecks() -> Int {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), "Session replay boundary: " + message)
        count += 1
    }
    func correction(_ token: String?) -> AutoCorrection? {
        token.flatMap { AutoCorrection.detect($0, recognizes: { _, _ in false }, isAddress: { _ in false }) }
    }

    // Reproduce actual cancellation ordering: the old editor drains, then a
    // session click selects B and its queued first character reaches B. The
    // next physical character adopts B's PID only after queue ownership ends.
    enum Event { case oldBoundary, click, prefix }
    for fallback in [false, true] {
        var queue = OrderedInputCancellation<Event>(originals: [.oldBoundary], awaitingDestination: false)
        expect(queue.enqueueInterrupt(.click) && queue.enqueueInterrupt(.prefix), "session tail captured")
        var tail: [Event]
        if fallback {
            tail = queue.takeOwnedFallback().session
        } else {
            expect(queue.takeDestinationBatch()?.count == 1, "old destination owns its boundary")
            expect(queue.destinationAcknowledged(), "old destination acknowledged before new editor")
            tail = queue.takeSessionBatch()!
        }
        var replay = SessionReplayBoundary()
        var buffer = TypingBuffer()
        var editor = ""
        for event in tail {
            switch event {
            case .click: buffer.reset(); replay.record(.focusNavigation)
            case .prefix: editor += "r"; buffer.reset(startOfWord: false); replay.record(.unknownText)
            case .oldBoundary: preconditionFailure("old input escaped into the new editor")
            }
        }
        if !fallback { expect(queue.sessionAcknowledged(), "session ownership ends once") }
        expect(replay.requiresBoundary, "untracked new-editor prefix survives queue completion")
        buffer.reset(startOfWord: replay.startOfWordOnPIDChange())
        for character in "nj" { editor.append(character); buffer.append(String(character)) }
        let token = buffer.finishWord()
        replay.observeProcessedBuffer(buffer)
        expect(editor == "rnj" && token == nil && correction(token) == nil, "PID adoption never corrects a suffix")
        expect(!replay.requiresBoundary, "real Space resumes complete-word tracking")
        buffer.append("n"); buffer.append("j")
        expect(correction(buffer.finishWord())?.text == "то", "next complete word is still corrected")
    }

    var replay = SessionReplayBoundary()
    var buffer = TypingBuffer()
    replay.record(.unknownText)
    buffer.reset(startOfWord: false)
    replay.observeProcessedBuffer(buffer)
    expect(!replay.startOfWordOnPIDChange(), "blocked prefix survives processed rejected keys")
    replay.record(.unchanged)
    expect(replay.requiresBoundary, "input-source shortcut cannot invent a word boundary")
    for _ in 0..<3 {
        expect(!replay.startOfWordOnPIDChange(), "metadata and repeated PID adoption do not reopen suffixes")
    }
    replay.record(.focusNavigation)
    expect(replay.startOfWordOnPIDChange(), "ordinary or replayed Cmd+Tab releases old-editor provenance")
    buffer.reset(startOfWord: replay.startOfWordOnPIDChange())
    buffer.append("n"); buffer.append("j")
    expect(correction(buffer.finishWord())?.text == "то", "first complete word after later app switch remains eligible")

    // Click/Cmd+Tab before replayed text cannot authorize that later prefix;
    // navigation after that text must not contaminate another app's first word.
    for navigationFirst in [true, false] {
        var state = SessionReplayBoundary()
        state.record(navigationFirst ? .focusNavigation : .unknownText)
        state.record(navigationFirst ? .unknownText : .focusNavigation)
        expect(state.requiresBoundary == navigationFirst, "session event order determines prefix ownership")
    }
    for effect: SessionReplayBoundary.Effect in [.boundary, .focusNavigation] {
        var state = SessionReplayBoundary()
        state.record(.unknownText); state.record(effect)
        expect(state.startOfWordOnPIDChange(), "known reset releases replay provenance")
    }
    var unrelated = TypingBuffer()
    unrelated.reset(startOfWord: false)
    var cleanSession = SessionReplayBoundary()
    cleanSession.observeProcessedBuffer(unrelated)
    expect(cleanSession.startOfWordOnPIDChange(), "ordinary old-editor rejection is not replay provenance")
    replay.record(.unknownText)
    replay = SessionReplayBoundary() // AutoMonitor.stop() starts a new stream.
    expect(replay.startOfWordOnPIDChange(), "restart cannot carry an obsolete replay prefix")
    return count
}
