# История изменений / Changelog

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
