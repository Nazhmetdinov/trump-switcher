import AppKit
import Carbon
import Darwin
import SwitcherCore

/// Explicit CLI checks only: isolated preferences/files and an invisible own
/// settings window. Never installs a tap, posts events or queries other apps.
enum ApplicationConfigurationChecks {
    static func run() throws {
        var checks = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ name: String) {
            precondition(try! value(), "Application configuration: " + name); checks += 1
        }
        let suite = "local.trumpswitcher.checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(defaults: defaults)
        expect(store.settings == CorrectionSettings(), "fresh preferences use defaults")
        let damagedSuite = "local.trumpswitcher.checks." + UUID().uuidString
        let damagedDefaults = UserDefaults(suiteName: damagedSuite)!
        defer { damagedDefaults.removePersistentDomain(forName: damagedSuite) }
        let damagedData = Data("damaged saved configuration".utf8)
        damagedDefaults.set(damagedData, forKey: "localSettingsV1")
        let damagedStore = PreferencesStore(defaults: damagedDefaults)
        expect(damagedStore.invalidSavedSettings && !damagedStore.settings.automatic,
               "corrupt preferences never silently enable automatic edits")
        expect(damagedDefaults.data(forKey: "localSettingsV1") == damagedData, "loading corruption preserves original data")
        try damagedStore.save(CorrectionSettings())
        expect(damagedDefaults.data(forKey: "localSettingsV1Recovery") == damagedData,
               "explicit recovery retains a backup before replacing bad preferences")
        expect(!damagedStore.invalidSavedSettings && !PreferencesStore(defaults: damagedDefaults).invalidSavedSettings,
               "valid explicit save clears recovery state")
        for original in ["wrong stored type", 1, ["unexpected"], ["unexpected": true]] as [Any] {
            damagedDefaults.set(original, forKey: "localSettingsV1")
            let wrongType = PreferencesStore(defaults: damagedDefaults)
            expect(wrongType.invalidSavedSettings && !wrongType.settings.automatic,
                   "wrong stored property-list type is corruption, not a fresh installation")
            try wrongType.save(CorrectionSettings())
            expect((damagedDefaults.object(forKey: "localSettingsV1Recovery") as? NSObject)?.isEqual(original) == true,
                   "recovery preserves the original property-list value")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        let file = root.appendingPathComponent("settings.json")
        for bits in 0..<512 {
            var next = CorrectionSettings()
            next.automatic = bits & 1 != 0; next.toRussian = bits & 2 != 0; next.toEnglish = bits & 4 != 0
            next.shortWords = bits & 8 != 0; next.punctuation = bits & 16 != 0; next.addresses = bits & 32 != 0
            next.onEnter = bits & 64 != 0; next.onTab = bits & 128 != 0; next.allowAllCaps = bits & 256 != 0
            try store.save(next)
            expect(PreferencesStore(defaults: defaults).settings == next, "all flag combinations survive store reload")
        }
        var configured = CorrectionSettings()
        configured.excludedWords = ["git", "Яндекс", "yandex.ru"]
        configured.excludedApps = ["local.example.editor"]
        configured.rules = [CorrectionRule(input: "zz", output: "тест текста", russian: true)]
        configured.preferredRussian = InputSources.russianIDs[1]; configured.preferredEnglish = InputSources.englishIDs[1]
        try store.save(configured)
        try encoder.encode(configured).write(to: file, options: .atomic)
        expect(try SettingsFile.read(file) == configured, "exported settings import without lost fields")
        expect(PreferencesStore(defaults: defaults).settings == configured, "lists and chosen layouts survive reload")
        expect(defaults.synchronize(), "isolated preferences flush for independent-process check")
        let preferencesChild = Process(), preferencesOutput = Pipe()
        preferencesChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        preferencesChild.arguments = ["--check-preferences-suite", suite]; preferencesChild.standardOutput = preferencesOutput
        try preferencesChild.run()
        let coldData = preferencesOutput.fileHandleForReading.readDataToEndOfFile()
        preferencesChild.waitUntilExit()
        expect(preferencesChild.terminationStatus == 0 && CorrectionSettings.decode(coldData) == configured,
               "fresh process reads persisted rules, exclusions, flags and selected layouts")
        let storedBefore = defaults.data(forKey: "localSettingsV1")
        var invalid = configured; invalid.rules.append(invalid.rules[0])
        do { try store.save(invalid); preconditionFailure("Invalid duplicate rule accepted") } catch { checks += 1 }
        expect(store.settings == configured && defaults.data(forKey: "localSettingsV1") == storedBefore,
               "failed save leaves both memory and persistent data unchanged")
        var invalidConfigurations: [CorrectionSettings] = []
        invalid = configured; invalid.preferredRussian = "unsupported.layout"; invalidConfigurations.append(invalid)
        invalid = configured; invalid.preferredEnglish = "unsupported.layout"; invalidConfigurations.append(invalid)
        invalid = configured; invalid.rules.append(CorrectionRule(input: "different", output: "тест", russian: true, id: configured.rules[0].id)); invalidConfigurations.append(invalid)
        invalid = configured; invalid.rules.append(CorrectionRule(input: "zz", output: "other", russian: false)); invalidConfigurations.append(invalid)
        invalid = configured; invalid.excludedWords = Array(repeating: "word", count: 5001); invalidConfigurations.append(invalid)
        invalid = configured; invalid.excludedApps = Array(repeating: "local.example", count: 1001); invalidConfigurations.append(invalid)
        invalid = configured; invalid.excludedWords = ["two words"]; invalidConfigurations.append(invalid)
        invalid = configured; invalid.rules = [CorrectionRule(input: "bad", output: "text\n", russian: false)]; invalidConfigurations.append(invalid)
        invalid = configured; invalid.rules = [CorrectionRule(input: "bad", output: "text\t", russian: false)]; invalidConfigurations.append(invalid)
        for control in ["\u{0}", "\u{7f}", "\u{85}", "\u{202e}"] {
            invalid = configured; invalid.rules = [CorrectionRule(input: "bad" + control, output: "тест", russian: true)]; invalidConfigurations.append(invalid)
            invalid = configured; invalid.rules = [CorrectionRule(input: "bad", output: "тест" + control, russian: true)]; invalidConfigurations.append(invalid)
            invalid = configured; invalid.excludedWords = ["word" + control]; invalidConfigurations.append(invalid)
            invalid = configured; invalid.excludedApps = ["local.example" + control]; invalidConfigurations.append(invalid)
        }
        invalid = configured; invalid.excludedApps = ["local.example editor"]; invalidConfigurations.append(invalid)
        invalid = configured; invalid.rules = [CorrectionRule(input: "bad", output: String(repeating: "a", count: 129), russian: false)]; invalidConfigurations.append(invalid)
        for bad in invalidConfigurations {
            do { try store.save(bad); preconditionFailure("Invalid configuration committed") } catch { checks += 1 }
            expect(store.settings == configured && defaults.data(forKey: "localSettingsV1") == storedBefore,
                   "schema limits are enforced transactionally")
        }
        for bytes in [Data(), Data("{}".utf8), Data("null".utf8), Data("[]".utf8), Data("broken".utf8),
                      try encoder.encode(invalid), Data(repeating: 32, count: SettingsFile.maximumBytes + 1)] {
            try bytes.write(to: file)
            do { _ = try SettingsFile.read(file); preconditionFailure("Malformed/oversized settings accepted") } catch { checks += 1 }
            expect(store.settings == configured && defaults.data(forKey: "localSettingsV1") == storedBefore,
                   "bad import never mutates user configuration")
        }
        do { _ = try SettingsFile.read(root); preconditionFailure("Directory accepted as settings") } catch { checks += 1 }
        do { _ = try SettingsFile.read(URL(string: "https://invalid.example/settings.json")!); preconditionFailure("Remote settings accepted") } catch { checks += 1 }
        let validData = try encoder.encode(configured)
        var exactLimit = validData; exactLimit.append(Data(repeating: 32, count: SettingsFile.maximumBytes - validData.count))
        try exactLimit.write(to: file)
        expect(try SettingsFile.read(file) == configured, "exact file-size boundary accepts valid JSON")
        let settingsLink = root.appendingPathComponent("settings-link.json")
        try FileManager.default.createSymbolicLink(at: settingsLink, withDestinationURL: file)
        do { _ = try SettingsFile.read(settingsLink); preconditionFailure("Settings symlink accepted") } catch { checks += 1 }
        let pipeFile = root.appendingPathComponent("settings-pipe.json")
        expect(mkfifo(pipeFile.path, 0o600) == 0, "own disposable FIFO created")
        do { _ = try SettingsFile.read(pipeFile); preconditionFailure("FIFO accepted as settings") } catch { checks += 1 }

        let locks = root.appendingPathComponent("locks")
        var first = try ApplicationInstanceLease.acquire(in: locks)
        expect(first != nil, "first copy owns a kernel lease")
        try withExtendedLifetime(first) {
            expect(try ApplicationInstanceLease.acquire(in: locks) == nil, "second copy cannot attach another keyboard filter")
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--check-instance-lease", locks.path]
            try child.run(); child.waitUntilExit()
            expect(child.terminationStatus == 19, "another process cannot acquire the held lease")
        }
        first = nil
        var restarted = try ApplicationInstanceLease.acquire(in: locks)
        expect(restarted != nil, "lease is reusable after owner exit")
        restarted = nil
        let child = Process(), output = Pipe(), input = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--check-instance-lease", locks.path, "--hold-lease"]
        child.standardOutput = output; child.standardInput = input
        try child.run()
        expect(output.fileHandleForReading.readData(ofLength: 6) == Data("owned\n".utf8), "child reports acquired lease before crash test")
        expect(try ApplicationInstanceLease.acquire(in: locks) == nil, "independent child owns the lease")
        kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
        expect(child.terminationReason == .uncaughtSignal, "only the owned disposable child is terminated")
        let recovered = try ApplicationInstanceLease.acquire(in: locks)
        expect(recovered != nil, "kernel releases a crashed process lease automatically")
        try input.fileHandleForWriting.close(); try output.fileHandleForReading.close()
        let malicious = root.appendingPathComponent("symlink-lock")
        try FileManager.default.createDirectory(at: malicious, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: malicious.appendingPathComponent("instance.lock"), withDestinationURL: file)
        do { _ = try ApplicationInstanceLease.acquire(in: malicious); preconditionFailure("Symlink accepted as lock") } catch { checks += 1 }

        NSApplication.shared.setActivationPolicy(.prohibited)
        expect(LaunchAtLogin.state(for: .notFound) == .off, "first registration remains available when mainApp reports notFound")
        expect(LaunchAtLogin.state(for: .notRegistered) == .off, "unregistered login item is off")
        expect(LaunchAtLogin.state(for: .enabled) == .on, "only enabled login service is on")
        expect(LaunchAtLogin.state(for: .requiresApproval) == .needsApproval, "pending system approval is distinct from enabled")
        expect(LaunchAtLogin.shouldShowSettings(arguments: ["TrumpSwitcher"], event: nil), "ordinary launch opens settings")
        expect(!LaunchAtLogin.shouldShowSettings(arguments: ["TrumpSwitcher", "--background"], event: nil), "background launch leaves windows closed")
        for keyword in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication,
                                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyword)
            expect(!LaunchAtLogin.shouldShowSettings(arguments: ["TrumpSwitcher"], event: event), "system login launch leaves windows closed")
        }
        var failSave = false, permissionRequests = 0, resumes = 0
        var loginEnabled = false, loginChanges = 0, failLogin = false, loginSettingsOpened = 0
        var state: SettingsState = .ready
        let controller = SettingsController(settings: configured, changed: { next in
            if failSave { throw CocoaError(.coderInvalidValue) }
            try store.save(next)
        }, diagnostics: { "Fixed test metadata only" }, permission: { permissionRequests += 1 },
           state: { state }, resume: { resumes += 1; state = .ready },
           launchAtLogin: { loginEnabled ? .on : .off },
           setLaunchAtLogin: { enabled in
               loginChanges += 1
               if failLogin { throw CocoaError(.coderInvalidValue) }
               loginEnabled = enabled
           }, openLoginItems: { loginSettingsOpened += 1 })
        defer { controller.window?.close() }
        var visited = Set<ObjectIdentifier>()
        var views: [NSView] = []
        func visit(_ view: NSView) {
            guard visited.insert(ObjectIdentifier(view)).inserted else { return }
            views.append(view); view.subviews.forEach(visit)
            if let tabs = view as? NSTabView { tabs.tabViewItems.compactMap(\.view).forEach(visit) }
        }
        visit(controller.window!.contentView!)
        let buttons = views.compactMap { $0 as? NSButton }
        func button(_ action: String, tag: Int? = nil) -> NSButton {
            buttons.first { $0.action.map(NSStringFromSelector) == action && (tag == nil || $0.tag == tag) }!
        }
        func send(_ button: NSButton) { expect(NSApp.sendAction(button.action!, to: button.target, from: button), "own form action is connected") }
        func field(_ label: String) -> NSTextField {
            views.compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.accessibilityLabel() == label }!
        }
        let tables = views.compactMap { $0 as? NSTableView }
        expect(tables.count == 3, "all exclusion/rule lists constructed")
        let flagButtons = buttons.filter { $0.action.map(NSStringFromSelector) == "toggle:" }
        expect(Set(flagButtons.map(\.tag)) == Set(0...8), "every behavior option has its own native control")
        for control in flagButtons {
            let before = store.settings
            control.state = control.state == .on ? .off : .on; send(control)
            expect(store.settings != before, "behavior option commits")
            control.state = control.state == .on ? .off : .on; send(control)
            expect(store.settings == before, "behavior option restores without touching lists")
        }
        let login = button("toggleLaunchAtLogin:")
        expect(login.state == .off && !loginEnabled, "login switch reflects macOS state")
        login.state = .on; send(login)
        expect(loginEnabled && loginChanges == 1 && login.state == .on, "login switch enables system service")
        controller.refreshLaunchAtLogin()
        expect(login.state == .on, "login switch refreshes from system service")
        failLogin = true
        login.state = .off; send(login)
        expect(loginEnabled && login.state == .on, "failed login change restores actual system state")
        failLogin = false
        login.state = .off; send(login)
        expect(!loginEnabled && login.state == .off, "login switch disables system service")
        send(button("openLoginItemsAction"))
        expect(loginSettingsOpened == 1, "login settings link is connected")
        let beforeFailure = store.settings
        failSave = true
        let automatic = button("toggle:", tag: 0); let oldState = automatic.state
        automatic.state = oldState == .on ? .off : .on; send(automatic)
        expect(automatic.state == oldState && store.settings == beforeFailure, "failed commit restores control and saved settings")
        failSave = false
        let word = field("Слово, которое не нужно менять")
        word.stringValue = "  localword  "; send(button("addWord"))
        expect(store.settings.excludes("LOCALWORD") && word.stringValue.isEmpty, "word form trims, saves and clears")
        let wordCount = store.settings.excludedWords.count
        word.stringValue = "LOCALWORD"; send(button("addWord"))
        expect(store.settings.excludedWords.count == wordCount, "case-insensitive duplicate is refused")
        word.stringValue = "two words"; send(button("addWord"))
        expect(store.settings.excludedWords.count == wordCount, "multi-word exclusion refused")
        let wordTable = tables.first { $0.tableColumns.first?.identifier.rawValue == "word" }!
        wordTable.selectRowIndexes(IndexSet(integer: wordCount - 1), byExtendingSelection: false)
        send(button("remove:", tag: 0))
        expect(!store.settings.excludes("localword"), "selected exclusion removed without affecting other entries")
        let source = field("Если я набрал"), target = field("Заменять на")
        source.stringValue = "mytest"; target.stringValue = "привет"; send(button("saveRule"))
        expect(store.settings.rules.last?.output == "привет" && store.settings.rules.last?.russian == true,
               "new rule infers Russian and commits")
        let ruleTable = tables.first { $0.tableColumns.first?.identifier.rawValue == "input" }!
        let row = store.settings.rules.count - 1, id = store.settings.rules[row].id
        ruleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        expect(source.stringValue == "mytest" && target.stringValue == "привет", "selecting a rule populates its edit form")
        let language = views.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Язык текста замены" }!
        language.selectItem(at: 2)
        target.stringValue = "hello"; send(button("saveRule"))
        expect(store.settings.rules.last?.id == id && store.settings.rules.last?.output == "hello" && store.settings.rules.last?.russian == false,
               "editing updates original identity rather than adding a duplicate")
        source.stringValue = "mytest"; target.stringValue = "other"; send(button("saveRule"))
        expect(store.settings.rules.count == configured.rules.count + 1, "duplicate input rejected")
        ruleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        send(button("remove:", tag: 2))
        expect(store.settings.rules == configured.rules, "rule removal retains unrelated rules")
        let expectedStates: [(SettingsState, String)] = [(.ready,"Готов к работе"),(.disabled,"Автоматическое исправление выключено"),
            (.paused,"Исправления на паузе"),(.needsAccess,"Нужно разрешение macOS"),(.unavailable,"Исправление пока недоступно"),
            (.noDirection,"Не выбран язык исправления"),(.needsSettingsRecovery,"Не удалось загрузить сохранённые настройки")]
        for (next, text) in expectedStates {
            state = next; controller.synchronize(store.settings)
            expect(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(text) }, "status reflects actual mode")
        }
        state = .needsAccess; controller.synchronize(store.settings); send(button("stateAction"))
        expect(permissionRequests == 1, "permission action calls only the supplied handler")
        state = .paused; controller.synchronize(store.settings); send(button("stateAction"))
        expect(resumes == 1, "pause action calls resume handler")
        let customBeforeReset = store.settings
        send(button("recommended"))
        expect(store.settings.excludedWords == customBeforeReset.excludedWords && store.settings.excludedApps == customBeforeReset.excludedApps &&
               store.settings.rules == customBeforeReset.rules, "recommended mode preserves every user list")
        expect(controller.window?.isVisible == false, "settings checks never displayed a window")
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL {
            for (suffix, pixels) in [("",22),("@2x",44),("@3x",66)] {
                let data = try Data(contentsOf: resources.appendingPathComponent("TrumpMenuBar\(suffix).png"))
                let image = NSBitmapImageRep(data: data)!
                expect(image.pixelsWide == pixels && image.pixelsHigh == pixels && image.hasAlpha,
                       "packaged template icon has native resolution and alpha")
            }
            let icon = NSImage(contentsOf: resources.appendingPathComponent("TrumpAppIcon.icns"))
            expect(icon != nil && icon!.size.width > 0 && icon!.size.height > 0, "packaged application icon decodes")
        }
        print("Passed \(checks) application configuration checks; isolated preferences, files, lease and invisible settings forms; no external UI or posted events")
    }
}
