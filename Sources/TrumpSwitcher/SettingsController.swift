import AppKit
import UniformTypeIdentifiers
import SwitcherCore

enum SettingsState {
    case ready, disabled, paused, needsAccess, needsLayouts, unavailable, noDirection, needsSettingsRecovery
}

final class SettingsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTabViewDelegate {
    private var settings: CorrectionSettings
    private let changed: (CorrectionSettings) throws -> Void
    private let diagnostics: () -> String
    private let permission: () -> Void
    private let state: () -> SettingsState
    private let resume: () -> Void
    private let launchAtLogin: () -> LaunchAtLoginState
    private let setLaunchAtLogin: (Bool) throws -> Void
    private let openLoginItems: () -> Void
    private let loginControl = NSButton()
    private let loginDetail = NSTextField(wrappingLabelWithString: "")
    private let loginApprovalButton = NSButton()
    private let tables = [NSTableView(), NSTableView(), NSTableView()]
    private var controls: [Int: NSButton] = [:]
    private var removeButtons: [Int: NSButton] = [:]
    private var emptyLabels: [Int: NSTextField] = [:]
    private let wordField = NSTextField()
    private let sourceField = NSTextField()
    private let targetField = NSTextField()
    private let targetLayout = NSPopUpButton()
    private let russianLayout = NSPopUpButton()
    private let englishLayout = NSPopUpButton()
    private var editingRule: UUID?
    private var editingLanguage: Bool?
    private var appNames: [String: String] = [:]
    private let saveRuleButton = NSButton()
    private let message = NSTextField(wrappingLabelWithString: "Изменения сохраняются автоматически на этом Mac.")
    private let stateTitle = NSTextField(labelWithString: "")
    private let stateDetail = NSTextField(wrappingLabelWithString: "")
    private let stateButton = NSButton()
    private let diagnostic = NSTextView(frame: .zero)
    private var diagnosticWindow: NSWindow?
    private let tabs = NSTabView()
    private let advancedTabs = NSTabView()
    private var sectionButtons: [NSButton] = []
    private var advancedButtons: [NSButton] = []
    private var timer: Timer?

    init(settings: CorrectionSettings, changed: @escaping (CorrectionSettings) throws -> Void,
         diagnostics: @escaping () -> String, permission: @escaping () -> Void,
         state: @escaping () -> SettingsState, resume: @escaping () -> Void,
         launchAtLogin: @escaping () -> LaunchAtLoginState,
         setLaunchAtLogin: @escaping (Bool) throws -> Void,
         openLoginItems: @escaping () -> Void) {
        self.settings = settings; self.changed = changed; self.diagnostics = diagnostics
        self.permission = permission; self.state = state; self.resume = resume
        self.launchAtLogin = launchAtLogin; self.setLaunchAtLogin = setLaunchAtLogin
        self.openLoginItems = openLoginItems
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Trump Switcher — настройки"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = window.contentView!
        let icon = NSImageView(frame: NSRect(x: 28, y: 650, width: 64, height: 64))
        if let url = Bundle.main.url(forResource: "TrumpAppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: url)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Значок Trump Switcher")
        content.addSubview(icon)
        label("Trump Switcher", content, x: 108, y: 681, w: 700, h: 30, bold: true, size: 23)
        label("Настройки исправления раскладки", content, x: 108, y: 655, w: 700, h: 24, size: 14)
        // Keep text in native controls at integral coordinates, without the
        // small embossed labels of NSTabView's legacy tab bezel.
        tabs.tabViewType = .noTabsNoBorder
        tabs.delegate = self
        tabs.frame = NSRect(x: 28, y: 62, width: 824, height: 540)
        window.contentView?.addSubview(tabs)
        sectionButtons = navigation(["Главная", "Не менять", "Мои замены", "Дополнительно"],
                                    in: content, x: 28, y: 610, width: 824,
                                    action: #selector(selectSection))
        message.frame = NSRect(x: 28, y: 12, width: 824, height: 36)
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        window.contentView?.addSubview(message)
        makeGeneral(); makeExclusions(); makeRules(); makeAdvanced()
        synchronize(settings)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func navigation(_ titles: [String], in view: NSView, x: CGFloat, y: CGFloat,
                            width: CGFloat, action: Selector) -> [NSButton] {
        let gap: CGFloat = 8
        let itemWidth = floor((width - gap * CGFloat(titles.count - 1)) / CGFloat(titles.count))
        return titles.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: action)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 14, weight: .medium)
            button.tag = index
            button.state = index == 0 ? .on : .off
            button.frame = NSRect(x: x + CGFloat(index) * (itemWidth + gap), y: y,
                                  width: itemWidth, height: 36)
            button.setAccessibilityLabel(title)
            view.addSubview(button)
            return button
        }
    }
    @objc private func selectSection(_ sender: NSButton) {
        tabs.selectTabViewItem(at: sender.tag)
        updateNavigation(tabs)
    }
    @objc private func selectAdvancedSection(_ sender: NSButton) {
        advancedTabs.selectTabViewItem(at: sender.tag)
        updateNavigation(advancedTabs)
    }
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateNavigation(tabView)
    }
    private func updateNavigation(_ tabView: NSTabView) {
        guard let selected = tabView.selectedTabViewItem else { return }
        let index = tabView.indexOfTabViewItem(selected)
        let buttons = tabView === tabs ? sectionButtons : advancedButtons
        for button in buttons { button.state = button.tag == index ? .on : .off }
    }
    private func tab(_ name: String, in tabView: NSTabView? = nil) -> NSView {
        let item = NSTabViewItem(identifier: name); item.label = name
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 540))
        item.view = view; (tabView ?? tabs).addTabViewItem(item); return view
    }
    @discardableResult private func label(_ text: String, _ view: NSView, x: CGFloat = 22, y: CGFloat,
        w: CGFloat = 774, h: CGFloat = 42, bold: Bool = false, size: CGFloat = 13) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        label.frame = NSRect(x: x, y: y, width: w, height: h); view.addSubview(label)
        return label
    }
    @discardableResult private func button(_ title: String, _ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat,
                        action: Selector, tag: Int = 0) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded; button.tag = tag
        button.frame = NSRect(x: x, y: y, width: width, height: 32); view.addSubview(button)
        return button
    }
    private func field(_ field: NSTextField, _ placeholder: String, _ name: String, _ view: NSView,
                       x: CGFloat, y: CGFloat, w: CGFloat) {
        field.placeholderString = placeholder; field.setAccessibilityLabel(name)
        field.frame = NSRect(x: x, y: y, width: w, height: 30); view.addSubview(field)
    }
    private func checkbox(_ title: String, tag: Int, _ view: NSView, y: CGFloat) {
        let control = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggle))
        control.controlSize = .regular
        control.font = .systemFont(ofSize: 14)
        control.tag = tag; control.frame = NSRect(x: 22, y: y, width: 760, height: 28)
        controls[tag] = control; view.addSubview(control)
    }
    private func makeGeneral() {
        let view = tab("Главная")
        label("Пишите, не думая о раскладке", view, y: 494, h: 34, bold: true, size: 24)
        label("Программа исправляет слова, случайно набранные на другом языке.", view, y: 460, h: 28, size: 15)

        let privacy = NSBox(frame: NSRect(x: 22, y: 364, width: 774, height: 84))
        privacy.titlePosition = .noTitle; privacy.boxType = .custom; privacy.cornerRadius = 10
        privacy.fillColor = NSColor.systemGreen.withAlphaComponent(0.07)
        privacy.borderColor = NSColor.systemGreen.withAlphaComponent(0.3); privacy.borderWidth = 1
        view.addSubview(privacy)
        if let content = privacy.contentView {
            let shield = NSImageView(frame: NSRect(x: 12, y: 18, width: 36, height: 42))
            shield.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Локальная обработка")?
                .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
            shield.imageScaling = .scaleProportionallyUpOrDown
            shield.contentTintColor = .systemGreen; content.addSubview(shield)
            label("Ваш текст остаётся на вашем Mac", content, x: 60, y: 48, w: 680, h: 24, bold: true, size: 16)
            label("Обработка полностью локальная. Данные никуда не отправляются, история набора не сохраняется. Сетевые подключения Trump Switcher заблокированы.", content, x: 60, y: 6, w: 680, h: 40)
        }
        checkbox("Исправлять ошибки раскладки автоматически", tag: 0, view, y: 323)
        controls[0]?.font = .boldSystemFont(ofSize: 16)
        label("Исправлять по пробелу, а также по этим клавишам:", view, y: 293, h: 24)
        checkbox("Enter / Return — клавиша ввода", tag: 6, view, y: 261)
        controls[6]?.frame.size.width = 365
        controls[6]?.toolTip = "Исправить слово перед переносом строки или отправкой сообщения. Работает и с Shift + Enter."
        checkbox("Tab — перед переходом в другое поле", tag: 7, view, y: 261)
        controls[7]?.frame = NSRect(x: 410, y: 261, width: 386, height: 28)

        let box = NSBox(frame: NSRect(x: 22, y: 132, width: 774, height: 116))
        box.titlePosition = .noTitle; box.boxType = .custom; box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor; box.borderColor = .separatorColor; box.borderWidth = 1
        view.addSubview(box)
        stateTitle.font = .boldSystemFont(ofSize: 17)
        stateTitle.frame = NSRect(x: 18, y: 75, width: 726, height: 25)
        stateDetail.font = .systemFont(ofSize: 13)
        stateDetail.frame = NSRect(x: 18, y: 32, width: 726, height: 40)
        stateButton.bezelStyle = .rounded; stateButton.target = self; stateButton.action = #selector(stateAction)
        stateButton.frame = NSRect(x: 12, y: 0, width: 300, height: 32)
        box.contentView?.addSubview(stateTitle); box.contentView?.addSubview(stateDetail); box.contentView?.addSubview(stateButton)
        label("Как пользоваться", view, y: 99, h: 26, bold: true, size: 16)
        label("Наберите слово и нажмите пробел или включённую выше клавишу.", view, y: 74, h: 24)
        label("ghbdtn → привет     руддщ → hello     lkz → для", view, y: 45, h: 28, bold: true, size: 16)
        label("Слово осталось неправильным? Нажмите Control + Option + Пробел.\nЧтобы остановить исправления, выберите «Пауза» в меню значка наверху.", view, y: 1, h: 40)
    }
    private func list(_ index: Int, _ view: NSView, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                      columns: [(String, String, CGFloat)], empty: String) {
        let table = tables[index]
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 30
        table.allowsMultipleSelection = false
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.isEditable = false
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: NSRect(x: x, y: y, width: w, height: h))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        view.addSubview(scroll)
        let hint = label(empty, view, x: x + 16, y: y + h / 2 - 25, w: w - 32, h: 64)
        hint.alignment = .center; hint.textColor = .secondaryLabelColor; emptyLabels[index] = hint
    }
    private func makeExclusions() {
        let view = tab("Не менять")
        label("Где исправления не нужны", view, y: 482, h: 34, bold: true, size: 22)
        label("Добавьте слова, которые нужно оставлять как есть, или приложения, в которых вам не нужна замена.", view, y: 434, h: 42)
        list(0, view, x: 22, y: 148, w: 375, h: 270, columns: [("word", "Не менять эти слова и адреса", 348)],
             empty: "Пока здесь пусто.\nМожно добавить имя, сокращение или адрес.")
        list(1, view, x: 421, y: 148, w: 375, h: 270, columns: [("app", "Не исправлять в этих приложениях", 348)],
             empty: "Приложения пока не добавлены.\nВыберите нужное кнопкой ниже.")
        field(wordField, "Например: git", "Слово, которое не нужно менять", view, x: 22, y: 104, w: 245)
        button("Добавить слово", view, x: 273, y: 103, width: 124, action: #selector(addWord))
        removeButtons[0] = button("Убрать из списка", view, x: 22, y: 60, width: 190, action: #selector(remove), tag: 0)
        button("Выбрать приложение…", view, x: 421, y: 103, width: 230, action: #selector(chooseApp))
        removeButtons[1] = button("Убрать из списка", view, x: 421, y: 60, width: 190, action: #selector(remove), tag: 1)
        label("Список учитывает набранное слово и результат исправления. Регистр не важен.\nПароли не исправляются.", view, y: 10, h: 36)
    }
    private func makeRules() {
        let view = tab("Мои замены")
        label("Научите программу своим заменам", view, y: 482, h: 34, bold: true, size: 22)
        label("Если слово часто остаётся неправильным, добавьте его здесь. Замена сработает по триггерам, включённым на вкладке «Главная».\nНапример: «lkz» заменять на «для». Чтобы изменить запись, выберите её в списке.", view, y: 414, h: 62)
        list(2, view, x: 22, y: 231, w: 774, h: 177,
             columns: [("input", "Если я набрал", 330), ("output", "Заменять на", 410)],
             empty: "Ваших замен пока нет.\nДобавьте первую с помощью полей ниже.")
        label("Если я набрал", view, y: 195, w: 330, h: 24, bold: true)
        label("Заменять на", view, x: 421, y: 195, w: 375, h: 24, bold: true)
        field(sourceField, "Например: lkz", "Если я набрал", view, x: 22, y: 160, w: 375)
        field(targetField, "Например: для", "Заменять на", view, x: 421, y: 160, w: 375)
        label("Язык текста замены", view, y: 117, w: 175, h: 26)
        targetLayout.addItems(withTitles: ["Определять по тексту", "Русский", "Английский"])
        targetLayout.setAccessibilityLabel("Язык текста замены")
        targetLayout.frame = NSRect(x: 195, y: 117, width: 225, height: 28); view.addSubview(targetLayout)
        saveRuleButton.title = "Добавить замену"; saveRuleButton.bezelStyle = .rounded
        saveRuleButton.target = self; saveRuleButton.action = #selector(saveRule)
        saveRuleButton.frame = NSRect(x: 22, y: 67, width: 225, height: 32); view.addSubview(saveRuleButton)
        button("Очистить поля", view, x: 263, y: 67, width: 180, action: #selector(newRule))
        removeButtons[2] = button("Удалить замену", view, x: 610, y: 67, width: 186, action: #selector(remove), tag: 2)
        label("В левом поле — одно слово без пробелов. В правом можно написать фразу.\nБольшие и маленькие буквы учитываются: «lkz» и «LKZ» — разные записи.", view, y: 4, h: 54)
    }
    private func makeAdvanced() {
        let view = tab("Дополнительно")
        label("Здесь можно настроить детали", view, y: 482, h: 34, bold: true, size: 22)
        label("Обычно менять эти параметры не нужно. Они пригодятся, если вам нужен особый режим работы.", view, y: 435, h: 38)
        advancedTabs.tabViewType = .noTabsNoBorder
        advancedTabs.delegate = self
        advancedTabs.frame = NSRect(x: 12, y: 8, width: 794, height: 390)
        view.addSubview(advancedTabs)
        advancedButtons = navigation(["Что исправлять", "Клавиатура", "Помощь и сохранение"],
                                     in: view, x: 22, y: 400, width: 774,
                                     action: #selector(selectAdvancedSection))
        let behavior = tab("Что исправлять", in: advancedTabs)
        let options = [(1, "Ошибки вроде ghbdtn → привет"), (2, "Ошибки вроде руддщ → hello"),
            (3, "Короткие слова: и, в, не, для"), (4, "Слова в кавычках, скобках и со знаками препинания"),
            (5, "Адреса сайтов и электронной почты"), (8, "Слова, набранные БОЛЬШИМИ БУКВАМИ")]
        for (index, option) in options.enumerated() { checkbox(option.1, tag: option.0, behavior, y: 340 - CGFloat(index) * 35) }
        loginControl.setButtonType(.switch)
        loginControl.title = "Запускать Trump Switcher при входе в macOS"
        loginControl.font = .systemFont(ofSize: 14)
        loginControl.target = self; loginControl.action = #selector(toggleLaunchAtLogin)
        loginControl.frame = NSRect(x: 22, y: 105, width: 630, height: 28)
        behavior.addSubview(loginControl)
        loginDetail.font = .systemFont(ofSize: 12)
        loginDetail.textColor = .secondaryLabelColor
        loginDetail.frame = NSRect(x: 44, y: 73, width: 690, height: 29)
        behavior.addSubview(loginDetail)
        loginApprovalButton.title = "Открыть объекты входа macOS…"
        loginApprovalButton.bezelStyle = .rounded
        loginApprovalButton.target = self; loginApprovalButton.action = #selector(openLoginItemsAction)
        loginApprovalButton.frame = NSRect(x: 375, y: 20, width: 340, height: 32)
        behavior.addSubview(loginApprovalButton)
        button("Вернуть обычный режим", behavior, x: 22, y: 22, width: 255, action: #selector(recommended))
        // The launch item is managed by macOS and stays independent of the correction profile.
        let keyboard = tab("Клавиатура", in: advancedTabs)
        label("Резервные раскладки", keyboard, y: 326, h: 30, bold: true, size: 17)
        label("Программа запоминает выбранные вами русскую и английскую раскладки.\nЭти варианты нужны только тогда, когда подходящая раскладка ещё не запомнена.", keyboard, y: 250, w: 722, h: 64)
        label("Русский язык", keyboard, y: 209, w: 340, h: 24)
        label("Английский язык", keyboard, x: 398, y: 209, w: 340, h: 24)
        russianLayout.addItems(withTitles: ["Русская (стандартная Mac)", "Русская — PC", "Русская — фонетическая"])
        englishLayout.addItems(withTitles: ["ABC (стандартная Mac)", "США"])
        russianLayout.target = self; russianLayout.action = #selector(layoutChanged)
        englishLayout.target = self; englishLayout.action = #selector(layoutChanged)
        russianLayout.frame = NSRect(x: 22, y: 174, width: 345, height: 28)
        englishLayout.frame = NSRect(x: 398, y: 174, width: 345, height: 28)
        keyboard.addSubview(russianLayout); keyboard.addSubview(englishLayout)
        label("Выбранные раскладки должны быть добавлены в настройках клавиатуры macOS.\nЕсли вы не знаете, какой вариант выбрать, оставьте текущие значения.", keyboard, y: 76, w: 722, h: 72)
        let help = tab("Помощь и сохранение", in: advancedTabs)
        label("Если исправления не работают", help, y: 328, h: 30, bold: true, size: 17)
        label("1. На вкладке «Главная» включите автоматическое исправление.\n2. Уберите «Паузу» в меню значка программы.\n3. Нажмите «Открыть разрешения macOS» и включите доступ для Trump Switcher.\n4. Проверьте, что слово или приложение не добавлено в «Не менять».", help, y: 218, w: 722, h: 102)
        button("Открыть разрешения macOS…", help, x: 22, y: 171, width: 295, action: #selector(openPermission))
        button("Техническая информация…", help, x: 337, y: 171, width: 295, action: #selector(showDiagnostics))
        label("Сохранить мои настройки в файл", help, y: 121, h: 28, bold: true, size: 16)
        label("Файл содержит ваши параметры, списки и замены. Он остаётся на вашем Mac.\nЗагрузка заменит текущие настройки содержимым выбранного файла.", help, y: 63, w: 722, h: 52)
        button("Сохранить в файл…", help, x: 22, y: 19, width: 255, action: #selector(exportSettings))
        button("Загрузить из файла…", help, x: 297, y: 19, width: 255, action: #selector(importSettings))
    }
    func synchronize(_ settings: CorrectionSettings) {
        self.settings = settings
        let flags = [settings.automatic, settings.toRussian, settings.toEnglish, settings.shortWords, settings.punctuation,
                     settings.addresses, settings.onEnter, settings.onTab, settings.allowAllCaps]
        for (i, flag) in flags.enumerated() { controls[i]?.state = flag ? .on : .off }
        russianLayout.selectItem(at: InputSources.russianIDs.firstIndex(of: settings.preferredRussian) ?? 0)
        englishLayout.selectItem(at: InputSources.englishIDs.firstIndex(of: settings.preferredEnglish) ?? 0)
        tables.forEach { $0.reloadData() }; updateLists(); updateState()
        refreshLaunchAtLogin()
    }
    func refreshLaunchAtLogin() {
        switch launchAtLogin() {
        case .on:
            loginControl.state = .on; loginControl.isEnabled = true
            loginDetail.stringValue = "Программа будет запускаться после входа в вашу учётную запись."
            loginApprovalButton.isHidden = true
        case .off:
            loginControl.state = .off; loginControl.isEnabled = true
            loginDetail.stringValue = "Включите, если хотите запускать программу вместе с Mac."
            loginApprovalButton.isHidden = true
        case .needsApproval:
            loginControl.state = .off; loginControl.isEnabled = true
            loginDetail.stringValue = "macOS ждёт вашего разрешения на автозапуск."
            loginApprovalButton.isHidden = false
        case .unavailable:
            loginControl.state = .off; loginControl.isEnabled = false
            loginDetail.stringValue = "Автозапуск недоступен. Запустите установленную программу из папки «Программы»."
            loginApprovalButton.isHidden = true
        }
    }
    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        if launchAtLogin() == .needsApproval {
            refreshLaunchAtLogin(); openLoginItems(); return
        }
        do {
            try setLaunchAtLogin(sender.state == .on)
            refreshLaunchAtLogin()
            message.stringValue = launchAtLogin() == .needsApproval
                ? "Подтвердите автозапуск в настройках macOS."
                : "Настройка автозапуска обновлена."
            message.textColor = .secondaryLabelColor
        } catch {
            refreshLaunchAtLogin()
            self.error("Не удалось изменить автозапуск. Проверьте «Объекты входа» macOS.")
        }
    }
    @objc private func openLoginItemsAction() { openLoginItems() }
    private func updateLists() {
        for index in 0..<3 {
            emptyLabels[index]?.isHidden = numberOfRows(in: tables[index]) != 0
            removeButtons[index]?.isEnabled = tables[index].selectedRow >= 0 && tables[index].selectedRow < numberOfRows(in: tables[index])
        }
    }
    private func updateState() {
        stateButton.isHidden = true; stateTitle.textColor = .labelColor
        switch state() {
        case .ready:
            stateTitle.stringValue = "● Готов к работе"; stateTitle.textColor = .systemGreen
            var triggers = ["пробел"]
            if settings.onEnter { triggers.append("Enter / Return (включая Shift + Enter)") }
            if settings.onTab { triggers.append("Tab") }
            let punctuation = settings.punctuation
                ? " Знаки вроде ! запускают замену сразу; неоднозначные точки и запятые — при завершении слова."
                : " Исправление слов со знаками препинания отключено в дополнительных настройках."
            stateDetail.stringValue = "Исправление: " + triggers.joined(separator: ", ") + "." + punctuation
        case .disabled:
            stateTitle.stringValue = "Автоматическое исправление выключено"
            stateDetail.stringValue = "Включите переключатель выше. Ручная замена доступна по сочетанию Control + Option + Пробел."
        case .paused:
            stateTitle.stringValue = "Исправления на паузе"
            stateDetail.stringValue = "Чтобы снова исправлять слова во время набора, продолжите работу."
            stateButton.title = "Продолжить исправление"; stateButton.isHidden = false
        case .needsAccess:
            stateTitle.stringValue = "Нужно разрешение macOS"; stateTitle.textColor = .systemOrange
            stateDetail.stringValue = "Откройте разрешения macOS и включите доступ для Trump Switcher. Вернитесь сюда — программа проверит разрешение сама."
            stateButton.title = "Разрешить работу в macOS…"; stateButton.isHidden = false
        case .unavailable:
            stateTitle.stringValue = "Исправление пока недоступно"; stateTitle.textColor = .systemOrange
            stateDetail.stringValue = "Проверьте разрешение macOS. Если оно уже включено, закройте и снова запустите программу. Подсказки есть в разделе помощи."
            stateButton.title = "Открыть помощь"; stateButton.isHidden = false
        case .needsLayouts:
            stateTitle.stringValue = "Добавьте русскую и английскую раскладки"; stateTitle.textColor = .systemOrange
            stateDetail.stringValue = "В macOS → Клавиатура → Ввод текста добавьте «Русская», «Русская — ПК» или «Русская — фонетическая», а также ABC или «США». Переключатель подключится автоматически."
            stateButton.title = "Открыть настройки клавиатуры…"; stateButton.isHidden = false
        case .noDirection:
            stateTitle.stringValue = "Не выбран язык исправления"; stateTitle.textColor = .systemOrange
            stateDetail.stringValue = "В дополнительных настройках отключены оба языка. Включите хотя бы один или верните обычный режим."
            stateButton.title = "Выбрать, что исправлять"; stateButton.isHidden = false
        case .needsSettingsRecovery:
            stateTitle.stringValue = "Не удалось загрузить сохранённые настройки"; stateTitle.textColor = .systemOrange
            stateDetail.stringValue = "Автоисправление выключено. Исходные данные сохранены. Загрузите ваш файл настроек или настройте программу заново."
            stateButton.title = "Открыть сохранение настроек"; stateButton.isHidden = false
        }
        if diagnosticWindow?.isVisible == true { diagnostic.string = diagnostics() }
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); NSApp.activate(ignoringOtherApps: true); updateState(); refreshLaunchAtLogin()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true || self.diagnosticWindow?.isVisible == true else { return }
            self.updateState()
            self.refreshLaunchAtLogin()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === tables[0] { return settings.excludedWords.count }
        if tableView === tables[1] { return settings.excludedApps.count }
        return settings.rules.count
    }
    private func appName(_ id: String) -> String {
        if let cached = appNames[id] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
        } else { name = (id.components(separatedBy: ".").last ?? id) + " (не найдено на Mac)" }
        appNames[id] = name; return name
    }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView === tables[0] { return settings.excludedWords[row] }
        if tableView === tables[1] { return appName(settings.excludedApps[row]) }
        let rule = settings.rules[row]
        return tableColumn?.identifier.rawValue == "input" ? rule.input : rule.output
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateLists()
        guard let table = notification.object as? NSTableView, table === tables[2], table.selectedRow >= 0,
              table.selectedRow < settings.rules.count else { return }
        let rule = settings.rules[table.selectedRow]
        editingRule = rule.id; editingLanguage = rule.russian
        sourceField.stringValue = rule.input; targetField.stringValue = rule.output
        // Keep the stored choice when editing; new entries infer their language by default.
        targetLayout.selectItem(at: rule.russian ? 1 : 2); saveRuleButton.title = "Сохранить изменения"
    }
    @discardableResult private func commit(_ next: CorrectionSettings, _ success: String = "Готово. Настройки сохранены.") -> Bool {
        do { try changed(next); synchronize(next); message.stringValue = success; message.textColor = .secondaryLabelColor; return true }
        catch { synchronize(settings); self.error("Не удалось сохранить изменения. Попробуйте ещё раз."); return false }
    }
    private func error(_ text: String) { message.stringValue = text; message.textColor = .systemRed }
    @objc private func stateAction() {
        switch state() {
        case .needsAccess: permission()
        case .needsLayouts:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .paused: resume(); updateState()
        case .noDirection: tabs.selectTabViewItem(at: 3); advancedTabs.selectTabViewItem(at: 0)
        default: tabs.selectTabViewItem(at: 3); advancedTabs.selectTabViewItem(at: 2)
        }
    }
    @objc private func toggle(_ sender: NSButton) {
        var next = settings; let value = sender.state == .on
        switch sender.tag {
        case 0: next.automatic = value
        case 1: next.toRussian = value
        case 2: next.toEnglish = value
        case 3: next.shortWords = value
        case 4: next.punctuation = value
        case 5: next.addresses = value
        case 6: next.onEnter = value
        case 7: next.onTab = value
        default: next.allowAllCaps = value
        }
        commit(next)
    }
    @objc private func recommended() {
        var next = settings; let defaults = CorrectionSettings()
        next.automatic = defaults.automatic; next.toRussian = defaults.toRussian; next.toEnglish = defaults.toEnglish
        next.shortWords = defaults.shortWords; next.punctuation = defaults.punctuation; next.addresses = defaults.addresses
        next.onEnter = defaults.onEnter; next.onTab = defaults.onTab; next.allowAllCaps = defaults.allowAllCaps
        if commit(next, "Обычный режим включён. Ваши списки и замены сохранены.") { resume(); updateState() }
    }
    @objc private func layoutChanged() {
        guard InputSources.russianIDs.indices.contains(russianLayout.indexOfSelectedItem),
              InputSources.englishIDs.indices.contains(englishLayout.indexOfSelectedItem) else {
            error("Выберите русскую и английскую раскладки в списках."); return
        }
        var next = settings
        next.preferredRussian = InputSources.russianIDs[russianLayout.indexOfSelectedItem]
        next.preferredEnglish = InputSources.englishIDs[englishLayout.indexOfSelectedItem]
        commit(next)
    }
    @objc private func addWord() {
        let word = wordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.utf16.count <= 128, !word.contains(where: \.isWhitespace) else { error("Напишите одно слово или адрес без пробелов (не больше 128 символов)."); return }
        guard !word.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            error("Введите слово заново: в тексте есть невидимые служебные символы."); return
        }
        guard !settings.excludes(word) else { error("Это слово уже есть в списке — добавлять его снова не нужно."); return }
        var next = settings; next.excludedWords.append(word)
        if commit(next, "Добавлено. Это слово больше не будет исправляться.") { wordField.stringValue = "" }
    }
    @objc private func chooseApp() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        panel.title = "В каком приложении не нужны исправления?"
        panel.prompt = "Не исправлять здесь"; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let id = Bundle(url: url)?.bundleIdentifier else { self.error("Не удалось добавить это приложение. Выберите другой файл приложения."); return }
            guard !self.settings.excludesApp(id) else { self.error("Это приложение уже есть в списке."); return }
            var next = self.settings; next.excludedApps.append(id)
            self.appNames[id] = url.deletingPathExtension().lastPathComponent
            self.commit(next, "Добавлено. В \(self.appName(id)) исправления отключены.")
        }
    }
    @objc private func saveRule() {
        var russian: Bool
        switch targetLayout.indexOfSelectedItem {
        case 1: russian = true
        case 2: russian = false
        default:
            let text = targetField.stringValue
            let hasRussian = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            let hasEnglish = text.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
            guard hasRussian != hasEnglish else {
                if let language = editingLanguage { russian = language; break }
                error("В замене неясен язык. Выберите «Русский» или «Английский» в поле «Язык текста замены»."); return
            }
            russian = hasRussian
        }
        let rule = CorrectionRule(input: sourceField.stringValue, output: targetField.stringValue,
                                  russian: russian, id: editingRule ?? UUID())
        guard rule.valid else { error("Слева напишите одно слово, справа — другую замену. В каждом поле не больше 128 символов, без переноса строки."); return }
        let layouts = KeyboardLayouts()
        guard KeyboardReplacement.keys(original: rule.input, corrected: rule.output, layout: rule.layout,
                                       appendSpace: false, keyProvider: layouts.replacement) != nil else { error("Выбранная клавиатура не поддерживает некоторые символы замены. Измените текст или язык."); return }
        guard !settings.rules.contains(where: { $0.input == rule.input && $0.id != rule.id }) else { error("Такая замена уже есть. Выберите её в списке, чтобы изменить."); return }
        var next = settings
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) { next.rules[index] = rule }
        else { next.rules.append(rule) }
        if commit(next, "Замена сохранена. Она сработает по триггерам на вкладке «Главная».") { newRule() }
    }
    @objc private func newRule() {
        editingRule = nil; editingLanguage = nil; sourceField.stringValue = ""; targetField.stringValue = ""
        targetLayout.selectItem(at: 0); tables[2].deselectAll(nil); saveRuleButton.title = "Добавить замену"
    }
    @objc private func remove(_ sender: NSButton) {
        let index = sender.tag; let row = tables[index].selectedRow
        guard row >= 0, row < numberOfRows(in: tables[index]) else { return }
        var next = settings
        switch index { case 0: next.excludedWords.remove(at: row); case 1: next.excludedApps.remove(at: row); default: next.rules.remove(at: row) }
        if commit(next, "Запись удалена из списка.") { tables[index].deselectAll(nil); if index == 2 { newRule() }; updateLists() }
    }
    @objc private func openPermission() { permission() }
    @objc private func showDiagnostics() {
        if diagnosticWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Trump Switcher — техническая информация"; panel.isReleasedWhenClosed = false
            label("Эта информация помогает разобраться в неполадках. Набираемых слов здесь нет.", panel.contentView!, y: 426, w: 774, h: 36)
            let scroll = NSScrollView(frame: NSRect(x: 22, y: 22, width: 774, height: 394))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            diagnostic.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            diagnostic.isEditable = false; diagnostic.isSelectable = true; diagnostic.drawsBackground = false
            diagnostic.frame = NSRect(origin: .zero, size: scroll.contentSize)
            diagnostic.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            diagnostic.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            diagnostic.isVerticallyResizable = true; diagnostic.isHorizontallyResizable = false
            diagnostic.autoresizingMask = [.width]
            diagnostic.textContainer?.widthTracksTextView = true
            diagnostic.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            scroll.documentView = diagnostic; panel.contentView?.addSubview(scroll)
            panel.center(); diagnosticWindow = panel
        }
        diagnostic.string = diagnostics(); diagnosticWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func exportSettings() {
        let panel = NSSavePanel(); panel.title = "Сохранить мои настройки"
        panel.nameFieldStringValue = "Trump Switcher — мои настройки.json"; panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(self.settings).write(to: url, options: .atomic)
                self.message.stringValue = "Настройки сохранены в выбранный файл."; self.message.textColor = .secondaryLabelColor
            } catch { self.error("Не удалось сохранить файл. Попробуйте выбрать другую папку.") }
        }
    }
    @objc private func importSettings() {
        let panel = NSOpenPanel(); panel.title = "Загрузить сохранённые настройки"; panel.prompt = "Загрузить"
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do { let next = try SettingsFile.read(url)
                if self.commit(next, "Готово. Настройки из файла загружены.") { self.newRule() }
            } catch { self.error("Этот файл не подходит. Выберите файл, сохранённый Trump Switcher. Ваши настройки не изменились.") }
        }
    }
    deinit { timer?.invalidate() }
}
