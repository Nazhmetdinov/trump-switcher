import AppKit
import Carbon
import SwitcherCore

/// Exercises the production filter against a disposable child application's
/// real editors. Every original event is posted to that exact child's PID; no
/// global event posting, clipboard access, or existing application is involved.
enum InputPipelineChecks {
    private static var retained: Runner?

    static func run(fixtureExecutable: URL, reportURL: URL) -> Never {
        let app = NSApplication.shared
        // Only the isolated test runner becomes a regular app. A nonactive
        // accessory process cannot reliably yield activation to its child.
        app.setActivationPolicy(.regular)
        let runner = Runner(executable: fixtureExecutable, reportURL: reportURL)
        retained = runner
        DispatchQueue.main.async { runner.activateBeforeBeginning() }
        app.run()
        exit(1)
    }

    private struct Sample {
        let name: String
        let source: Layout
        let input: String
        let expected: String
        var boundary: UInt16? = nil
        var corrections = 1
        var excluded = false
        var prefix = ""
        var trailingKeys: [UInt16] = []
        var manual = false
        var focusGuard = false
        var filterEnabled = true
        var trailingText = ""
        // Exact editor-event oracle for a single first-word replacement. It
        // catches a following original key overtaking deletion/insertion even
        // when a later edit happens to restore the final text.
        var orderingWord: String? = nil
        var expectedEditorCapitalizations: Int? = nil
        var manualInitialText: String? = nil
        var manualInitialSelection: NSRange? = nil
        var expectedSelection: NSRange? = nil
        var cancelAfterFirstCommit = false
        var pausesAfterKey: [Int: TimeInterval] = [:]
        var requiresExactCorrectionCount = false
        var processedKeysBeforeCancellation: Int? = nil
        var requiresCapturedCancellationTail = false
        var repeatsFinalSpace = false
    }

    private struct Job {
        let mode: String
        let sample: Sample
        let interval: TimeInterval
        var name: String { "\(mode)/\(interval == 0 ? "burst" : "paced")/\(sample.name)" }
        var expectedManualRefusal: Bool { sample.manual && mode == "opaque" }
        var expected: String { sample.prefix + (expectedManualRefusal ? sample.input : sample.expected) }
        var isFocusRace: Bool { mode.hasPrefix("focus-race") }
        func originalKeyUpCount(keyDownCount: Int) -> Int {
            keyDownCount - (sample.repeatsFinalSpace ? 1 : 0)
        }
        var processedKeyCountBeforeCancellation: Int? {
            sample.cancelAfterFirstCommit ? (sample.processedKeysBeforeCancellation ?? (sample.input.prefix(while: { $0 != " " }).count + 1)) : nil
        }
    }

    private struct WebBoundaryObservation: Equatable {
        let text: String
        let renderedText: String
        let focused: Bool
        let selectionState: String
        let selection: NSRange?

        var json: [String: Any] {
            ["text": text, "renderedText": renderedText, "focused": focused, "selectionState": selectionState,
             "selectionWithinTarget": selection != nil,
             "selection": selection.map { ["location": $0.location, "length": $0.length] } as Any? ?? NSNull()]
        }
    }

    private final class Runner {
        let executable: URL
        let reportURL: URL
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let keyboard = KeyboardLayouts()
        let nonce = Int64.random(in: 1...Int64.max)
        let injector = DispatchQueue(label: "local.trumpswitcher.owned-fixture-input", qos: .userInitiated)
        let previousSource = InputSources.currentID()
        let started = Date()
        var monitor: AutoMonitor?
        var pending: [String: ([String: Any]) -> Void] = [:]
        var data = Data()
        var jobs: [Job] = []
        var index = 0
        var results: [[String: Any]] = []
        var originalEvents: [[String: Any]] = []
        var manualResult: [String: Any]?
        var finished = false
        var ready = false
        var requestNumber = 0
        var deliveryLatencyMS: Double = 0
        var deliveryTimedOut = false
        var targetDeliveryLatencyMS: Double = 0
        var targetDeliveryTimedOut = false
        var targetDeliveryCounts: [String: Int] = [:]
        var deliveryBudgetMS: Double = 0
        var lastPostedAt: TimeInterval = 0
        var nativeBoundaryBaselineSelections: [UInt16: String] = [:]
        var webBoundaryBaselines: [String: (name: String, observation: WebBoundaryObservation)] = [:]
        var orderingExpectedCodes: [Int]?
        var orderingSelectionRange: NSRange?
        var fixtureErrorFlags: [String: Bool] = [:]
        var parentActivationFlags: [String: Bool] = [:]
        var frontmostAtFinish: String?
        var cancellationTrigger: [String: Any]?

        init(executable: URL, reportURL: URL) {
            self.executable = executable
            self.reportURL = reportURL
        }

        func activateBeforeBeginning() {
            save(status: "running")
            let app = NSApplication.shared
            if #available(macOS 14.0, *) { app.activate() }
            else { app.activate(ignoringOtherApps: true) }
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            func check() {
                guard !self.finished else { return }
                let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
                self.parentActivationFlags = ["active": app.isActive, "frontmost": frontmost]
                if app.isActive && frontmost { self.begin(); return }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.finish(error: "Owned test runner did not become active and frontmost within 2 seconds"); return
                }
                // Observe only. Never repeat activation or steal focus again.
                self.after(0.02, check)
            }
            check()
        }

        func begin() {
            save(status: "running")
            guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
                finish(error: "Owned fixture executable is missing"); return
            }
            guard AXIsProcessTrusted() else {
                finish(error: "The launched Trump Switcher process has no Accessibility permission"); return
            }
            process.executableURL = executable
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            // Data handling and all monitor operations remain on the main
            // runloop. The fixture has a separate runloop and can answer AX.
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                DispatchQueue.main.async { self?.receive(bytes) }
            }
            process.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    guard let self, !self.finished else { return }
                    self.finish(error: "Owned fixture exited unexpectedly (\(child.terminationStatus))")
                }
            }
            if #available(macOS 14.0, *) {
                // Cooperatively yield before launching this exact owned app.
                // The identifier is fixed by build-input-fixture.sh; yielding
                // grants permission but neither activates nor deactivates apps.
                NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: "local.trumpswitcher.input-fixture")
            }
            do { try process.run() }
            catch { finish(error: "Could not launch owned fixture: \(error.localizedDescription)"); return }
            after(15) { [weak self] in
                guard let self, !self.ready, !self.finished else { return }
                self.finish(error: "Owned fixture did not report ready")
            }
        }

        func receive(_ bytes: Data) {
            guard !finished else { return }
            guard !bytes.isEmpty else { return }
            data.append(bytes)
            guard data.count <= 2_000_000 else { finish(error: "Fixture response exceeded its bound"); return }
            while let newline = data.firstIndex(of: 10) {
                let line = data[..<newline]
                data.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                    finish(error: "Fixture returned invalid JSON"); return
                }
                guard (object["pid"] as? Int32) == process.processIdentifier else {
                    finish(error: "Fixture response PID did not match the owned child"); return
                }
                // Startup reset has no request id. Handle its error before
                // matching callbacks, retaining only fixed diagnostic fields.
                if object["event"] as? String == "error" {
                    for key in ["frontmost", "active", "keyWindow", "parentVerified", "activationAllowed"] {
                        if let value = object[key] as? Bool { fixtureErrorFlags[key] = value }
                    }
                    let knownReasons: Set<String> = [
                        "Owned fixture did not become frontmost with a key window within 2 seconds",
                        "Reset superseded while awaiting activation", "Focus race requires a pair of owned fields",
                        "Invalid mode, text, or UTF-16 selection", "Reset superseded", "Web reset not ready",
                        "Snapshot superseded", "Missing web result", "Unknown command", "Expected a JSON object"
                    ]
                    let reason = object["error"] as? String ?? ""
                    finish(error: "Fixture error: \(knownReasons.contains(reason) ? reason : "unspecified owned-fixture failure")")
                    return
                }
                if object["event"] as? String == "ready", !ready {
                    ready = true
                    prepareJobs(modes: object["modes"] as? [String] ?? [])
                    next()
                } else if let id = object["id"] as? String, let callback = pending.removeValue(forKey: id) {
                    callback(object)
                }
            }
        }

        func prepareJobs(modes: [String]) {
            var samples = [
                Sample(name: "for-lower", source: .english, input: "lkz ", expected: "для "),
                Sample(name: "for-title", source: .english, input: "Lkz ", expected: "Для "),
                Sample(name: "their-lower", source: .english, input: "b[ ", expected: "их "),
                Sample(name: "their-title", source: .english, input: "B[ ", expected: "Их "),
                Sample(name: "comma-inside", source: .english, input: "hf,jnftn ", expected: "работает "),
                Sample(name: "english-to-russian", source: .english, input: "ghbdtn ", expected: "привет "),
                Sample(name: "russian-to-english", source: .russian, input: "руддщ ", expected: "hello "),
                Sample(name: "exclamation", source: .english, input: "ghbdtn!", expected: "привет!"),
                Sample(name: "trailing-period", source: .english, input: "ghbdtn. ", expected: "привет. "),
                Sample(name: "ellipsis-three", source: .english,
                       input: "123 fdnjgthtrk.xtybt... ", expected: "123 автопереключение... ", requiresExactCorrectionCount: true),
                Sample(name: "ellipsis-five-next-word", source: .english,
                       input: "rjytxyj..... hello ", expected: "конечно..... hello ", corrections: 2, requiresExactCorrectionCount: true),
                Sample(name: "ellipsis-four-pause-next-word", source: .english,
                       input: "ghbdtn.... hello ", expected: "привет.... hello ", corrections: 2,
                       pausesAfterKey: [9: 0.250], requiresExactCorrectionCount: true),
                Sample(name: "domain", source: .russian, input: "нфтвучюкг ", expected: "yandex.ru "),
                Sample(name: "following-russian-words", source: .english, input: "lkz b[ ghbdtn ", expected: "для их привет ", orderingWord: "для"),
                Sample(name: "following-english-word", source: .russian, input: "руддщ цщкдв ", expected: "hello world "),
                Sample(name: "cancel-ellipsis-captured-tail", source: .english, input: "ghbdtn....", expected: "привет....",
                       cancelAfterFirstCommit: true, requiresExactCorrectionCount: true,
                       processedKeysBeforeCancellation: 9, requiresCapturedCancellationTail: true),
                Sample(name: "cancel-after-commit-ru", source: .english, input: "lkz f ", expected: "для а ",
                       orderingWord: "для", cancelAfterFirstCommit: true),
                Sample(name: "cancel-after-commit-en", source: .russian, input: "руддщ ц ", expected: "hello w ",
                       orderingWord: "hello", cancelAfterFirstCommit: true),
                Sample(name: "alternating-layouts", source: .english, input: "ghbdtn hello ghbdtn hello ",
                       expected: "привет hello привет hello ", corrections: 4),
                Sample(name: "alternating-layouts-long", source: .english,
                       input: String(repeating: "ghbdtn hello ", count: 10),
                       expected: String(repeating: "привет hello ", count: 10), corrections: 20),
                Sample(name: "enter", source: .english, input: "ghbdtn", expected: "привет", boundary: UInt16(kVK_Return), orderingWord: "привет"),
                Sample(name: "tab", source: .english, input: "ghbdtn", expected: "привет", boundary: UInt16(kVK_Tab), orderingWord: "привет"),
                Sample(name: "valid-english", source: .english, input: "hello ", expected: "hello ", corrections: 0),
                Sample(name: "valid-russian", source: .russian, input: "привет ", expected: "привет ", corrections: 0),
                Sample(name: "exclude-current-app", source: .english, input: " ghbdtn ", expected: " ghbdtn ", corrections: 0, excluded: true),
                Sample(name: "existing-ascii-prefix", source: .english, input: "lkz ", expected: "для ", prefix: "prefix: "),
                Sample(name: "existing-emoji-prefix", source: .english, input: "lkz ", expected: "для ", prefix: "🙂 "),
                Sample(name: "backspace-after-correction", source: .english, input: "lkz ", expected: "для", trailingKeys: [UInt16(kVK_Delete)], orderingWord: "для"),
                Sample(name: "space-repeat", source: .english, input: "lkz  ", expected: "для  ", orderingWord: "для"),
                Sample(name: "autorepeat-space-baseline", source: .english, input: "lkz ", expected: "lkz  ",
                       corrections: 0, filterEnabled: false, repeatsFinalSpace: true),
                Sample(name: "autorepeat-space-correction", source: .english, input: "lkz ", expected: "для  ",
                       orderingWord: "для", requiresExactCorrectionCount: true, repeatsFinalSpace: true),
                Sample(name: "ordering-delete-and-type", source: .english, input: "lkz ", expected: "для ",
                       trailingKeys: [UInt16(kVK_Delete), UInt16(kVK_Delete)], trailingText: "z ", orderingWord: "для"),
                Sample(name: "ordering-enter-after-space", source: .english, input: "lkz ", expected: "для ",
                       boundary: UInt16(kVK_Return), orderingWord: "для"),
                Sample(name: "ordering-tab-after-space", source: .english, input: "lkz ", expected: "для ",
                       boundary: UInt16(kVK_Tab), orderingWord: "для"),
                Sample(name: "manual-for", source: .english, input: "lkz", expected: "для", corrections: 0, manual: true),
                Sample(name: "manual-their", source: .english, input: "b[", expected: "их", corrections: 0, manual: true),
                Sample(name: "yandex", source: .english, input: "Zyltrc ", expected: "Яндекс "),
                Sample(name: "valid-yandex", source: .russian, input: "Яндекс ", expected: "Яндекс ", corrections: 0)
            ]
            let diversePhrase = "и hello в world для! hello их world Яндекс hello работает world такие hello спасибо! world пожалуйста hello клавиатура world переключение hello производительность world "
            guard let russianID = InputSources.sourceID(for: .russian), let russian = keyboard.table(russianID),
                  let englishID = InputSources.sourceID(for: .english), let english = keyboard.table(englishID) else {
                finish(error: "Native input tables are unavailable for the diverse phrase fixture"); return
            }
            // Expected phrase is a manually reviewed oracle. Only its physical
            // wrong-layout encoding comes from the native keyboard map.
            samples.append(Sample(name: "diverse-phrase", source: .english,
                input: russian.convert(diversePhrase, to: english), expected: diversePhrase, corrections: 24))
            // Environment filters are only a developer convenience for a failed
            // case rerun; the default matrix includes every fixture editor.
            let env = ProcessInfo.processInfo.environment
            let args = CommandLine.arguments
            func filter(_ position: Int, _ environment: String) -> [String]? {
                let value = args.indices.contains(position) ? args[position] : env[environment]
                guard let value, !value.isEmpty, value != "all" else { return nil }
                return value.split(separator: ",").map(String.init)
            }
            let selectedModes = filter(4, "TRUMP_SWITCHER_PIPELINE_MODES")
            let selectedCases = filter(5, "TRUMP_SWITCHER_PIPELINE_CASES")
            let selectedSpeeds = filter(6, "TRUMP_SWITCHER_PIPELINE_SPEEDS")
            let controls: [Job] = [
                Job(mode: "field", sample: Sample(name: "baseline-enter", source: .russian, input: "привет", expected: "привет",
                    boundary: UInt16(kVK_Return), corrections: 0, filterEnabled: false), interval: 0.022),
                Job(mode: "field", sample: Sample(name: "baseline-tab", source: .russian, input: "привет", expected: "привет",
                    boundary: UInt16(kVK_Tab), corrections: 0, filterEnabled: false), interval: 0.022),
                Job(mode: "field", sample: Sample(name: "baseline-valid-russian", source: .russian, input: "привет ", expected: "привет ",
                    corrections: 0, filterEnabled: false), interval: 0),
                Job(mode: "plain", sample: Sample(name: "baseline-valid-russian", source: .russian, input: "привет ", expected: "привет ",
                    corrections: 0, filterEnabled: false), interval: 0)
            ]
            for control in controls {
                let speed = control.interval == 0 ? "burst" : "paced"
                let explicitControl = (selectedCases == nil || selectedCases!.contains(control.sample.name)) &&
                    (selectedSpeeds == nil || selectedSpeeds!.contains(speed))
                // NSTextField may select its entire value on Enter/Tab. The
                // correction oracle must observe that native behavior even
                // when a targeted rerun requests only burst correction cases.
                let correctionSpeed = selectedSpeeds == nil || selectedSpeeds!.contains(where: { ["paced", "burst"].contains($0) })
                let requiredNativeControl = control.mode == "field" && control.sample.boundary != nil && correctionSpeed &&
                    samples.contains { sample in
                        sample.boundary == control.sample.boundary &&
                            (selectedCases == nil || selectedCases!.contains(sample.name))
                    }
                guard selectedModes == nil || selectedModes!.contains(control.mode),
                      explicitControl || requiredNativeControl else { continue }
                jobs.append(control)
            }
            // Browser Tab changes DOM focus; Enter can preserve a trailing
            // space as NBSP. Observe those native behaviors with the filter
            // stopped, using the exact same correctly typed text and boundary.
            // Both input speeds must match this stable editor-specific result.
            let webBoundaryControls: [(name: String, sample: Sample)] = [
                ("enter", Sample(name: "baseline-web-enter", source: .russian, input: "привет", expected: "привет",
                    boundary: UInt16(kVK_Return), corrections: 0, filterEnabled: false)),
                ("tab", Sample(name: "baseline-web-tab", source: .russian, input: "привет", expected: "привет",
                    boundary: UInt16(kVK_Tab), corrections: 0, filterEnabled: false)),
                ("ordering-enter-after-space", Sample(name: "baseline-web-enter-after-space", source: .russian, input: "для ", expected: "для ",
                    boundary: UInt16(kVK_Return), corrections: 0, filterEnabled: false)),
                ("ordering-tab-after-space", Sample(name: "baseline-web-tab-after-space", source: .russian, input: "для ", expected: "для ",
                    boundary: UInt16(kVK_Tab), corrections: 0, filterEnabled: false))
            ]
            for mode in ["web-contenteditable", "web-group", "web-rich"]
                where modes.contains(mode) && (selectedModes == nil || selectedModes!.contains(mode)) {
                for control in webBoundaryControls {
                    let wantedCorrection = selectedCases == nil || selectedCases!.contains(control.name)
                    let wantedBaseline = selectedCases == nil || selectedCases!.contains(control.sample.name)
                    let correctionSpeed = selectedSpeeds == nil || selectedSpeeds!.contains(where: { ["paced", "burst"].contains($0) })
                    let baselineSpeed = selectedSpeeds == nil || selectedSpeeds!.contains("paced")
                    guard (wantedCorrection && correctionSpeed) || (wantedBaseline && baselineSpeed) else { continue }
                    // A selected burst correction still needs its paced control;
                    // do not silently omit the dependency because of a filter.
                    jobs.append(Job(mode: mode, sample: control.sample, interval: 0.022))
                }
            }
            for mode in modes where selectedModes == nil || selectedModes!.contains(mode) {
                for interval in [0.022, 0.0] {
                    let speed = interval == 0 ? "burst" : "paced"
                    guard selectedSpeeds == nil || selectedSpeeds!.contains(speed) else { continue }
                    for sample in samples where selectedCases == nil || selectedCases!.contains(sample.name) {
                        if sample.cancelAfterFirstCommit && interval != 0 { continue }
                        if sample.repeatsFinalSpace && (interval != 0 || !["plain", "opaque", "web-contenteditable"].contains(mode)) { continue }
                        jobs.append(Job(mode: mode, sample: sample, interval: interval))
                    }
                }
            }
            // The editor mutates the initial physical lowercase keystroke to
            // uppercase once. Expected output is explicit, not adjusted from
            // the observed editor value. Generated replacement is untouched.
            if selectedModes == nil || selectedModes!.contains("editor-capitalization") {
                let capitalizationSamples = [
                    Sample(name: "capitalization-baseline-en", source: .english, input: "ghbdtn ", expected: "Ghbdtn ",
                        corrections: 0, filterEnabled: false, expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-baseline-ru", source: .russian, input: "руддщ ", expected: "Руддщ ",
                        corrections: 0, filterEnabled: false, expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-to-russian", source: .english, input: "ghbdtn ", expected: "Привет ", expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-to-english", source: .russian, input: "руддщ ", expected: "Hello ", expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-for", source: .english, input: "lkz ", expected: "Для ", expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-their", source: .english, input: "b[ ", expected: "Их ", expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-and", source: .english, input: "b ", expected: "И ", expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-in", source: .english, input: "d ", expected: "В ", expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-valid-english", source: .english, input: "hello ", expected: "Hello ",
                        corrections: 0, expectedEditorCapitalizations: 1),
                    Sample(name: "capitalization-valid-russian", source: .russian, input: "привет ", expected: "Привет ",
                        corrections: 0, expectedEditorCapitalizations: 1)
                ]
                for interval in [0.022, 0.0] {
                    let speed = interval == 0 ? "burst" : "paced"
                    guard selectedSpeeds == nil || selectedSpeeds!.contains(speed) else { continue }
                    for sample in capitalizationSamples where selectedCases == nil || selectedCases!.contains(sample.name) {
                        jobs.append(Job(mode: "editor-capitalization", sample: sample, interval: interval))
                    }
                }
            }
            // Four independent safety cases, in addition to the editor matrix.
            // The fixture changes its own focus during the final AX range read;
            // production preflight and AutoMonitor receive no test bypass.
            for mode in ["focus-race", "focus-race-protected"] where selectedModes == nil || selectedModes!.contains(mode) {
                let cases = [
                    Sample(name: "stale-context-guard", source: .english, input: "", expected: "", corrections: 0, prefix: "lkz", focusGuard: true),
                    Sample(name: "stale-context-pipeline", source: .english, input: "lkz ", expected: "lkz", corrections: 0)
                ]
                for sample in cases where selectedCases == nil || selectedCases!.contains(sample.name) {
                    guard selectedSpeeds == nil || selectedSpeeds!.contains("burst") else { continue }
                    jobs.append(Job(mode: mode, sample: sample, interval: 0))
                }
            }
            if (selectedModes == nil || selectedModes!.contains("focus-race-opaque")),
               (selectedCases == nil || selectedCases!.contains("stale-opaque-context-pipeline")),
               (selectedSpeeds == nil || selectedSpeeds!.contains("burst")) {
                jobs.append(Job(mode: "focus-race-opaque",
                    sample: Sample(name: "stale-opaque-context-pipeline", source: .english,
                                   input: "lkz ", expected: "lkz", corrections: 0), interval: 0))
            }
            // Explicit selected-phrase conversion exercises the direct manual
            // transport, independently of the caret/marker word path. No key
            // events are generated: reset supplies the known text/selection.
            for mode in ["plain", "rich", "web-contenteditable", "web-rich", "web-group"]
                where selectedModes == nil || selectedModes!.contains(mode) {
                guard selectedSpeeds == nil || selectedSpeeds!.contains("burst") else { continue }
                let cases = [
                    Sample(name: "manual-selection-to-russian", source: .english, input: "",
                           expected: "🙂 привет мир / end", corrections: 0, manual: true, filterEnabled: false,
                           manualInitialText: "🙂 ghbdtn vbh / end", manualInitialSelection: NSRange(location: 3, length: 10),
                           expectedSelection: NSRange(location: 3, length: 10)),
                    Sample(name: "manual-selection-to-english", source: .russian, input: "",
                           expected: "🙂 hello world / end", corrections: 0, manual: true, filterEnabled: false,
                           manualInitialText: "🙂 руддщ цщкдв / end", manualInitialSelection: NSRange(location: 3, length: 11),
                           expectedSelection: NSRange(location: 3, length: 11))
                ]
                for sample in cases where selectedCases == nil || selectedCases!.contains(sample.name) {
                    jobs.append(Job(mode: mode, sample: sample, interval: 0))
                }
            }
            // Marker-only editable groups expose a caret/word transport. Test
            // offsets after a surrogate pair and preservation of trailing
            // separators without enabling automatic correction first.
            if (selectedModes == nil || selectedModes!.contains("web-group")),
               (selectedSpeeds == nil || selectedSpeeds!.contains("burst")) {
                let cases = [
                    Sample(name: "manual-group-prefix", source: .english, input: "lkz", expected: "для",
                           corrections: 0, prefix: "🙂 before: ", manual: true, filterEnabled: false),
                    Sample(name: "manual-group-trailing", source: .english, input: "lkz  ", expected: "для  ",
                           corrections: 0, prefix: "🙂 before: ", manual: true, filterEnabled: false),
                    Sample(name: "manual-group-russian-prefix", source: .russian, input: "руддщ", expected: "hello",
                           corrections: 0, prefix: "🙂 before: ", manual: true, filterEnabled: false)
                ]
                for sample in cases where selectedCases == nil || selectedCases!.contains(sample.name) {
                    jobs.append(Job(mode: "web-group", sample: sample, interval: 0))
                }
            }
            guard !jobs.isEmpty else {
                finish(error: "No fixture cases matched the requested mode/case/speed filters; zero cases cannot pass")
                return
            }
        }

        func next() {
            guard !finished else { return }
            guard index < jobs.count else {
                finish(error: jobs.isEmpty ? "No matching fixture cases" : nil); return
            }
            guard ownsFrontmostFixture() else { finish(error: "Focus left the owned fixture; no further input was posted"); return }
            monitor?.stop(); monitor = nil
            manualResult = nil
            cancellationTrigger = nil
            lastPostedAt = 0; originalEvents = []
            orderingExpectedCodes = nil
            orderingSelectionRange = nil
            let job = jobs[index]
            var resetCommand: [String: Any] = ["command": "reset", "mode": job.mode,
                                               "text": job.sample.manualInitialText ?? job.sample.prefix]
            if let range = job.sample.manualInitialSelection {
                resetCommand["selection"] = ["location": range.location, "length": range.length]
            }
            request(resetCommand) { [weak self] reset in
                guard let self, !self.finished else { return }
                guard reset["frontmost"] as? Bool == true, self.ownsFrontmostFixture() else {
                    self.finish(error: "The owned fixture could not retain focus"); return
                }
                guard InputSources.select(job.sample.source),
                      let sourceID = InputSources.currentID(), InputSources.layout(forID: sourceID) == job.sample.source,
                      let table = self.keyboard.table(sourceID) else {
                    self.finish(error: "Required input source is not available"); return
                }
                if job.sample.focusGuard { self.runFocusGuard(job); return }
                var keys: [ReplacementKey] = []
                for char in job.sample.input {
                    guard let key = table.replacement(String(char)) else {
                        self.finish(error: "Fixture input has no physical key: \(char)"); return
                    }
                    keys.append(key)
                }
                if let boundary = job.sample.boundary { keys.append(ReplacementKey(code: boundary, shift: false, text: "")) }
                keys.append(contentsOf: job.sample.trailingKeys.map { ReplacementKey(code: $0, shift: false, text: "") })
                for char in job.sample.trailingText {
                    guard let key = table.replacement(String(char)) else {
                        self.finish(error: "Trailing fixture input has no physical key: \(char)"); return
                    }
                    keys.append(key)
                }
                if let word = job.sample.orderingWord {
                    let target: Layout = job.sample.source == .english ? .russian : .english
                    guard let targetID = InputSources.sourceID(for: target), let targetTable = self.keyboard.table(targetID) else {
                        self.finish(error: "Ordering fixture has no native target table"); return
                    }
                    let targetKeys = word.map { targetTable.replacement(String($0)) }
                    guard targetKeys.allSatisfy({ $0 != nil }), keys.count > word.count else {
                        self.finish(error: "Ordering fixture could not encode its independent replacement oracle"); return
                    }
                    let selectsWord = self.expectsSelectionReplacement(in: job.mode)
                    self.orderingExpectedCodes = keys.prefix(word.count).map { Int($0.code) } +
                        Array(repeating: Int(selectsWord ? kVK_LeftArrow : kVK_Delete), count: word.utf16.count) +
                        targetKeys.compactMap { $0.map { Int($0.code) } } +
                        keys.dropFirst(word.count).map { Int($0.code) } +
                        (job.sample.repeatsFinalSpace ? [Int(kVK_Space)] : [])
                    if selectsWord {
                        self.orderingSelectionRange = NSRange(location: word.count, length: word.utf16.count)
                    }
                }
                if job.sample.requiresCapturedCancellationTail {
                    // Independent exact sequence: eight original key pairs
                    // (word + two dots), replacement of those eight characters
                    // by привет..., then the one already-captured literal dot.
                    guard let targetID = InputSources.sourceID(for: .russian),
                          let targetTable = self.keyboard.table(targetID), keys.count == 10 else {
                        self.finish(error: "Captured ellipsis cancellation fixture has no exact physical oracle"); return
                    }
                    let replacement = "привет...".map { targetTable.replacement(String($0)) }
                    guard replacement.allSatisfy({ $0 != nil }), let dot = targetTable.replacement(".") else {
                        self.finish(error: "Captured ellipsis cancellation oracle cannot encode its literal dots"); return
                    }
                    let selectsWord = self.expectsSelectionReplacement(in: job.mode)
                    self.orderingExpectedCodes = keys.prefix(8).map { Int($0.code) } +
                        Array(repeating: Int(selectsWord ? kVK_LeftArrow : kVK_Delete), count: 8) +
                        replacement.compactMap { $0.map { Int($0.code) } } + [Int(dot.code)]
                    if selectsWord { self.orderingSelectionRange = NSRange(location: 8, length: 8) }
                }
                let filter = AutoMonitor(fixture: InputPipelineTarget(process: self.process, nonce: self.nonce))
                self.monitor = filter
                if job.sample.filterEnabled, !filter.start() {
                    self.finish(error: "Process event tap failed: \(filter.lastError)"); return
                }
                if job.sample.cancelAfterFirstCommit {
                    filter.onResult = { [weak self, weak filter] _ in
                        guard let self, let filter, !self.finished, self.monitor === filter,
                              self.cancellationTrigger == nil, filter.automaticCorrections >= 1 else { return }
                        self.cancellationTrigger = ["automaticCorrections": filter.automaticCorrections,
                            "receivedKeys": filter.receivedKeys, "hasPendingInput": filter.hasPendingInput,
                            "orderedCancellationsBefore": filter.orderedCancellations]
                        if job.sample.requiresCapturedCancellationTail {
                            let originals = filter.inputTrace.filter { event in
                                event["step"] as? String == "tap" &&
                                    event["type"] as? UInt32 == CGEventType.keyDown.rawValue &&
                                    event["tag"] as? Int64 == self.nonce
                            }
                            let tail = Array(originals.dropFirst(job.processedKeyCountBeforeCancellation ?? 0))
                            self.cancellationTrigger?["capturedTailKeyDowns"] = tail.count
                            self.cancellationTrigger?["capturedTailWasPendingDot"] = tail.count == 1 && tail.allSatisfy { event in
                                event["code"] as? Int64 == Int64(kVK_ANSI_Period) &&
                                    ((event["pending"] as? UInt64 ?? 0) != 0 || (event["delivery"] as? UInt64 ?? 0) != 0)
                            }
                        }
                        // This callback runs after posting the first committed
                        // replacement. The queued originals must retain order
                        // and the captured layout without another correction.
                        filter.cancel()
                    }
                }
                self.after(0.08) { [weak self] in
                    guard let self else { return }
                    let startInput: () -> Void = { [weak self] in
                        self?.inject(keys, interval: job.interval, pausesAfterKey: job.sample.pausesAfterKey,
                                     repeatFinalSpace: job.sample.repeatsFinalSpace) { [weak self] in
                            self?.inputFinished(job, sourceID: sourceID, keyCount: keys.count + (job.sample.repeatsFinalSpace ? 1 : 0))
                        }
                    }
                    if job.sample.excluded {
                        // Change policy after this exact PID has already become
                        // eligible, then let the usual context poll run.
                        filter.settings.excludedApps = ["local.trumpswitcher.input-fixture"]
                        self.after(0.32, startInput)
                    } else if job.mode == "focus-race-opaque" {
                        self.startOpaqueRace(job, keys: keys, sourceID: sourceID)
                    } else if job.isFocusRace {
                        self.request(["command": "arm-focus-race"]) { _ in startInput() }
                    } else { startInput() }
                }
            }
        }

        func ownsFrontmostFixture() -> Bool {
            process.isRunning && process.processIdentifier > 0 &&
                NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
        }

        func startOpaqueRace(_ job: Job, keys: [ReplacementKey], sourceID: String) {
            guard keys.count == 4, keys.last?.code == UInt16(kVK_Space) else {
                finish(error: "Opaque race requires the independent lkz + Space sequence"); return
            }
            // A genuinely opaque editor can finish receiving its original word
            // after preflight. This safety regression isolates final identity:
            // complete the physical prefix before arming the A→B AX read hook.
            inject(Array(keys.dropLast()), interval: 0) { [weak self] in
                guard let self else { return }
                let prefixEvents = self.originalEvents
                let deadline = self.lastPostedAt + 1.2
                func awaitPrefix() {
                    guard !self.finished, self.ownsFrontmostFixture() else {
                        self.finish(error: "Owned fixture lost focus while staging the opaque race"); return
                    }
                    self.request(["command": "snapshot"]) { snapshot in
                        guard self.hasOnlyOwnedInput(snapshot) else {
                            self.finish(error: "Foreign input reached the opaque race fixture"); return
                        }
                        let counts = snapshot["counts"] as? [String: Any] ?? [:]
                        let ready = snapshot["text"] as? String == "lkz" && snapshot["activeField"] as? String == "A" &&
                            counts["keyDown"] as? Int == 3 && counts["keyDownCompleted"] as? Int == 3 && counts["keyUp"] as? Int == 3 &&
                            self.monitor?.receivedKeys == 3 && self.monitor?.hasPendingInput == false
                        guard ready else {
                            guard ProcessInfo.processInfo.systemUptime < deadline else {
                                self.finish(error: "Owned opaque fixture did not complete its exact original prefix within 1.2 seconds"); return
                            }
                            self.after(0.008, awaitPrefix)
                            return
                        }
                        self.request(["command": "arm-focus-race"]) { _ in
                            self.inject(Array(keys.suffix(1)), interval: 0) {
                                self.originalEvents = prefixEvents + self.originalEvents
                                self.inputFinished(job, sourceID: sourceID, keyCount: keys.count)
                            }
                        }
                    }
                }
                awaitPrefix()
            }
        }

        func inject(_ keys: [ReplacementKey], interval: TimeInterval, pausesAfterKey: [Int: TimeInterval] = [:],
                    repeatFinalSpace: Bool = false, completion: @escaping () -> Void) {
            guard let plan = InputPipelineEventPlan.make(codes: keys.map(\.code), repeatFinalSpace: repeatFinalSpace) else {
                finish(error: "Autorepeat fixture requires the exact reviewed l/k/z/Space plan"); return
            }
            // Carbon/TIS is confined to the main thread. Concurrent TIS reads
            // from the injector can corrupt HIToolbox's mutable source list.
            let sourceIDs = [InputSources.sourceID(for: .english), InputSources.sourceID(for: .russian)].compactMap { $0 }
            let tables = sourceIDs.compactMap { keyboard.table($0) }
            injector.async { [weak self] in
                guard let self else { return }
                guard let source = CGEventSource(stateID: .privateState) else {
                    DispatchQueue.main.async { self.finish(error: "Could not create the private fixture event source") }; return
                }
                var originalEvents: [[String: Any]] = []
                var lastPostedAt = ProcessInfo.processInfo.systemUptime
                let modifierMask: CGEventFlags = [.maskShift, .maskAlternate, .maskAlphaShift]
                func setModifiers(_ desired: CGEventFlags) -> Bool {
                    let modifiers: [(UInt16, CGEventFlags)] = [(UInt16(kVK_Shift), .maskShift),
                        (UInt16(kVK_Option), .maskAlternate), (UInt16(kVK_CapsLock), .maskAlphaShift)]
                    for (code, bit) in modifiers {
                        let current = CGEventSource.flagsState(source.sourceStateID).intersection(modifierMask)
                        guard current.contains(bit) != desired.contains(bit) else { continue }
                        guard self.ownsFrontmostFixture(),
                              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: desired.contains(bit)) else {
                            DispatchQueue.main.async { self.finish(error: "Owned fixture lost focus before its modifier event") }; return false
                        }
                        var next = current
                        if desired.contains(bit) { next.insert(bit) } else { next.remove(bit) }
                        event.type = .flagsChanged
                        event.flags = next
                        event.timestamp = DispatchTime.now().uptimeNanoseconds
                        event.setIntegerValueField(.eventSourceUserData, value: self.nonce)
                        guard self.ownsFrontmostFixture() else {
                            DispatchQueue.main.async { self.finish(error: "Owned fixture lost focus before a directed modifier post") }; return false
                        }
                        event.postToPid(self.process.processIdentifier)
                        lastPostedAt = ProcessInfo.processInfo.systemUptime
                        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
                        while CGEventSource.flagsState(source.sourceStateID).intersection(modifierMask) != next {
                            guard self.ownsFrontmostFixture(), ProcessInfo.processInfo.systemUptime < deadline else {
                                DispatchQueue.main.async { self.finish(error: "Process-directed events did not update the private modifier state; fixture input would be malformed") }; return false
                            }
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                    }
                    return true
                }
                for (keyIndex, key) in keys.enumerated() {
                    guard self.ownsFrontmostFixture() else {
                        DispatchQueue.main.async { self.finish(error: "Focus left the owned fixture during input; injection stopped") }; return
                    }
                    var flags: CGEventFlags = []
                    if key.shift { flags.insert(.maskShift) }
                    if key.option { flags.insert(.maskAlternate) }
                    if key.capsLock { flags.insert(.maskAlphaShift) }
                    // The constructor reads this source's accumulated modifier
                    // state. Merely setting event.flags afterwards leaves an
                    // incorrect unshifted Unicode payload in the original event.
                    guard setModifiers(flags) else { return }
                    var group: [CGEvent] = []
                    for specification in plan.groups[keyIndex] {
                        let down = specification.down
                        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down) else {
                            DispatchQueue.main.async { self.finish(error: "Could not create a fixture keyboard event") }; return
                        }
                        event.flags = flags
                        event.timestamp = DispatchTime.now().uptimeNanoseconds
                        event.setIntegerValueField(.eventSourceUserData, value: self.nonce)
                        event.setIntegerValueField(.keyboardEventAutorepeat, value: specification.autorepeat)
                        if down {
                            var units = [UniChar](repeating: 0, count: 8), length = 0
                            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                            let unicode = String(utf16CodeUnits: units, count: min(length, units.count))
                            let physicalCharacters = Set(tables.compactMap { table in
                                table.character(code: key.code, shift: key.shift, capsLock: key.capsLock, option: key.option)
                            })
                            if let text = key.text, !text.isEmpty, !physicalCharacters.isEmpty,
                               !physicalCharacters.contains(unicode) {
                                DispatchQueue.main.async {
                                    self.finish(error: "Malformed original fixture event at key \(key.code): Unicode \(unicode.debugDescription), expected \(physicalCharacters.sorted()), sources \(sourceIDs)")
                                }
                                return
                            }
                            originalEvents.append(["code": Int(key.code), "flags": event.flags.rawValue,
                                "autorepeat": Int(specification.autorepeat),
                                "declaredText": key.text ?? "", "unicode": unicode,
                                "inputSourceCandidates": sourceIDs, "timestampNS": event.timestamp])
                        }
                        // Repeat groups are prepared completely before posting,
                        // so construction/validation cannot split their release.
                        if repeatFinalSpace { group.append(event); continue }
                        guard self.ownsFrontmostFixture() else {
                            DispatchQueue.main.async { self.finish(error: "Focus changed before a directed event") }; return
                        }
                        event.postToPid(self.process.processIdentifier)
                        lastPostedAt = ProcessInfo.processInfo.systemUptime
                    }
                    if repeatFinalSpace {
                        guard self.ownsFrontmostFixture() else {
                            DispatchQueue.main.async { self.finish(error: "Focus changed before an owned autorepeat group") }; return
                        }
                        // No AX, allocation, timer or yield between down/repeat/up.
                        // Every event remains directed to the one owned child.
                        for event in group { event.postToPid(self.process.processIdentifier) }
                        lastPostedAt = ProcessInfo.processInfo.systemUptime
                    }
                    guard setModifiers([]) else { return }
                    let scheduledPause = pausesAfterKey[keyIndex + 1] ?? 0
                    let pause = max(interval, scheduledPause)
                    if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                }
                DispatchQueue.main.async {
                    self.originalEvents = originalEvents
                    self.lastPostedAt = lastPostedAt
                    completion()
                }
            }
        }

        func inputFinished(_ job: Job, sourceID: String, keyCount: Int) {
            guard job.sample.manual else { check(job, sourceID: sourceID, keyCount: keyCount); return }
            after(0.1) { [weak self] in
                guard let self, !self.finished else { return }
                self.waitForManualInput(job, sourceID: sourceID, keyCount: keyCount,
                                        deadline: ProcessInfo.processInfo.systemUptime + 1)
            }
        }

        func waitForManualInput(_ job: Job, sourceID: String, keyCount: Int, deadline: TimeInterval) {
            guard !finished else { return }
            guard ownsFrontmostFixture() else { finish(error: "Owned fixture lost focus before the manual check"); return }
            request(["command": "snapshot"]) { [weak self] snapshot in
                guard let self, !self.finished else { return }
                guard self.hasOnlyOwnedInput(snapshot) else {
                    self.finish(error: "Input outside the owned test sequence reached the fixture; current text was not saved"); return
                }
                let expectedInput = job.sample.manualInitialText ?? (job.sample.prefix + job.sample.input)
                let expectedSelection = job.sample.manualInitialSelection ?? NSRange(location: expectedInput.utf16.count, length: 0)
                let selection = snapshot["selection"] as? [String: Int] ?? [:]
                let delivered = snapshot["text"] as? String == expectedInput && selection["length"] == expectedSelection.length &&
                    selection["location"] == expectedSelection.location
                guard delivered else {
                    if ProcessInfo.processInfo.systemUptime < deadline {
                        self.after(0.02) { [weak self] in self?.waitForManualInput(job, sourceID: sourceID, keyCount: keyCount, deadline: deadline) }
                    } else {
                        self.manualResult = ["attempted": false, "succeeded": false,
                            "error": "Fixture did not finish delivering the planned input before the manual API check",
                            "expectedRefusal": job.expectedManualRefusal]
                        self.check(job, sourceID: sourceID, keyCount: keyCount)
                    }
                    return
                }
                guard self.ownsFrontmostFixture() else { self.finish(error: "Owned fixture lost focus before manual conversion"); return }
                self.monitor?.cancel()
                do {
                    let message = try TextAccess().convert(expectedPID: self.process.processIdentifier)
                    self.manualResult = ["attempted": true, "succeeded": true, "message": message,
                                         "expectedRefusal": job.expectedManualRefusal]
                } catch {
                    let message = (error as? AccessFailure)?.message ?? String(describing: error)
                    self.manualResult = ["attempted": true, "succeeded": false, "error": message,
                                         "expectedRefusal": job.expectedManualRefusal]
                }
                self.check(job, sourceID: sourceID, keyCount: keyCount)
            }
        }

        func hasOnlyOwnedInput(_ snapshot: [String: Any]) -> Bool {
            guard let counts = snapshot["counts"] as? [String: Any],
                  counts["originsOverflowed"] as? Bool == false,
                  let origins = counts["observedOrigins"] as? [[String: Any]], origins.count <= 8,
                  let keyDown = counts["keyDown"] as? Int, keyDown == 0 || !origins.isEmpty else { return false }
            return origins.allSatisfy {
                let tag = $0["tag"] as? Int64
                return (tag == nonce || tag == 0x5452554d505357) && $0["sourcePID"] as? Int64 == Int64(getpid())
            }
        }

        func runFocusGuard(_ job: Job) {
            request(["command": "arm-focus-race"]) { [weak self] _ in
                guard let self, self.ownsFrontmostFixture() else { return }
                self.injector.async { [weak self] in
                    guard let self, self.ownsFrontmostFixture() else { return }
                    let result = ReplacementPreflight.check(original: "lkz", pid: self.process.processIdentifier)
                    var details: [String: Any] = ["matchedOriginalContext": false, "staleContextRejected": false]
                    if case .matches(let context) = result {
                        details["matchedOriginalContext"] = true
                        details["staleContextRejected"] = !ReplacementPreflight.isCurrent(context, original: "lkz", pid: self.process.processIdentifier)
                    }
                    DispatchQueue.main.async {
                        guard !self.finished, self.ownsFrontmostFixture() else {
                            self.finish(error: "Owned fixture lost focus during stale-context guard check"); return
                        }
                        self.request(["command": "snapshot"]) { early in
                            self.after(0.5) {
                                self.request(["command": "snapshot"]) { late in
                                    self.recordFocusRace(job, guardResult: details, keyCount: 0, early: early, late: late)
                                }
                            }
                        }
                    }
                }
            }
        }

        func recordFocusRace(_ job: Job, guardResult: [String: Any]?, keyCount: Int,
                             early: [String: Any], late: [String: Any]) {
            guard !finished else { return }
            guard [early, late].allSatisfy(hasOnlyOwnedInput) else {
                finish(error: "Input outside the owned focus-race sequence reached the fixture; snapshots were not saved"); return
            }
            var failures: [String] = []
            if (monitor?.deliveryTimeouts ?? 0) != 0 { failures.append("Delivery fence timed out") }
            for (moment, snapshot) in [("early", early), ("late", late)] {
                if snapshot["hookCount"] as? Int != 1 { failures.append("\(moment): AX race hook did not fire exactly once") }
                if job.mode == "focus-race-opaque", snapshot["raceTrigger"] as? String != "unsupported-marker-range" {
                    failures.append("\(moment): opaque race did not use the unsupported marker-range hook")
                }
                if snapshot["activeField"] as? String != "B" { failures.append("\(moment): focus did not move to the second field") }
                if snapshot["text"] as? String != "lkz" { failures.append("\(moment): original field was modified") }
                let targetKey = job.sample.focusGuard ? "targetUnchanged" : "targetHasOnlyBoundary"
                if snapshot[targetKey] as? Bool != true { failures.append("\(moment): second field received unexpected text changes") }
                if snapshot["targetSelectionLength"] as? Int != 0 { failures.append("\(moment): second field has an unexpected selection") }
                let counts = snapshot["counts"] as? [String: Any] ?? [:]
                let events = counts["eventLog"] as? [[String: Any]] ?? []
                let down = events.filter { $0["type"] as? String == "keyDown" }
                if down.contains(where: { $0["code"] as? Int == Int(kVK_Delete) }) { failures.append("\(moment): Backspace was sent across the focus change") }
                if job.sample.focusGuard {
                    if !down.isEmpty { failures.append("\(moment): read-only guard test emitted keyboard input") }
                } else {
                    let expectedCodes = originalEvents.compactMap { $0["code"] as? Int }
                    let actualCodes = down.compactMap { $0["code"] as? Int }
                    let actualPairs = events.compactMap { event -> String? in
                        guard let type = event["type"] as? String, ["keyDown", "keyUp"].contains(type),
                              let code = event["code"] as? Int else { return nil }
                        return "\(type):\(code)"
                    }
                    if expectedCodes.count != keyCount || actualCodes != expectedCodes ||
                        actualPairs != expectedCodes.flatMap({ ["keyDown:\($0)", "keyUp:\($0)"] }) ||
                        counts["keyDown"] as? Int != keyCount || counts["keyDownCompleted"] as? Int != keyCount || counts["keyUp"] as? Int != keyCount {
                        failures.append("\(moment): focus race did not deliver exactly the original ordered key pairs")
                    }
                }
            }
            if job.sample.focusGuard {
                if guardResult?["matchedOriginalContext"] as? Bool != true { failures.append("Preflight did not produce the deliberately stale original context") }
                if guardResult?["staleContextRejected"] as? Bool != true { failures.append("Production isCurrent accepted the stale context") }
            } else {
                if deliveryTimedOut { failures.append("Focus-race pipeline exceeded its delivery deadline") }
                if targetDeliveryTimedOut { failures.append("Focus-race editor did not complete the forwarded events within its delivery deadline") }
                if monitor?.receivedKeys != keyCount { failures.append("Focus-race input was not processed exactly once") }
                if monitor?.automaticCorrections != 0 { failures.append("Production monitor corrected after the field changed") }
                if InputSources.layout(forID: InputSources.currentID()) != job.sample.source { failures.append("A cancelled correction left the input source changed") }
            }
            let record: [String: Any] = ["case": job.name, "mode": job.mode,
                "passed": failures.isEmpty, "failures": failures,
                "scope": job.mode == "focus-race-opaque" ?
                    "Same owned process, distinct fields; physical lkz fully delivered before arming focus change on unsupported marker-range read" :
                    "Same owned process, distinct fields; focus changes after original AX range is captured",
                "guard": guardResult as Any? ?? NSNull(), "early": early, "late": late,
                "deliveryLatencyMS": job.sample.focusGuard ? 0 : deliveryLatencyMS,
                "targetDeliveryLatencyMS": job.sample.focusGuard ? 0 : targetDeliveryLatencyMS,
                "targetDeliveryCounts": job.sample.focusGuard ? [:] : targetDeliveryCounts,
                "deliveryTimeouts": monitor?.deliveryTimeouts ?? 0, "deliveryAcks": monitor?.deliveryAcks ?? 0,
                "monitorTrace": monitor?.inputTrace as Any? ?? NSNull()]
            results.append(record)
            print("\(failures.isEmpty ? "PASS" : "FAIL") \(job.name): \(failures.joined(separator: "; "))")
            index += 1; save(status: "running"); next()
        }

        func check(_ job: Job, sourceID: String, keyCount: Int) {
            deliveryLatencyMS = 0
            deliveryTimedOut = false
            targetDeliveryLatencyMS = 0
            targetDeliveryTimedOut = false
            targetDeliveryCounts = [:]
            let started = lastPostedAt > 0 ? lastPostedAt : ProcessInfo.processInfo.systemUptime
            // AppKit's cursor/input-context startup can block super.sendEvent
            // for ~0.5 s even in no-filter controls. Its measured delivery is
            // separate from the strict stability snapshots, never hidden by
            // extending the deadline after an intermediate progress update.
            let budget = job.interval == 0 ? min(3, 1.2 + 0.075 * Double(max(job.sample.corrections - 1, 0))) : 1.2
            deliveryBudgetMS = budget * 1000
            waitForDelivery(job, sourceID: sourceID, keyCount: keyCount, started: started, deadline: started + budget)
        }

        func expectedProcessedKeys(_ job: Job, keyCount: Int) -> Int {
            guard job.sample.filterEnabled else { return 0 }
            return job.processedKeyCountBeforeCancellation ?? keyCount
        }

        func waitForDelivery(_ job: Job, sourceID: String, keyCount: Int, started: TimeInterval, deadline: TimeInterval) {
            guard !finished, let monitor else { return }
            guard ownsFrontmostFixture() else { finish(error: "Owned fixture lost focus while awaiting event delivery"); return }
            let now = ProcessInfo.processInfo.systemUptime
            let delivered = monitor.receivedKeys == expectedProcessedKeys(job, keyCount: keyCount) && !monitor.hasPendingInput
            if !delivered, now < deadline {
                after(0.005) { [weak self] in self?.waitForDelivery(job, sourceID: sourceID, keyCount: keyCount,
                    started: started, deadline: deadline) }
                return
            }
            deliveryLatencyMS = (now - started) * 1000
            deliveryTimedOut = !delivered || now > deadline
            waitForTargetDelivery(job, sourceID: sourceID, keyCount: keyCount, started: started, deadline: deadline)
        }

        func waitForTargetDelivery(_ job: Job, sourceID: String, keyCount: Int, started: TimeInterval, deadline: TimeInterval) {
            guard !finished, let monitor else { return }
            guard ownsFrontmostFixture() else { finish(error: "Owned fixture lost focus while awaiting editor completion"); return }
            request(["command": "snapshot"]) { [weak self] snapshot in
                guard let self, !self.finished else { return }
                guard self.hasOnlyOwnedInput(snapshot) else {
                    self.finish(error: "Input outside the owned test sequence reached the fixture; readiness text was not saved"); return
                }
                let counts = snapshot["counts"] as? [String: Any] ?? [:]
                // Safety races permit only the original sequence. Secure Input
                // can hide the boundary's re-post from the monitor tap after
                // focus moves, although the owned editor receives it normally.
                // Use the independent exact original count for these cases.
                let originalOnly = job.isFocusRace || !job.sample.filterEnabled
                let expectedDown = originalOnly ? keyCount : monitor.forwardedKeyDowns
                let expectedUp = originalOnly ? job.originalKeyUpCount(keyDownCount: keyCount) : monitor.forwardedKeyUps
                let actualDown = counts["keyDown"] as? Int ?? -1
                let actualCompleted = counts["keyDownCompleted"] as? Int ?? -1
                let actualUp = counts["keyUp"] as? Int ?? -1
                let transportIdle = monitor.receivedKeys == self.expectedProcessedKeys(job, keyCount: keyCount) && !monitor.hasPendingInput
                // AppKit spelling may consume a queued keyDown in its own
                // input loop and insert a batch, bypassing NSApp.sendEvent.
                // Accept that only for spelling fixtures without an exact
                // ordering oracle, with independent destination-tail receipt
                // of every head-forwarded event and every target key release.
                // Critical ordering cases and no-filter controls stay exact.
                let canCoalesce = job.mode.hasSuffix("-autocorrect") && !originalOnly && self.orderingExpectedCodes == nil
                let tailComplete = monitor.tailKeyDowns == expectedDown && monitor.tailKeyUps == expectedUp
                let downsComplete = actualDown == expectedDown ||
                    (canCoalesce && tailComplete && actualDown > 0 && actualDown < expectedDown)
                let expectedBalance = originalOnly && job.sample.repeatsFinalSpace
                    ? expectedDown == expectedUp + 1 : expectedDown == expectedUp
                let ready = transportIdle && expectedDown >= keyCount && expectedBalance &&
                    downsComplete && actualCompleted == actualDown && actualUp == expectedUp &&
                    (!canCoalesce || tailComplete)
                let observedAt = snapshot["snapshotTime"] as? Double ?? ProcessInfo.processInfo.systemUptime
                let now = ProcessInfo.processInfo.systemUptime
                if !ready && now < deadline {
                    self.after(0.008) { [weak self] in
                        self?.waitForTargetDelivery(job, sourceID: sourceID, keyCount: keyCount, started: started, deadline: deadline)
                    }
                    return
                }
                self.targetDeliveryLatencyMS = (observedAt - started) * 1000
                self.targetDeliveryTimedOut = !ready || observedAt > deadline
                self.targetDeliveryCounts = ["expectedKeyDown": expectedDown, "expectedKeyUp": expectedUp,
                    "actualKeyDown": actualDown, "actualKeyDownCompleted": actualCompleted, "actualKeyUp": actualUp,
                    "destinationTailKeyDown": monitor.tailKeyDowns, "destinationTailKeyUp": monitor.tailKeyUps,
                    "coalescedKeyDowns": canCoalesce && tailComplete ? max(0, expectedDown - actualDown) : 0]
                self.takeStabilitySnapshots(job, sourceID: sourceID, keyCount: keyCount)
            }
        }

        func takeStabilitySnapshots(_ job: Job, sourceID: String, keyCount: Int) {
            after(0.1) { [weak self] in
                self?.request(["command": "snapshot"]) { [weak self] early in
                    guard let self else { return }
                    self.after(0.4) { [weak self] in
                        self?.request(["command": "snapshot"]) { [weak self] late in
                            self?.record(job, sourceID: sourceID, keyCount: keyCount, early: early, late: late)
                        }
                    }
                }
            }
        }

        func webBoundaryKey(_ job: Job) -> String? {
            guard ["web-contenteditable", "web-group", "web-rich"].contains(job.mode),
                  let boundary = job.sample.boundary,
                  [UInt16(kVK_Return), UInt16(kVK_Tab)].contains(boundary) else { return nil }
            // The whole expected value includes any prefix and trailing space.
            // A control for one phrase can never approve a different phrase.
            return "\(job.mode)|\(boundary)|\(job.expected)"
        }

        func expectsSelectionReplacement(in mode: String) -> Bool {
            // Independent fixture capability expectation, never inferred from
            // the production counter or the observed output key sequence.
            ["web-contenteditable", "web-rich", "web-input", "web-textarea"].contains(mode)
        }

        func webBoundaryObservation(_ value: [String: Any]) -> WebBoundaryObservation? {
            guard let text = value["text"] as? String, let rendered = value["renderedText"] as? String,
                  let focused = value["focused"] as? Bool, let within = value["selectionWithinTarget"] as? Bool,
                  let state = value["selectionState"] as? String else { return nil }
            let selection: NSRange?
            if within {
                guard state == "inside-target", let range = value["selection"] as? [String: Int],
                      let location = range["location"], let length = range["length"],
                      location >= 0, location <= text.utf16.count,
                      length >= 0, length <= text.utf16.count - location,
                      value["caret"] as? Int == location else { return nil }
                selection = NSRange(location: location, length: length)
            } else {
                guard ["absent", "outside-target"].contains(state),
                      value["selection"] is NSNull, value["caret"] is NSNull else { return nil }
                selection = nil
            }
            return WebBoundaryObservation(text: text, renderedText: rendered, focused: focused,
                                          selectionState: state, selection: selection)
        }

        func record(_ job: Job, sourceID: String, keyCount: Int, early: [String: Any], late: [String: Any]) {
            guard !finished, let monitor else { return }
            if job.isFocusRace {
                recordFocusRace(job, guardResult: nil, keyCount: keyCount, early: early, late: late)
                return
            }
            // A user can still physically type into this owned test window.
            // Stop before retaining either snapshot if that happens, so the
            // diagnostic file contains only deliberate fixture data.
            for snapshot in [early, late] {
                if !hasOnlyOwnedInput(snapshot) {
                    finish(error: "Input outside the owned test sequence reached the fixture; current text was not saved")
                    return
                }
            }
            var failures: [String] = []
            if monitor.deliveryTimeouts != 0 { failures.append("Delivery fence timed out") }
            if deliveryTimedOut { failures.append("Event pipeline exceeded its bounded delivery deadline") }
            if targetDeliveryTimedOut { failures.append("Editor did not complete exactly the forwarded events within the fixed delivery deadline") }
            let nativeBoundary = job.mode == "field" && job.sample.boundary.map {
                [UInt16(kVK_Return), UInt16(kVK_Tab)].contains($0)
            } == true
            let webControlKey = webBoundaryKey(job)
            let webControl = webControlKey.flatMap { webBoundaryBaselines[$0] }
            if nativeBoundary, job.sample.filterEnabled,
               job.sample.boundary.flatMap({ nativeBoundaryBaselineSelections[$0] }) == nil {
                failures.append("Matching no-filter native boundary control is missing or failed")
            }
            if webControlKey != nil, job.sample.filterEnabled, webControl == nil {
                failures.append("Matching no-filter Web boundary control is missing or failed")
            }
            func selectionShape(_ selection: [String: Int], length: Int) -> String? {
                if selection["location"] == length && selection["length"] == 0 { return "caret-at-end" }
                if selection["location"] == 0 && selection["length"] == length { return "all-selected" }
                return nil
            }
            for (moment, value) in [("100ms", early), ("500ms", late)] {
                let text = value["text"] as? String ?? ""
                let selection = value["selection"] as? [String: Int] ?? [:]
                let counts = value["counts"] as? [String: Any] ?? [:]
                let boundary = job.sample.boundary
                let web = job.mode.hasPrefix("web-")
                let singleLine = job.mode == "field" || job.mode == "web-input"
                let suffixes: [String]
                if boundary == UInt16(kVK_Return) {
                    // contenteditable uses BR/div nodes, absent from textContent;
                    // textarea and NSTextView store the actual newline itself.
                    suffixes = singleLine ? [""] : web && job.mode != "web-textarea" ? ["", "\n"] : ["\n"]
                } else if boundary == UInt16(kVK_Tab) { suffixes = web || singleLine ? [""] : ["\t"] }
                else { suffixes = [""] }
                var expectedTexts = suffixes.map { job.expected + $0 }
                if webControlKey != nil {
                    if job.sample.filterEnabled {
                        expectedTexts = webControl.map { [$0.observation.text] } ?? []
                    } else if boundary == UInt16(kVK_Return), job.expected.hasSuffix(" ") {
                        // Only the final ordinary space immediately before the
                        // native Enter may become NBSP in a browser control.
                        // The measured exact result, not normalization, is used
                        // for the corresponding correction afterward.
                        let nbsp = String(job.expected.dropLast()) + "\u{00A0}"
                        expectedTexts += suffixes.map { nbsp + $0 }
                    }
                }
                if !expectedTexts.contains(text) { failures.append("\(moment): text mismatch") }
                if web, boundary != UInt16(kVK_Return), !job.sample.trailingKeys.contains(UInt16(kVK_Return)),
                   value["renderedText"] as? String != text {
                    failures.append("\(moment): Web editor gained visible whitespace or line breaks without Enter")
                }
                if job.mode == "web-rich", !job.sample.prefix.isEmpty,
                   value["formattedPrefixPreserved"] as? Bool != true {
                    failures.append("\(moment): correction changed the bold formatting of the existing prefix")
                }
                let shape = selectionShape(selection, length: text.utf16.count)
                let baselineSelection = nativeBoundary && (!job.sample.filterEnabled ? shape != nil :
                    (job.sample.boundary.flatMap { nativeBoundaryBaselineSelections[$0] }).map { $0 == shape } == true)
                if webControlKey != nil {
                    if let observed = webBoundaryObservation(value) {
                        if job.sample.filterEnabled {
                            if let expected = webControl?.observation {
                                if observed.renderedText != expected.renderedText {
                                    failures.append("\(moment): rendered Web text differs from its no-filter control")
                                }
                                if observed.focused != expected.focused || observed.selectionState != expected.selectionState ||
                                    observed.selection != expected.selection {
                                    failures.append("\(moment): Web boundary selection or focus differs from its no-filter control")
                                }
                            }
                        } else {
                            let atEnd = observed.selection == NSRange(location: text.utf16.count, length: 0)
                            let blurredTab = boundary == UInt16(kVK_Tab) && !observed.focused && observed.selection == nil
                            if !(atEnd || blurredTab) || (boundary == UInt16(kVK_Return) && !observed.focused) {
                                failures.append("\(moment): no-filter Web boundary has an invalid editor selection or focus")
                            }
                        }
                    } else {
                        failures.append("\(moment): Web selection ownership metadata is missing or invalid")
                    }
                } else if let expected = job.sample.expectedSelection {
                    if selection["location"] != expected.location || selection["length"] != expected.length {
                        failures.append("\(moment): manually converted phrase did not retain its exact selection")
                    }
                } else if !baselineSelection, shape != "caret-at-end" {
                    failures.append("\(moment): caret or selection mismatch")
                }
                if boundary == UInt16(kVK_Return), counts["enter"] as? Int != 1 { failures.append("\(moment): Enter not delivered exactly once") }
                if boundary == UInt16(kVK_Tab), counts["tab"] as? Int != 1 { failures.append("\(moment): Tab not delivered exactly once") }
                if job.sample.manualInitialText == nil, (counts["keyDown"] as? Int ?? 0) == 0 {
                    failures.append("\(moment): editor received no key events")
                }
                if let expected = job.sample.expectedEditorCapitalizations, counts["editorCapitalizations"] as? Int != expected {
                    failures.append("\(moment): deterministic editor capitalization did not occur exactly once")
                }
                if !job.sample.filterEnabled, counts["keyDown"] as? Int != keyCount {
                    failures.append("\(moment): no-filter baseline has not received exactly the posted key-downs")
                }
                if job.sample.repeatsFinalSpace {
                    let events = (counts["eventLog"] as? [[String: Any]] ?? []).filter {
                        ["keyDown", "keyUp"].contains($0["type"] as? String ?? "")
                    }
                    let repeatEvents = events.enumerated().filter { $0.element["autorepeat"] as? Int == 1 }
                    if job.sample.filterEnabled {
                        if counts["repeatKeyDown"] as? Int != 0 || !repeatEvents.isEmpty ||
                           events.suffix(2).first?["type"] as? String != "keyDown" ||
                           events.suffix(2).first?["code"] as? Int != Int(kVK_Space) ||
                           events.suffix(2).first?["isARepeat"] as? Bool != false ||
                           events.last?["type"] as? String != "keyUp" ||
                           events.last?["code"] as? Int != Int(kVK_Space) {
                            failures.append("\(moment): repeat after replacement must restart the released Space press and retain its release")
                        }
                    } else if counts["repeatKeyDown"] as? Int != 1 || repeatEvents.count != 1 ||
                       repeatEvents.first?.offset != events.count - 2 ||
                       repeatEvents.first?.element["type"] as? String != "keyDown" ||
                       repeatEvents.first?.element["code"] as? Int != Int(kVK_Space) ||
                       repeatEvents.first?.element["isARepeat"] as? Bool != true ||
                       events.last?["type"] as? String != "keyUp" ||
                       events.last?["code"] as? Int != Int(kVK_Space) ||
                       events.last?["autorepeat"] as? Int != 0 {
                        failures.append("\(moment): exactly one Space repeat down must reach the editor immediately before its release")
                    }
                    if !job.sample.filterEnabled {
                        // Independent baseline oracle: three ordinary presses,
                        // then a single held Space with one autorepeat down.
                        let expected = ["keyDown:37:0", "keyUp:37:0", "keyDown:40:0", "keyUp:40:0",
                                        "keyDown:6:0", "keyUp:6:0", "keyDown:49:0", "keyDown:49:1", "keyUp:49:0"]
                        let actual = events.compactMap { event -> String? in
                            guard let type = event["type"] as? String, let code = event["code"] as? Int,
                                  let repeatFlag = event["autorepeat"] as? Int else { return nil }
                            return "\(type):\(code):\(repeatFlag)"
                        }
                        if actual != expected || counts["keyDown"] as? Int != 5 ||
                           counts["keyDownCompleted"] as? Int != 5 || counts["keyUp"] as? Int != 4 {
                            failures.append("\(moment): no-filter autorepeat baseline differs from the exact 5-down/4-up physical plan")
                        }
                    }
                }
                if let expectedCodes = orderingExpectedCodes {
                    let events = counts["eventLog"] as? [[String: Any]] ?? []
                    let downCodes = events.filter { $0["type"] as? String == "keyDown" }.compactMap { $0["code"] as? Int }
                    if downCodes != expectedCodes {
                        failures.append("\(moment): editor key order differs from original → delete → replacement → boundary → continuation")
                    }
                    if counts["keyUp"] as? Int != expectedCodes.count {
                        failures.append("\(moment): editor key releases are missing or duplicated in the ordering sequence")
                    }
                    let observedPairs = events.compactMap { event -> String? in
                        guard let type = event["type"] as? String, ["keyDown", "keyUp"].contains(type),
                              let code = event["code"] as? Int else { return nil }
                        return "\(type):\(code)"
                    }
                    let expectedPairs = expectedCodes.flatMap { ["keyDown:\($0)", "keyUp:\($0)"] }
                    if observedPairs != expectedPairs {
                        failures.append("\(moment): a key release or continuation crossed the ordered replacement event sequence")
                    }
                    if let range = orderingSelectionRange {
                        let pairs = events.filter { ["keyDown", "keyUp"].contains($0["type"] as? String ?? "") }
                        let selectionEvents = pairs.dropFirst(range.location * 2).prefix(range.length * 2)
                        let mask: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
                        if selectionEvents.count != range.length * 2 || !selectionEvents.allSatisfy({ event in
                            guard event["code"] as? Int == Int(kVK_LeftArrow), let flags = event["flags"] as? UInt else { return false }
                            return flags & mask.rawValue == NSEvent.ModifierFlags.shift.rawValue
                        }) {
                            failures.append("\(moment): verified word was not selected by exact Shift+Left down/up pairs")
                        }
                    }
                }
                if expectsSelectionReplacement(in: job.mode), job.sample.filterEnabled,
                   !job.sample.trailingKeys.contains(UInt16(kVK_Delete)) {
                    let events = counts["eventLog"] as? [[String: Any]] ?? []
                    if events.contains(where: { $0["type"] as? String == "keyDown" && $0["code"] as? Int == Int(kVK_Delete) }) {
                        failures.append("\(moment): verified Web editor received a standalone Delete instead of selection replacement")
                    }
                }
            }
            let expectedKeys = expectedProcessedKeys(job, keyCount: keyCount)
            if job.sample.repeatsFinalSpace {
                let codes = originalEvents.compactMap { $0["code"] as? Int }
                let repeats = originalEvents.compactMap { $0["autorepeat"] as? Int }
                if codes != [37, 40, 6, 49, 49] || repeats != [0, 0, 0, 0, 1] {
                    failures.append("Original autorepeat fixture events did not match the reviewed fixed plan")
                }
            }
            if monitor.receivedKeys != expectedKeys { failures.append("Production filter did not process original key events exactly once (\(monitor.receivedKeys)/\(expectedKeys))") }
            if job.sample.cancelAfterFirstCommit {
                if cancellationTrigger?["hasPendingInput"] as? Bool != true ||
                   cancellationTrigger?["automaticCorrections"] as? Int != 1 ||
                   cancellationTrigger?["receivedKeys"] as? Int != expectedKeys {
                    failures.append("Cancellation did not interrupt the pending first committed replacement before continuation")
                }
                let before = cancellationTrigger?["orderedCancellationsBefore"] as? Int ?? monitor.orderedCancellations
                if monitor.orderedCancellations <= before { failures.append("Ordered input cancellation was not exercised") }
                if monitor.automaticCorrections != 1 { failures.append("Cancellation allowed a later automatic correction") }
                if job.sample.requiresCapturedCancellationTail {
                    if cancellationTrigger?["capturedTailKeyDowns"] as? Int != 1 ||
                       cancellationTrigger?["capturedTailWasPendingDot"] as? Bool != true {
                        failures.append("Cancellation did not capture exactly the fourth original dot behind the committed replacement")
                    }
                    let preserved = monitor.inputTrace.filter { $0["step"] as? String == "period-cancel-preserved" }
                    if preserved.count != 1 {
                        failures.append("Cancellation did not preserve exactly one captured literal ellipsis continuation")
                    }
                }

            }
            if job.sample.corrections > 0, monitor.automaticCorrections < job.sample.corrections { failures.append("Production filter did not perform the required correction") }
            if job.sample.corrections == 0, monitor.automaticCorrections != 0 { failures.append("A correctly typed word was changed") }
            if job.sample.requiresExactCorrectionCount, monitor.automaticCorrections != job.sample.corrections {
                failures.append("Ellipsis handling did not perform exactly the planned whole-word corrections")
            }
            let expectedSelectionReplacements = expectsSelectionReplacement(in: job.mode) ? monitor.automaticCorrections : 0
            if monitor.selectionKeyboardReplacements != expectedSelectionReplacements {
                failures.append("Keyboard replacement route did not match the independently expected editor capability")
            }
            if job.sample.manual {
                if manualResult?["attempted"] as? Bool != true { failures.append("Manual conversion was not exercised") }
                if job.expectedManualRefusal {
                    if manualResult?["succeeded"] as? Bool != false { failures.append("Opaque manual access was not safely refused") }
                } else if manualResult?["succeeded"] as? Bool != true { failures.append("Production manual conversion failed") }
            }
            if job.mode == "opaque", job.sample.corrections > 0, monitor.keyboardFallbacks == 0 { failures.append("Opaque field did not exercise keyboard fallback") }
            if early["text"] as? String != late["text"] as? String { failures.append("Text changed after the first snapshot") }
            if let key = webControlKey, !job.sample.filterEnabled {
                let earlyState = webBoundaryObservation(early), lateState = webBoundaryObservation(late)
                if earlyState != lateState { failures.append("No-filter Web boundary state changed after the first snapshot") }
                if failures.isEmpty, let observation = earlyState {
                    webBoundaryBaselines[key] = (job.name, observation)
                }
            }
            if nativeBoundary, !job.sample.filterEnabled, failures.isEmpty, let boundary = job.sample.boundary,
               let earlyShape = selectionShape(early["selection"] as? [String: Int] ?? [:], length: job.expected.utf16.count),
               earlyShape == selectionShape(late["selection"] as? [String: Int] ?? [:], length: job.expected.utf16.count) {
                nativeBoundaryBaselineSelections[boundary] = earlyShape
            }
            let nativeEvents = ((late["counts"] as? [String: Any])?["eventLog"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? String == "keyDown" }
            let targetDelays = nativeEvents.compactMap { event -> Double? in
                guard let processed = event["processingTime"] as? Double, let created = event["timestamp"] as? Double else { return nil }
                return (processed - created) * 1000
            }
            let lastTargetTime = nativeEvents.compactMap { $0["processingTime"] as? Double }.max()
            let record: [String: Any] = [
                "case": job.name, "mode": job.mode, "input": job.sample.input,
                "caseScope": job.sample.manualInitialText == nil ? "Physical key events and production input processing" :
                    "Manual AX conversion of an explicit fixture selection; no physical keyboard events",
                "filterEnabled": job.sample.filterEnabled,
                "cancelAfterFirstCommit": job.sample.cancelAfterFirstCommit,
                "cancellationTrigger": cancellationTrigger as Any? ?? NSNull(),
                "expectedProcessedKeys": expectedKeys,
                "originalEventPlan": ["keyDown": keyCount, "keyUp": job.originalKeyUpCount(keyDownCount: keyCount),
                                      "autorepeatDown": job.sample.repeatsFinalSpace ? 1 : 0],
                "repeatsFinalSpace": job.sample.repeatsFinalSpace,
                "requiresCapturedCancellationTail": job.sample.requiresCapturedCancellationTail,
                "prefix": job.sample.prefix, "expected": job.expected, "sourceID": sourceID,
                "trailingKeys": job.sample.trailingKeys.map { Int($0) },
                "trailingText": job.sample.trailingText,
                "orderingExpectedKeyCodes": orderingExpectedCodes as Any? ?? NSNull(),
                "orderingSelectionRange": orderingSelectionRange.map { ["location": $0.location, "length": $0.length] } as Any? ?? NSNull(),
                "expectedKeyboardReplacementRoute": expectsSelectionReplacement(in: job.mode) ? "verified-selection" : "backspace",
                "expectedEditorCapitalizations": job.sample.expectedEditorCapitalizations as Any? ?? NSNull(),
                "manualInitialText": job.sample.manualInitialText as Any? ?? NSNull(),
                "manualInitialSelection": job.sample.manualInitialSelection.map { ["location": $0.location, "length": $0.length] } as Any? ?? NSNull(),
                "expectedSelection": job.sample.expectedSelection.map { ["location": $0.location, "length": $0.length] } as Any? ?? NSNull(),
                "manualConversion": manualResult as Any? ?? NSNull(),
                "boundaryKey": job.sample.boundary.map { Int($0) } as Any? ?? NSNull(),
                "webBoundaryControl": webControl.map { ["case": $0.name, "observation": $0.observation.json] } as Any? ?? NSNull(),
                "intervalMS": job.interval * 1000,
                "pausesAfterKey": job.sample.pausesAfterKey.sorted { $0.key < $1.key }.map { ["completedKeyPairs": Double($0.key), "pauseMS": $0.value * 1000] },
                "requiresExactCorrectionCount": job.sample.requiresExactCorrectionCount,
                "expectedCorrections": job.sample.corrections,
                "deliveryLatencyMS": deliveryLatencyMS,
                "targetDeliveryLatencyMS": targetDeliveryLatencyMS,
                "targetDeliveryTimedOut": targetDeliveryTimedOut, "targetDeliveryCounts": targetDeliveryCounts,
                "deliveryBudgetMS": deliveryBudgetMS,
                "lastPostedAt": lastPostedAt,
                "targetLastKeyDeliveryMS": lastTargetTime.map { ($0 - lastPostedAt) * 1000 } as Any? ?? NSNull(),
                "targetMaximumKeyDelayMS": targetDelays.max() as Any? ?? NSNull(),
                "snapshotTiming": "100/500 ms after bounded event drain. Spelling fixtures may coalesce sendEvent keyDown only with exact head/tail delivery, completed observed downs and exact keyUps; text/caret/order remain strict",
                "passed": failures.isEmpty, "failures": failures,
                "originalEvents": originalEvents,
                "early": early, "late": late,
                "monitor": ["receivedKeys": monitor.receivedKeys, "automaticCorrections": monitor.automaticCorrections,
                            "selectionKeyboardReplacements": monitor.selectionKeyboardReplacements,
                            "ownSelectionWaits": monitor.ownSelectionWaits,
                            "orderedCancellations": monitor.orderedCancellations,
                            "forwardedKeyDowns": monitor.forwardedKeyDowns, "forwardedKeyUps": monitor.forwardedKeyUps,
                            "tailKeyDowns": monitor.tailKeyDowns, "tailKeyUps": monitor.tailKeyUps,
                            "directCorrections": monitor.directCorrections, "unconfirmedWrites": monitor.unconfirmedWrites,
                            "inputTrace": monitor.inputTrace,
                            "keyboardFallbacks": monitor.keyboardFallbacks, "confirmedKeyboardWrites": monitor.confirmedKeyboardWrites,
                            "lateEditorChanges": monitor.lateEditorChanges, "foreignInputEvents": monitor.foreignInputEvents,
                            "reconciledKeys": monitor.reconciledKeys, "rejectedContextKeys": monitor.rejectedContextKeys,
                            "incompleteWords": monitor.incompleteWords, "decisionStatus": monitor.decisionStatus,
                            "contextStatus": monitor.contextStatus, "longestCallbackMS": monitor.longestCallbackMS,
                            "deliveryTimeouts": monitor.deliveryTimeouts, "deliveryAcks": monitor.deliveryAcks]
            ]
            results.append(record)
            print("\(failures.isEmpty ? "PASS" : "FAIL") \(job.name): \(failures.joined(separator: "; "))")
            index += 1
            save(status: "running")
            next()
        }

        func request(_ values: [String: Any], reply: @escaping ([String: Any]) -> Void) {
            guard !finished, process.isRunning else { return }
            requestNumber += 1
            let id = "request-\(requestNumber)"
            var values = values; values["id"] = id
            guard var bytes = try? JSONSerialization.data(withJSONObject: values) else { finish(error: "Cannot encode fixture request"); return }
            bytes.append(10)
            pending[id] = reply
            do { try input.fileHandleForWriting.write(contentsOf: bytes) }
            catch { finish(error: "Could not send a command to the owned fixture"); return }
            after(15) { [weak self] in
                guard let self, self.pending[id] != nil, !self.finished else { return }
                self.finish(error: "Fixture command timed out: \(id)")
            }
        }

        func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }

        func save(status: String, error: String? = nil) {
            let passed = results.filter { $0["passed"] as? Bool == true }.count
            var report: [String: Any] = [
                "status": status, "started": ISO8601DateFormatter().string(from: started),
                "updated": ISO8601DateFormatter().string(from: Date()), "scope": "Owned AppKit and WKWebView fixture only",
                "mechanism": "Physical keycodes posted to owned child PID, production AutoMonitor process event tap, cross-process AX and real editor input",
                "limitation": "Synthetic process-directed events test the event pipeline; they do not reproduce physical HID origin or prove every third-party editor",
                "planned": jobs.count, "completed": results.count, "passed": passed, "failed": results.count - passed,
                "results": results
            ]
            if let error { report["error"] = error }
            if !fixtureErrorFlags.isEmpty { report["fixtureErrorFlags"] = fixtureErrorFlags }
            if !parentActivationFlags.isEmpty { report["parentActivationFlags"] = parentActivationFlags }
            if let frontmostAtFinish { report["frontmostAtFinish"] = frontmostAtFinish }
            do {
                let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try bytes.write(to: reportURL, options: .atomic)
            } catch { fputs("Could not save input pipeline report: \(error.localizedDescription)\n", stderr) }
        }

        func finish(error: String?) {
            guard !finished else { return }
            // Classify only against the two owned processes. Never retain the
            // identity, name, window contents, or text of another application.
            if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                if frontmost == getpid() { frontmostAtFinish = "runner" }
                else if process.isRunning && frontmost == process.processIdentifier { frontmostAtFinish = "fixture" }
                else { frontmostAtFinish = "other" }
            } else { frontmostAtFinish = "none" }
            finished = true
            monitor?.stop(); monitor = nil
            pending.removeAll()
            output.fileHandleForReading.readabilityHandler = nil
            if let previousSource { _ = InputSources.selectID(previousSource) }
            save(status: error == nil ? "completed" : "aborted", error: error)
            if process.isRunning { process.terminate() }
            let failures = results.filter { $0["passed"] as? Bool != true }.count
            if let error { fputs("Input pipeline aborted: \(error)\n", stderr) }
            print("Input pipeline: \(results.count - failures) passed, \(failures) failed, \(jobs.count) planned")
            exit(error == nil && failures == 0 && !jobs.isEmpty ? 0 : 1)
        }
    }
}
