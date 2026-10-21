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
    """)

    public static let english = words("""
    autocorrection autocorrections autocompletions
    sidepanel sidepanels worktree worktrees
    agentic codegen codemod codemods devtools
    cloudflare vercel dockerize dockerized dockerizing
    """)

    public static func recognizes(_ word: String, _ layout: Layout) -> Bool {
        (layout == .russian ? russian : english).contains(word)
    }
}
