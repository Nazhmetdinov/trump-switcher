# История изменений / Changelog

## 0.6.37 · build 76 · 2026-10-18

- Увеличены просветы между буквами «A», «Я» и разделителем значка в строке меню. Высота знака сохранена, внешние поля остаются видимыми.

## 0.6.36 · build 75 · 2026-10-18

- Значок «A│Я» в строке меню уменьшен по высоте и ширине, выровнен по центру поля 22 pt и получил заметные отступы. Линии стали тоньше; поведение переключателя не менялось.
- Установочные образы теперь получают имя тома с номером версии, чтобы открытый установщик прошлой версии не сбивал оформление нового.

## 0.6.35 · build 74 · 2026-10-17

- Значок в строке меню заменён на изящный монохромный знак «A│Я» по варианту №2. Буквы и тонкий разделитель рисуются векторно для экранов 1×, 2× и 3×; иконка адаптируется к светлой и тёмной строке меню.
- Алгоритм исправления раскладки и иконка приложения не менялись.

## 0.6.34 · сборка для Intel · 2026-10-16

- Установщик Intel `setup5`: отдельное имя тома и корректная ссылка Finder на встроенный фон устраняют конфликт с образом Apple Silicon.
- Добавлены отдельные DMG и ZIP для Mac с Intel (x86_64, macOS 13+); функциональный код и версия приложения не менялись.
- Сборка и установщик прошли проверку архитектуры, подписи, ресурсов и контрольных сумм. Запуск на Intel Mac пока не проверен.

## 0.6.34 · build 73 · 2026-10-15

- Во всех размерах иконки восстановлен единый исходный портрет: устранена подмена на упрощённый рисунок в настройках и системных списках.
- Сохранено исправление формата ICNS, устраняющее цветную рябь в macOS.

## 0.6.33 · build 72 · 2026-10-15

- Исправлена пиксельная «рябь» значка в списках разрешений macOS и других местах, где система использует размер 16 или 32 пикселя: эти части ICNS теперь записаны в ожидаемом macOS формате ARGB.
- Для малого размера нарисован упрощённый портрет; большая иконка приложения сохранена.

## 0.6.32 · build 71 · 2026-10-15

- Подготовлен первый открытый выпуск для macOS 13+ на Apple Silicon.
- Стоковая иллюстрация заменена новой самостоятельной иконкой; исходное изображение и материалы для сборки доступны в репозитории.
- Выпущен фирменный установочный DMG с перетаскиванием приложения в «Программы», а также ZIP и контрольные суммы SHA-256.
- Добавлены документация на русском и английском языках, лицензия, сведения о словарях и правила сообщения об ошибках.
- Локальные проверки сборки и упаковки подтверждают подпись приложения, целостность образа и архива, ресурсы словарей и запрет сетевых соединений. Совместимость с каждым сторонним редактором этими проверками не гарантируется.

## 0.6.31 · build 70

- Исправлены обработка границ слова и ряд сценариев замены в текстовых редакторах.

---

## 0.6.37 · build 76 · 2026-10-18

- Increased the gaps between A, Я, and the menu-bar divider, retaining the compact height and clear outer margins.

## 0.6.36 · build 75 · 2026-10-18

- Made the A│Я menu-bar mark shorter and narrower, centered it within its 22-pt canvas, and added clear margins. Slightly lighter strokes keep the compact icon crisp; app behavior is unchanged.
- Versioned installer volume names prevent an older mounted disk image from redirecting the new Finder background.

## 0.6.35 · build 74 · 2026-10-17

- Replaced the menu-bar icon with the refined monochrome A│Я mark from option 2. The letters and fine separator are rendered from vector paths at 1×, 2× and 3×; the template icon adapts to light and dark menu bars.
- Text correction behavior and the app icon are unchanged.

## 0.6.34 · Intel build · 2026-10-16

- Intel installer `setup5` gives the image a distinct volume name and Finder background reference, avoiding a conflict with the Apple Silicon image.
- Added separate DMG and ZIP downloads for Intel Macs (x86_64, macOS 13+), without changing the app's functionality or version.
- Verified architecture, signature, resources and checksums. A launch on Intel hardware has not yet been tested.

## 0.6.34 · build 73 · 2026-10-15

- Restored the same original portrait across all icon sizes, removing the simplified substitute shown in Settings and system lists.
- Retained the ICNS encoding fix that prevents garbled colours on macOS.

## 0.6.33 · build 72 · 2026-10-15

- Fixed the garbled icon in macOS permission lists and other 16/32-pixel contexts by encoding those ICNS representations as native ARGB.
- Added a simplified portrait for small sizes while retaining the full-size app icon.

## 0.6.32 · build 71 · 2026-10-15

- Prepared the first open-source release for macOS 13+ on Apple Silicon.
- Replaced the unlicensed stock-derived illustration with independently generated project artwork; the source and icon build assets are included.
- Packaged a branded drag-to-Applications DMG, a ZIP archive, and SHA-256 checksums.
- Added bilingual documentation, licensing, dictionary notices, and an issue-report template.
- Local build and packaging checks verify the app signature, disk-image and archive integrity, bundled dictionaries, and blocked network sockets. These checks do not establish compatibility with every third-party editor.
