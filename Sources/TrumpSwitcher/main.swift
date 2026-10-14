import AppKit
import Carbon
import SwitcherCore
import LocalSafety

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var resultItem: NSMenuItem!
    private var paused = false
    private let access = TextAccess()
    private var window: NSWindow?
    private let browserAccessibility = BrowserAccessibilitySupport()
    private var preparedBrowserExclusions: [String]?
    private lazy var autoMonitor = AutoMonitor(browserAccessibility: browserAccessibility)
    private var autoItem: NSMenuItem!
    private var permissionTimer: Timer?
    private let preferences = PreferencesStore()
    private var settingsController: SettingsController?
    private var autoEnabled = true
    private var wasTrusted = false
    private var pauseItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var hotkeyRegistered = false
    private lazy var menuBarIcon: NSImage? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        for suffix in ["", "@2x", "@3x"] {
            guard let data = try? Data(contentsOf: resources.appendingPathComponent("TrumpMenuBar\(suffix).png")),
                  let representation = NSBitmapImageRep(data: data) else { return nil }
            representation.size = size
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        autoEnabled = preferences.settings.automatic
        applyLayoutPreferences(preferences.settings)
        autoMonitor.settings = preferences.settings
        access.settings = preferences.settings
        // The approved arrows fit a standard square menu-bar item.
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        status.button?.toolTip = "Trump Switcher · ⌃⌥Пробел"
        let menu = NSMenu()
        menu.delegate = self
        let title = NSMenuItem(title: "Trump Switcher · локально", action: nil, keyEquivalent: "")
        menu.addItem(title)
        resultItem = NSMenuItem(title: "Исправить: ⌃⌥Пробел", action: nil, keyEquivalent: "")
        menu.addItem(resultItem)
        menu.addItem(.separator())
        autoItem = NSMenuItem(title: "Исправлять автоматически", action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = autoEnabled ? .on : .off
        menu.addItem(autoItem)
        pauseItem = NSMenuItem(title: "Пауза", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self; menu.addItem(pauseItem)
        loginItem = NSMenuItem(title: "Запускать при входе в macOS", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self; menu.addItem(loginItem)
        refreshLoginItem()
        add(menu, "Разрешения macOS…", #selector(requestAccess))
        add(menu, "Настройки…", #selector(showSettings))
        add(menu, "Как пользоваться…", #selector(showHelp))
        menu.addItem(.separator())
        add(menu, "Завершить Trump Switcher", #selector(quit))
        status.menu = menu

        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x54524d50, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.convert()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = installed == noErr ? RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                           EventHotKeyID(signature: 0x54524d50, id: 1),
                                           GetApplicationEventTarget(), 0, &hotKey) : OSStatus(eventNotHandledErr)
        if registered != noErr, let handler {
            RemoveEventHandler(handler); self.handler = nil
        }
        hotkeyRegistered = installed == noErr && registered == noErr
        if installed != noErr || registered != noErr {
            resultItem.title = "Не удалось зарегистрировать ⌃⌥Пробел: сочетание занято."
            menu.insertItem(NSMenuItem(title: "Ручное сочетание ⌃⌥Пробел недоступно", action: nil, keyEquivalent: ""), at: 2)
        }
        autoMonitor.onResult = { [weak self] message in
            self?.resultItem.title = message
            self?.status.button?.toolTip = message
        }
        wasTrusted = AXIsProcessTrusted()
        refreshAuto()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.wasTrusted || (trusted && self.autoEnabled && !self.paused && !self.autoMonitor.running) { self.wasTrusted = trusted; self.refreshAuto() }
        }
        if LaunchAtLogin.shouldShowSettings(arguments: CommandLine.arguments,
                                           event: NSAppleEventManager.shared().currentAppleEvent) {
            showSettings()
        }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        switch LaunchAtLogin.state() {
        case .on:
            loginItem.title = "Запускать при входе в macOS"
            loginItem.state = .on; loginItem.isEnabled = true
        case .off:
            loginItem.title = "Запускать при входе в macOS"
            loginItem.state = .off; loginItem.isEnabled = true
        case .needsApproval:
            loginItem.title = "Автозапуск: подтвердить в macOS…"
            loginItem.state = .off; loginItem.isEnabled = true
        case .unavailable:
            loginItem.title = "Автозапуск недоступен"
            loginItem.state = .off; loginItem.isEnabled = false
        }
    }

    @objc private func toggleLaunchAtLogin() {
        if LaunchAtLogin.state() == .needsApproval {
            LaunchAtLogin.openSystemSettings()
            return
        }
        do {
            try LaunchAtLogin.setEnabled(LaunchAtLogin.state() != .on)
            refreshLoginItem()
            settingsController?.refreshLaunchAtLogin()
            if LaunchAtLogin.state() == .needsApproval { LaunchAtLogin.openSystemSettings() }
        } catch {
            refreshLoginItem()
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = "Проверьте разрешение в разделе «Объекты входа» macOS и повторите попытку."
            alert.addButton(withTitle: "Открыть настройки macOS")
            alert.addButton(withTitle: "Закрыть")
            if alert.runModal() == .alertFirstButtonReturn { LaunchAtLogin.openSystemSettings() }
        }
    }

    private func installApplicationMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Trump Switcher")
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить Trump Switcher", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        for (title, action, key) in [("Отменить", Selector(("undo:")), "z"),
                                    ("Вырезать", #selector(NSText.cut(_:)), "x"),
                                    ("Копировать", #selector(NSText.copy(_:)), "c"),
                                    ("Вставить", #selector(NSText.paste(_:)), "v"),
                                    ("Выбрать всё", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func convert() {
        guard !paused else { return }
        guard autoMonitor.prepareManualConversion() else {
            resultItem.title = "Дождитесь окончания ввода и повторите команду"
            status.button?.toolTip = resultItem.title
            NSSound.beep()
            return
        }
        do { resultItem.title = try access.convert(); updateIcon() }
        catch let failure as AccessFailure { resultItem.title = failure.message; updateIcon(); NSSound.beep() }
        catch { resultItem.title = "Операция не выполнена." }
        status.button?.toolTip = resultItem.title
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        paused.toggle()
        sender.state = paused ? .on : .off
        updateIcon()
        refreshAuto()
    }

    @objc private func toggleAuto() {
        autoEnabled.toggle()
        var next = preferences.settings; next.automatic = autoEnabled
        do { try preferences.save(next) } catch { autoEnabled = preferences.settings.automatic }
        autoMonitor.settings = preferences.settings
        access.settings = preferences.settings
        settingsController?.synchronize(preferences.settings)
        autoItem.state = autoEnabled ? .on : .off
        refreshAuto()
    }

    private func refreshAuto() {
        access.resetPolling()
        autoMonitor.stop()
        if AXIsProcessTrusted() {
            let excluded = preferences.settings.excludedApps
            if preparedBrowserExclusions != excluded {
                browserAccessibility.stop(); browserAccessibility.start(excluded: excluded)
                preparedBrowserExclusions = excluded
            }
        } else if preparedBrowserExclusions != nil {
            browserAccessibility.stop(); preparedBrowserExclusions = nil
        }
        if paused { resultItem.title = "Пауза · исправление отключено" }
        else if !autoEnabled { resultItem.title = "Ручной режим · ⌃⌥Пробел" }
        else if !access.dictionariesAvailable { resultItem.title = "Авто недоступно: нет словарей русского и английского" }
        else if autoMonitor.start() { resultItem.title = "Авто включено · слова и адреса" }
        else { resultItem.title = autoMonitor.lastError }
        updateIcon()
        status.button?.toolTip = resultItem.title
    }

    private func diagnosticsText() -> String {
        return "Версия: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") · сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev")\n\(autoMonitor.boundaryStatus)\nСеть: запрещена macOS · только локальные данные\nРаскладки: \(InputSources.sourceID(for: .russian) ?? "—") / \(InputSources.sourceID(for: .english) ?? "—")\nСловари: \(access.dictionaryStatus)\nДоступ: \(AXIsProcessTrusted() ? "есть" : "НЕТ") · Авто: \(autoMonitor.running ? "подключено" : "выключено") · События: \(autoMonitor.receivedEvents) · Пробелы: \(autoMonitor.receivedSpaces) · Клавиши: \(autoMonitor.receivedKeys)/\(autoMonitor.receivedCharacters)\n\(autoMonitor.contextStatus)\n\(autoMonitor.appStatus)\n\(autoMonitor.typingStatus) · \(autoMonitor.decisionStatus)\nОтправлено замен: \(autoMonitor.automaticCorrections) · \(autoMonitor.lastReplacement) · ожидание решения ≤ \(Int(autoMonitor.longestDecisionMS)) мс\nФильтр: ≤ \(Int(autoMonitor.longestCallbackMS)) мс · прерываний \(autoMonitor.interruptedTaps) · согласовано клавиш \(autoMonitor.reconciledKeys)\nФоновая проверка фокуса: ≤ \(Int(autoMonitor.longestFocusMS)) мс\n\(autoMonitor.reliabilityStatus)\nАктивно: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "—") · Горячая клавиша: \(hotkeyRegistered ? "зарегистрирована" : "ошибка") · Защищённый ввод: \(IsSecureEventInputEnabled() ? "да" : "нет")\n\(resultItem?.title ?? "")"
    }

    private func settingsState() -> SettingsState {
        if preferences.invalidSavedSettings { return .needsSettingsRecovery }
        if !autoEnabled { return .disabled }
        if paused { return .paused }
        if !AXIsProcessTrusted() { return .needsAccess }
        if !preferences.settings.toRussian && !preferences.settings.toEnglish { return .noDirection }
        if !access.dictionariesAvailable || !autoMonitor.running { return .unavailable }
        return .ready
    }

    private func resumeCorrections() {
        paused = false; pauseItem.state = .off; refreshAuto()
    }

    private func updateIcon() {
        if let image = menuBarIcon {
            status.button?.imageScaling = .scaleNone
            status.button?.imagePosition = .imageOnly
            status.button?.image = image; status.button?.title = ""
        } else { status.button?.title = "TS" }
        status.button?.alphaValue = paused || !autoEnabled ? 0.45 : 1
        status.button?.setAccessibilityLabel("Trump Switcher")
    }

    private func applyLayoutPreferences(_ settings: CorrectionSettings) {
        InputSources.setPreferences(russian: settings.preferredRussian, english: settings.preferredEnglish)
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsController(settings: preferences.settings, changed: { [weak self] next in
                guard let self else { return }
                try self.preferences.save(next)
                self.autoEnabled = next.automatic; self.autoItem.state = next.automatic ? .on : .off
                self.applyLayoutPreferences(next); self.autoMonitor.settings = next; self.access.settings = next; self.refreshAuto()
            }, diagnostics: { [weak self] in self?.diagnosticsText() ?? "" }, permission: { [weak self] in self?.requestAccess() },
               state: { [weak self] in self?.settingsState() ?? .unavailable }, resume: { [weak self] in self?.resumeCorrections() },
               launchAtLogin: { LaunchAtLogin.state() },
               setLaunchAtLogin: { [weak self] enabled in
                   try LaunchAtLogin.setEnabled(enabled)
                   self?.refreshLoginItem()
               }, openLoginItems: { LaunchAtLogin.openSystemSettings() })
        }
        settingsController?.showWindow(nil)
    }

    @objc private func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func showHelp() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 470),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Trump Switcher — как пользоваться"; panel.isReleasedWhenClosed = false
        let text = NSTextField(wrappingLabelWithString: "Набирайте текст как обычно\n\n1. В настройках включите «Исправлять ошибки раскладки автоматически». На главной странице появится состояние «Готов к работе».\n\n2. Наберите слово и нажмите пробел, Enter / Return или Tab. Enter и Tab можно включить на вкладке «Главная». Shift + Enter также поддерживается. Например: ghbdtn → привет, руддщ → hello, lkz → для. Однозначные знаки, например !, запускают исправление сразу. Если точка или запятая могут оказаться буквами ю или б, программа дождётся пробела, Enter или Tab.\n\n3. Если слово осталось неправильным, нажмите Control + Option + Пробел. Для часто повторяющейся ошибки добавьте запись в «Мои замены».\n\n4. Чтобы не менять отдельное слово или отключить исправления в приложении, добавьте его в «Не менять». Для временной остановки выберите «Пауза» в меню значка наверху.\n\nОбработка полностью локальная: программа не отправляет данные в интернет и не сохраняет историю набора. Сетевые подключения заблокированы. Пароли не исправляются. Если слово незнакомое или есть сомнения в замене, оно может остаться как есть.")
        text.font = .systemFont(ofSize: 14); text.frame = NSRect(x: 24, y: 66, width: 602, height: 376)
        panel.contentView?.addSubview(text)
        let button = NSButton(title: "Открыть настройки", target: self, action: #selector(showSettings))
        button.bezelStyle = .rounded; button.frame = NSRect(x: 24, y: 20, width: 260, height: 32)
        panel.contentView?.addSubview(button); panel.center(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); window = panel
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        autoMonitor.stop()
        browserAccessibility.stop()
        permissionTimer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

guard trump_deny_internet() == 0, trump_network_is_denied() == 1 else {
    if CommandLine.arguments.contains(where: { $0.hasPrefix("--check-") }) {
        fputs("Offline network restriction could not be established; startup refused.\n", stderr)
    } else {
        let alert = NSAlert(); alert.messageText = "Trump Switcher не запущен"
        alert.informativeText = "macOS не позволила установить запрет сетевых соединений. Для сохранения локального режима приложение остановлено."
        alert.runModal()
    }
    exit(1)
}
if CommandLine.arguments.contains("--check-offline") {
    print("IPv4/IPv6 TCP/UDP connections denied by macOS; checked only loopback, no external addresses")
    exit(0)
}
if CommandLine.arguments.contains("--check-keyboard-events") {
    var checks = 0
    let layouts = KeyboardLayouts()
    for (original, corrected, layout) in [("b", "и", Layout.russian), ("Ghbdtn", "Привет", .russian), ("руддщ", "hello", .english), ("yt!", "не!", .russian), ("нфтвучюкг", "yandex.ru", .english), ("гыук123@ьфшдюкг", "user123@mail.ru", .english), ("lkz", "для", .russian), ("d", "в", .russian), ("test", "ё.,?!:;№", .russian), ("test", "«привет»", .russian)] {
        guard let keys = KeyboardReplacement.keys(original: original, corrected: corrected, layout: layout, keyProvider: layouts.replacement),
              let events = AutoMonitor.events(for: keys), events.count == keys.count * 2 else { exit(1) }
        for (index, event) in events.enumerated() {
            let key = keys[index / 2]
            guard event.type == (index % 2 == 0 ? .keyDown : .keyUp),
                  event.getIntegerValueField(.keyboardEventKeycode) == Int64(key.code),
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  event.flags == (key.shift ? CGEventFlags.maskShift : []).union(key.option ? .maskAlternate : []).union(key.capsLock ? .maskAlphaShift : []),
                  event.getIntegerValueField(.eventSourceUserData) != 0 else {
                print("Unexpected event metadata", index, event.type.rawValue, event.getIntegerValueField(.keyboardEventKeycode), event.flags.rawValue)
                exit(1)
            }
            if let text = key.text {
                var units = [UniChar](repeating: 0, count: 8)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                guard String(utf16CodeUnits: units, count: length) == text else {
                    print("Unexpected generated Unicode", index, length, "expected", text)
                    exit(1)
                }
            }
            guard let cocoa = NSEvent(cgEvent: event) else { print("Cannot bridge generated event to AppKit"); exit(1) }
            if let text = key.text, layout == InputSources.currentLayout() || key.code == 49 {
                guard cocoa.characters == text else {
                    print("AppKit text differs for generated key", key.code, "expected", text, "actual", cocoa.characters ?? "nil")
                    exit(1)
                }
            } else if key.code == 51 {
                guard cocoa.characters == "\u{7f}" else {
                    print("AppKit Backspace is missing", Array((cocoa.characters ?? "").utf16))
                    exit(1)
                }
            }
            checks += 1
        }
    }
    print("Passed \(checks) native keyboard event checks; AppKit characters checked in active layout (no events posted)")
    exit(0)
}
if CommandLine.arguments.contains("--check-editor-replacements") {
    _ = EditorReplacementChecks.run()
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--check-preferences-suite") {
    guard index + 1 < CommandLine.arguments.count else { exit(2) }
    let suite = CommandLine.arguments[index + 1], prefix = "local.trumpswitcher.checks."
    guard suite.hasPrefix(prefix), UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil,
          let defaults = UserDefaults(suiteName: suite),
          let data = try? JSONEncoder().encode(PreferencesStore(defaults: defaults).settings) else { exit(2) }
    FileHandle.standardOutput.write(data); exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--check-instance-lease") {
    guard index + 1 < CommandLine.arguments.count, CommandLine.arguments[index + 1].hasPrefix("/") else { exit(2) }
    do {
        guard let lease = try ApplicationInstanceLease.acquire(in: URL(fileURLWithPath: CommandLine.arguments[index + 1])) else { exit(19) }
        withExtendedLifetime(lease) {
            if CommandLine.arguments.contains("--hold-lease") {
                print("owned"); fflush(stdout)
                var byte: UInt8 = 0
                _ = read(STDIN_FILENO, &byte, 1)
            }
        }
        exit(0)
    } catch { exit(1) }
}
if CommandLine.arguments.contains("--check-application-configuration") {
    do { try ApplicationConfigurationChecks.run(); exit(0) }
    catch { fputs("Application configuration checks failed: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.contains("--check-dictionaries") {
    let dictionary = LocalDictionary(includeSystem: false)
    let addresses = AddressRecognizer(directory: dictionary.resourceDirectory)
    print("Bundled dictionaries:", dictionary.status)
    guard dictionary.bundledAvailable,
          dictionary.frequencyCounts.russian == 50000, dictionary.frequencyCounts.english == 30000, addresses.available else { exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--diagnostics") {
    _ = NSApplication.shared
    print("Build:", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev")
    print("Accessibility:", AXIsProcessTrusted())
    print("Launch at login:", LaunchAtLogin.state())
    print("Dictionaries:", LocalDictionary().status)
    exit(0)
}
// Reject removed developer modes while leaving standard Cocoa/LaunchServices
// single-dash arguments (and their values) to AppKit.
guard !CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") && $0 != "--background" }) else {
    fputs("Unsupported command. Use --background for a background launch.\n", stderr)
    exit(2)
}
let app = NSApplication.shared
// Also refuse a second copy of an older build which did not yet hold a lease.
if NSRunningApplication.runningApplications(withBundleIdentifier: "local.trumpswitcher.mac")
    .contains(where: {
        guard $0.processIdentifier != getpid(), !$0.isTerminated, let url = $0.bundleURL else { return false }
        let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return (version.flatMap(Int.init) ?? 0) < 66
    }) { exit(0) }
let instanceLease: ApplicationInstanceLease
do {
    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true).appendingPathComponent("Trump Switcher")
    guard let lease = try ApplicationInstanceLease.acquire(in: directory) else { exit(0) }
    instanceLease = lease
} catch {
    let alert = NSAlert(); alert.messageText = "Trump Switcher не запущен"
    alert.informativeText = "Не удалось создать локальный файл защиты от повторного запуска. Проверьте доступ к папке Application Support."
    alert.runModal(); exit(1)
}
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(instanceLease) { app.run() }
