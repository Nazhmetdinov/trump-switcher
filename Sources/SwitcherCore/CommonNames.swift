import Foundation

/// Curated application data, authored locally. No external spelling service or
/// learning from typed text. Inflections are explicit, never guessed suffixes.
public enum CommonNames {
    private static func words(_ text: String) -> Set<String> { Set(text.split(whereSeparator: \.isWhitespace).map(String.init)) }
    private static let russian = words("""
    яндекс яндекса яндексу яндексом яндексе яндексы
    гугл гугла гуглу гуглом гугле
    телеграм телеграма телеграму телеграмом телеграме
    телеграмм телеграмма телеграмму телеграммом телеграмме
    ватсап ватсапа ватсапу ватсапом ватсапе
    макс макса максу максом максе
    хром хрома хрому хромом хроме
    сафари файрфокс опера айфон айфона айфону айфоном айфоне
    айпад айпада айпаду айпадом айпаде макбук макбука макбуку макбуком макбуке
    эппл эйпл майкрософт виндовс линукс андроид
    вконтакте одноклассники сбер сбера сберу сбером сбере сбербанк сбербанка сбербанку сбербанком сбербанке
    тинькофф озон озона озону озоном озоне вайлдберриз авито
    ютуб ютуба ютубу ютубом ютубе рутуб рутуба рутубу рутубом рутубе
    инстаграм инстаграма инстаграму инстаграмом инстаграме
    гитхаб гитхаба гитхабу гитхабом гитхабе фигма фигмы фигме фигму фигмой
    кодекс зум зума зуму зумом зуме дискорд дискорда дискорду дискордом дискорде
    россия россии россию россией москва москвы москве москву москвой
    петербург петербурга петербургу петербургом петербурге казань казани казанью
    игорь игоря игорю игорем игоре александр александра александру александром александре
    алексей алексея алексею алексеем алексее дмитрий дмитрия дмитрию дмитрием дмитрии
    сергей сергея сергею сергеем сергее андрей андрея андрею андреем андрее
    михаил михаила михаилу михаилом михаиле николай николая николаю николаем николае
    екатерина екатерины екатерине екатерину екатериной анастасия анастасии анастасию анастасией
    ольга ольги ольге ольгу ольгой наталья натальи наталье наталью натальей
    нейросеть нейросети нейросетей нейросетям нейросетями нейросетях
    промпт промпта промпту промптом промпте промпты промптов промптами
    чатбот чатбота чатботу чатботом чатботе чатботы чатботов
    скриншот скриншота скриншоту скриншотом скриншоте скриншоты скриншотов
    мессенджер мессенджера мессенджеру мессенджером мессенджере мессенджеры мессенджеров
    автозамена автозамены автозамене автозамену автозаменой
    автопереключение автопереключения автопереключению автопереключением автопереключении
    бэкенд бэкенда бэкенду бэкендом бэкенде фронтенд фронтенда фронтенду фронтендом фронтенде
    дедлайн дедлайна дедлайну дедлайном дедлайне дедлайны дедлайнов
    созвон созвона созвону созвоном созвоне созвоны созвонов
    деплой деплоя деплою деплоем деплое коммит коммита коммиту коммитом коммите коммиты коммитов
    плагин плагина плагину плагином плагине плагины плагинов
    онбординг онбординга онбордингу онбордингом онбординге
    кэш кэша кэшу кэшем кэше докер докера докеру докером докере
    клауд клод джемини дипсик перплексити миджорни курсор таймвеб
    госуслуги госуслуг госуслугах госуслугам госуслугами
    """)
    private static let english = words("""
    yandex google telegram whatsapp max chrome safari firefox opera
    iphone ipad macbook imac macos ios apple microsoft windows linux android
    github gitlab codex chatgpt openai figma zoom discord slack notion timeweb
    youtube rutube ozon wildberries avito sber sberbank tinkoff vk vkontakte
    outlook onedrive icloud dropbox airpods homebrew swift python javascript typescript
    instagram facebook tiktok netflix spotify pinterest reddit linkedin
    claude gemini deepseek perplexity midjourney cursor windsurf copilot anthropic ollama
    docker kubernetes postgresql postgres sqlite redis mongodb mysql nginx vite react nextjs
    intellij webstorm pycharm xcode swiftui appkit testflight facetime touchid faceid
    devops powershell ebpf
    obsidian raycast alfred arc vivaldi brave thunderbird proton bitwarden
    screenshot screenshots screencast workflow workflows onboarding backend frontend fullstack
    pullrequest webhook webhooks autocomplete autocorrect hotkey hotkeys keymap keymaps
    """)
    public static func recognizes(_ word: String, _ layout: Layout) -> Bool {
        let normalized = word.lowercased()
        return (layout == .russian ? russian : english).contains(normalized) ||
            ReviewedVocabulary.recognizesName(normalized, layout)
    }

    // Membership in a name list alone must not license arbitrary camelCase
    // identifiers such as jOhN or sVeLtE. Only reviewed brand spellings can
    // bypass the normal internal-capital guard; title case needs no exception.
    private static let internalCapitals = words("""
    iPhone iPad iMac MacBook macOS iOS iCloud AirPods OneDrive FaceTime TouchID FaceID
    WhatsApp WeChat YouTube TikTok AliExpress PayPal PlayStation JetBrains
    GitHub GitLab OpenAI ChatGPT DeepSeek Midjourney HuggingFace
    DevOps PowerShell eBPF SwiftUI AppKit TestFlight PyCharm WebStorm IntelliJ GoLand DataGrip RustRover
    PostgreSQL Postgres MySQL SQLite MongoDB DuckDB ClickHouse DynamoDB BigQuery OpenSearch
    FastAPI SQLAlchemy NumPy SciPy PyTorch TensorFlow OpenVPN WireGuard ZeroTier
    McDonald McKenzie McCarthy McGregor MacDonald O'Connor O'Brien O'Neill D'Angelo
    """)
    public static func allowsInternalCapitals(_ word: String, _ layout: Layout) -> Bool {
        layout == .english && internalCapitals.contains(word) && recognizes(word, layout)
    }
}
