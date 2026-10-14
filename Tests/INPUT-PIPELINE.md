# Cross-process input validation

The production AutoMonitor is connected through a process event tap to a disposable,
owned InputFixture child. Originals use physical macOS key codes, a private event
source and a nonce accepted only in this explicit test mode. The ordinary application
continues to reject injected/private input. No events are posted globally or to user
applications; no user document or pasteboard is used. Focus loss/foreign input aborts.

Build the fixture with `bash scripts/build-input-fixture.sh`. Launch the installed
application through LaunchServices with `--check-input-pipeline`, then the absolute
fixture executable and report paths. Optional comma-separated mode/case/speed filters
limit a diagnostic run. Ordinary startup never activates this test harness.

## Assertions

- Each original keyDown is processed exactly once by the production filter.
- Ordering regressions compare the editor's entire keyDown/keyUp sequence:
  original word, selection/deletion, replacement, boundary, continuation. Delivery watchdog
  expiry is a failure even when the eventual text happens to look correct.
- Expected corrections really execute; preserved controls execute no correction.
- Text, UTF-16 caret and selection match exactly; Enter/Tab arrive once.
- FIFO completion has a fixed deadline measured from the last original post.
- Before stability snapshots, the runner verifies that the owned editor has received
  every forwarded keyDown/keyUp and finished processing every observed keyDown.
  In spelling-enabled AppKit editors, the internal spelling loop can consume
  several keyDowns and issue one insertText call without dispatching each through
  NSApplication.sendEvent. Only non-ordering spelling cases allow that reduction,
  with exact independent head/tail event counts, every keyUp and exact final text.
  Ordering cases and all other editors retain exact event counts. Transport
  completion alone is insufficient: AppKit can temporarily block inside sendEvent.
  This extra check shares the same fixed deadline; it does not extend the budget.
- Stability snapshots are taken at 100 and 500 ms after that bounded editor drain.
  Transport and editor-delivery latencies are reported separately so the wait cannot
  hide an unresponsive pipeline.
- Plain/rich NSTextView, system spelling enabled/disabled, NSTextField, an opaque
  editor without AX text APIs, and five local WebKit field types are covered.
- Cases include short words, capitalization, punctuation, addresses, alternating
  layouts, a 20-word zero-interval burst, existing Unicode prefixes, Backspace,
  repeated Space, exclusions, Enter/Tab and the production manual-conversion path.
- A separate 24-word mixed-language phrase covers one- to eighteen-letter Russian
  words, punctuation and repeated switches in both directions. Independent
  no-filter controls record native single-line Enter/Tab selection behaviour and
  distinguish editor delivery delay from correction delay.
- Manual access to the opaque field must fail explicitly without altering it.
- Ten selected-phrase manual cases use an explicit UTF-16 selection with an
  emoji prefix and untouched suffix, in both directions across plain/rich AppKit
  and editable WebKit fields. They invoke the production manual API without
  synthesizing any keys and verify the whole result and selected range twice.
- Three additional marker-only WebKit group cases cover a last word after a
  Unicode prefix, trailing whitespace and the opposite layout direction. The
  prefix and whitespace must remain intact, and the caret must be restored.
- Twelve independent controls type the correctly spelled text with filtering
  stopped before Enter/Tab in the three contenteditable modes. Corrected cases
  at both speeds must match that control's exact text, rendered text, focus and
  owned DOM selection. An absent/outside selection is reported explicitly, never
  as a fabricated cursor at zero. The controls account for native Tab navigation
  and rich WebKit's conversion of a final space to NBSP before Enter; corrected
  results are not normalized. These dependencies are included automatically in
  filtered runs of their corresponding cases.
- Verified numeric-range WebKit fixtures must use the selection transport.
  Their ordering cases require Shift+Left on both keyDown and keyUp, without
  extra modifiers; unexpected Delete events fail. The mode expectations are
  independent of the production counter. Marker-only groups, opaque editors
  and native fixtures retain the expected Backspace transport. Web cases without
  Enter must have identical rendered/plain text, and rich-text prefix cases must
  preserve the pre-existing bold prefix.
- A deterministic editor-capitalization mode changes only the first original
  letter, once, inside the editor. It never capitalizes generated replacements;
  both the final text and the single transformation count must match.
- The opaque focus-race case moves between distinct same-geometry groups during
  an unsupported AX marker request. The second field must receive only the
  original boundary, with no deletion or layout correction.

When filtering a run containing single-line `field` Enter/Tab cases, include
`baseline-enter,baseline-tab` in the case filter and use speed `all`. These independent
controls run at paced speed and establish the native field's selection behaviour;
a burst-only filter omits them and cannot validate that selection oracle.

Only deliberate test sequences enter reports. Native fixture events and replacement
metadata are retained only for this opt-in test; ordinary runtime diagnostics retain
counts, lengths and fixed reasons in RAM and never retain user text.

The runner activates once and yields activation to its owned fixture; resets do
not repeatedly activate the application. Each snapshot records the fixture's own
active/key-window flags. The final report classifies focus as fixture, runner,
none or other before cleanup, without recording another application's identity.

The transport fence uses Apple's process-directed event stream, which is distinct
from an acknowledgement of an editor mutation:
https://developer.apple.com/documentation/coregraphics/cgevent
https://developer.apple.com/documentation/coregraphics/cgeventtapplacement/tailappendeventtap

## Limits

Headless checks complement this fixture. `bash scripts/build.sh` runs the physical
key-release ownership regressions and `scripts/check-input-queue-model.swift`.
The latter uses an independent arrival ledger, event IDs, paired-key assertions
and expected text across captured destinations. Its 8,208 deterministic schedules
cover cancellation, delayed acknowledgements, saturation and fallback without
AppKit, AX, input-source changes or posted events. These checks do not exercise
the OS adapter or count as real-application typing evidence. Physical autorepeat
ownership is covered headlessly; native autorepeat integration remains untested.

The fixture performs editor/pipeline integration testing using synthetic process-directed events,
not a physical keyboard/HID test. It does not prove every third-party application or
protected text field is supported. Secure Input, password fields and user exclusions
remain excluded. Cases with differing output while the queue is still processing
are latency observations; a changed result after completion is a stability failure.
The matrix is finite: for example, cancellation after a committed replacement
with the next word still queued is not a separate integration scenario yet.
Neither are manual pointer/caret movements after a committed batch, manual source
switching inside a word, held-key autorepeat or Caps Lock. Initial capitals use Shift.
These are uncovered integration scenarios, not reproduced defects or passing tests.

Historical reports remain unchanged, including failed and aborted runs. A stale
`running` report whose process crashed is not a successful test. Final validation
must identify the exact installed executable and the corresponding completed report.
