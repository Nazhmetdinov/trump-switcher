import Foundation

/// Small, reviewed additions to the bundled spelling dictionaries. These are
/// complete spellings, not stems: accepting arbitrary inflections here would
/// turn wrong-layout English words into false Russian positives (and vice versa).
/// Keep this list separate from proper names, which have different case rules.
public enum SupplementalWords {
    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    public static let russian = words("""
    автозаменами фронтендов патчем нейронкой
    промптинг промптинга промптинге
    тапать тапнул тапнула тапнули
    дизлайка гуглил гуглила гуглили загуглил
    телеграмов суперапп супераппа супераппы супераппов
    нейроагент нейроагента нейроагенты нейроагентов
    мультиагент мультиагента мультиагенты
    скроллит скроллил скроллила скроллили заскринить
    мем мемы рилс чаты фича фичи айти пуш пуши пушей скам ок
    пин пины репо сорс фейк
    трея трее пулреквест пулреквеста пулреквесты
    офлайн свайп свайпнуть фидбек фидбека фидбеком
    нейроагентами нейронками промптингу нейросетевым
    кэширование кэширования мерж вайб вайбкодинг баги
    лайк вебкамера апдейт лайфхак лайфхаки фичам
    видеосозвон видеосозвона видеосозвону видеосозвоном видеосозвоне
    видеосозвоны видеосозвонов видеосозвонам видеосозвонами видеосозвонах
    нейроагенту нейроагентом нейроагенте нейроагентам нейроагентах
    мультиагенту мультиагентом мультиагенте мультиагентов
    мультиагентам мультиагентами мультиагентах
    промптам промптах
    фидбека фидбеку фидбеке фидбеки фидбеков фидбекам фидбеками фидбеках
    фидбэк фидбэка фидбэку фидбэком фидбэке фидбэки фидбэков фидбэкам фидбэками фидбэках
    пулреквесту пулреквестом пулреквесте пулреквестов
    пулреквестам пулреквестами пулреквестах
    мердж мерджа мерджу мерджем мердже
    мержить мержу мержишь мержит мержим мержите мержат мержил мержила мержили
    дебажить дебажу дебажишь дебажит дебажим дебажите дебажат дебажил дебажила дебажили
    """)

    public static let english = words("""
    autocorrection autocorrections autocompletions
    sidepanel sidepanels worktree worktrees
    agentic codegen codemod codemods devtools
    cloudflare vercel dockerize dockerized dockerizing
    api llm llms dockerfile webkit tokenizer tokenization
    signup passcode webapp bugfix dataclass langchain patchset
    timezone timezones readonly worktree's
    """)

    public static func recognizes(_ word: String, _ layout: Layout) -> Bool {
        (layout == .russian ? russian : english).contains(word)
    }
}
