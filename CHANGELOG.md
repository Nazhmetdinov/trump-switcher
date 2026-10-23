# История изменений / Changelog

## 0.6.48 · build 87 · 2026-10-23

- Расширено распознавание редких слов из уже поставляемых словарей: ограниченный анализ сочетаний букв допускает дополнительную проверку Hunspell, но сам по себе не разрешает замену.
- Добавлена защита от потери букв при конкуренции полного редкого слова с вариантом, содержащим пунктуацию, в том числе при смешанном вводе.
- В разделе «Не менять» появились условия «Начинается с» и «Содержит». Старые точные исключения и пользовательские настройки сохраняются; правила применяются к исходному слову и результату.
- Правила компилируются при изменении настроек, чтобы не перебирать весь список при вводе. Нет обучения на набираемом тексте или его сохранения.
- 377 475 проверок ядра; отдельные проверки настроек, миграции и обеих архитектур. Проверки в сторонних приложениях и установка на пользовательский Mac не выполнялись.

## 0.6.47 · build 86 · 2026-10-23

- Расширены проверяемые локальные списки: русские имена, отчества и фамилии с явными падежами, английские имена и фамилии, бренды, ИТ-лексика и разговорные формы. Новые записи не разрешают произвольные окончания или замену уже правильных слов.
- Исправлен выбор усечённого слова перед пунктуацией: например, `dfkthb.!` больше не превращается в `валери.!`. Конкурирующие полные написания остаются без автоматической замены; существующее правило буквального многоточия сохранено.
- Внутренние заглавные разрешены для проверенных написаний `iPhone`, `GitHub`, `PlayStation`, `McDonald`, `O'Connor` и других. Принадлежность словарю больше не разрешает произвольный регистр вроде `jOhN`.
- Список источников ввода обновляется при добавлении/удалении раскладок macOS. После пробуждения фильтр пересоздаётся с очисткой старого контекста ввода.
- Если русская или английская раскладка не добавлена в macOS, вместо ложного «Готов к работе» показывается объяснение и кнопка настроек клавиатуры. Техническая информация дополнена версией macOS и архитектурой сборки.
- Нативные проверки Apple Silicon и отдельная сборка Intel выполняются без установки и вмешательства в сторонние приложения. Это не подтверждает причину каждого отказа на компьютерах пользователей.

## 0.6.46 · build 85 · 2026-10-22

- Восстановлены исправления коротких русских слов `bp → из`, `ds → вы`, `kb → ли`, `vs → мы` и других. Прописные сокращения защищены; после известного английского слова короткие английские обозначения сохраняются. Контекст содержит только язык и сбрасывается при смене поля, ручной раскладки или внешнем вводе.
- Добавлены полные проверенные словоформы современных терминов: «видеосозвонами», «нейроагентам», «промптах», «пулреквестами», `timezones`, `worktree's` и другие. Исправлена обработка внутреннего регистра для `DevOps`, `PowerShell`, `eBPF`.
- Типографские дефисы U+2010/U+2011 учитываются при распознавании и в исключениях. Верно набранный текст сохраняется; при исправлении раскладки используется обычный дефис, доступный физической клавиатуре.
- Подготовка доступности Chromium снова допускает попытки после ограниченного периода ожидания вместо пожизненного отказа после трёх неудач в одном процессе.
- Проверка результата замены перенесена с потока ввода на отдельную очередь. Продолжение набора не отменяет чтение точно ограниченного участка исправления. Проверка не задерживает клавиши и не выполняет повторных записей; непроверенный результат учитывается отдельно.
- Уменьшены повторные словарные запросы в рамках одного решения, исключения подготавливаются при изменении настроек. Проверка безопасности фокуса использует общий бюджет, а паузы внутри слова не сбрасывают его буфер. Неоднозначные варианты пунктуации по-прежнему не угадываются.

## 0.6.45 · build 84 · 2026-10-22

- Адаптированы две защиты из открытого RuSwitcher (MIT): исключения учитывают также результат исправления, а короткие английские обозначения `vs`, `DJ`, `KB`, `JR`, `BP`, `YE`, `DS` не превращаются автоматически в русские слова. Свои явно заданные замены по-прежнему имеют приоритет над защитой коротких обозначений.
- Защита согласована с существующей обработкой пунктуации: символ на клавише русской буквы не отсекается, если целое слово уже подтверждено словарём. Неоднозначные варианты сохраняются.
- Сохранены словари, физические таблицы раскладок, порядок доставки текста и выбор языка после исправления. Указаны источник, точная ревизия и лицензия заимствований.

## 0.6.44 · build 83 · 2026-10-22

- После успешного автоматического исправления остаётся раскладка исправленного слова. Убран безусловный возврат через 90 мс, который снова включал прежний язык перед следующим словом. При отменённой проверке без изменения текста прежняя раскладка по-прежнему восстанавливается.
- Обновление Accessibility-объекта того же поля после уже отправленной замены больше не сбрасывает очередь и следующее полное слово. Неподтверждённая замена и переход в другое поле по-прежнему отменяются; геометрия не разрешает редактирование без проверки текста.
- Офлайн-регрессия воспроизводила пропуск второго слова до правки и проходит после неё в обоих направлениях. Проверены смешанные по времени клавиши следующего слова до и после выбора раскладки. Это проверка модели и сборки, а не новое подтверждение работы во всех сторонних приложениях.

## 0.6.43 · build 82 · 2026-10-22

- Удалена ложная русская запись из решений распознавания: набранное в русской раскладке `сфе` теперь исправляется в `cat`, а не блокируется как якобы правильное русское слово. Исходные частотные файлы и их лицензии сохранены.
- Добавлены проверенные современные написания и формы на русском и английском, включая короткие слова, которые не мог принять дополнительный морфологический словарь. Для неоднозначных сочетаний по-прежнему безопаснее оставить набранный текст, чем заменять часть слова.
- Проверены полные частотные списки и реальные таблицы поддерживаемых раскладок: неверных исправлений и изменений корректных слов в аудите нет. Гарвардский General Inquirer изучен, но не включён: это словарь смысловых категорий для анализа текста, а не источник проверки написания; его самостоятельное распространение также ограничено правообладателем.

## 0.6.42 · build 81 · 2026-10-22

- Trump Switcher работает как приложение строки меню: без значка в Dock и без автоматического открытия настроек при запуске. Настройки и справка открываются по команде в меню значка.
- Приложение продолжает работать после закрытия окна настроек. Сборки Apple Silicon и Intel проверены локально без установки на Mac.

## 0.6.41 · build 80 · 2026-10-21

- При смене поля редактора с тем же Accessibility-объектом приложение теперь учитывает устойчивый идентификатор поля. Начало слова из прежнего поля не переносится в новое.
- После подтверждённой смены поля первое слово обрабатывается сразу. При пересоздании объекта того же поля с совпадающей геометрией сохранённая часть слова используется только после проверки полного текста перед заменой.
- Пройдены 77 996 офлайн-проверок, включая 240 воспроизводимых последовательностей ввода. Сборки Apple Silicon и Intel и оба установочных образа проверены без установки на Mac; поведение на реальном Intel Mac и в сторонних редакторах этим выпуском отдельно не подтверждалось.

## 0.6.40 · build 79 · 2026-10-21

- Исправлена отмена ожидающей замены, когда редактор пересоздаёт Accessibility-объект того же поля с устойчивым идентификатором. Переход в другое поле по-прежнему отменяет замену; совпадение одной геометрии не считается доказательством того же поля.
- Если пересозданные поля совпали только по координатам, программа сохраняет набранные символы, но перед заменой требует подтверждения целого слова в текущем поле. Это исключает удаление части слова из другого поля при быстром переключении.
- Сохранены точная проверка поля и текста непосредственно перед отправкой клавиш, порядок их доставки и возврат прежней раскладки после исправления.

## 0.6.39 · build 78 · 2026-10-21

- Добавлены 33 русские и 17 английских написаний, отсутствовавших в упакованных словарях: современные термины и их конкретные формы. Существующие частотные словари и лицензии не менялись.
- При совпадении символа на разных физических клавишах RussianWin преобразование теперь выбирает обычную ANSI-позицию. Это исправляет обратное сопоставление «ё» с клавишей ` вместо служебной ISO-клавиши.
- Проверены все печатные позиции пяти поддерживаемых раскладок с сочетаниями Shift, Caps Lock и Option; расширенный офлайн-прогон слов и оформления прошёл без ошибок. Неоднозначные варианты по-прежнему не заменяются автоматически.

## 0.6.38 · build 77 · 2026-10-21

- После автоматического исправления программа возвращает раскладку, которая была включена до этого слова. Возврат выполняется после доставки всей замены; уже набранные клавиши следующего слова остаются в очереди до возврата.
- Если пользователь сам сменил раскладку или активное приложение, программа не перезаписывает этот выбор.
- В настройках своих замен подпись «Язык текста замены» теперь описывает язык исправленного слова, а не раскладку, которая останется после него.
- Проверены словари RU/EN и физические соответствия поддерживаемых раскладок. Неоднозначные написания по-прежнему сохраняются, чтобы не портить правильно введённый текст.

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

## 0.6.48 · build 87 · 2026-10-23

- Expanded rare-word recognition from the existing bundled dictionaries: bounded letter-pattern backoff permits an additional Hunspell lookup, never a replacement on its own.
- Protected complete rare words against competing punctuation interpretations that would lose letters, including mixed-script input.
- Added “Starts with” and “Contains” conditions in «Не менять». Existing exact exclusions and user settings are retained; rules cover both the original word and the selected result.
- Rules are compiled when settings change instead of scanning the full list during input. No learning from typed text or typing history.
- 377,475 core assertions plus settings, migration and architecture checks. No third-party application tests or installation on the user's Mac.

## 0.6.47 · build 86 · 2026-10-23

- Expanded enumerable local lists of Russian names, patronymics and surnames with explicit inflections, English names, brands, technical vocabulary and colloquial spellings. No speculative suffixes or forced conversion of valid source words.
- Fixed truncated-word selection before punctuation: `dfkthb.!` no longer becomes `валери.!`. Competing complete spellings stay unchanged; the existing literal-ellipsis convention is retained.
- Reviewed internal-capital spellings such as `iPhone`, `GitHub`, `PlayStation`, `McDonald` and `O'Connor` remain eligible. Name-list membership no longer licenses arbitrary case such as `jOhN`.
- Refresh enabled layouts when macOS input sources change. Recreate monitoring and clear stale input context after wake.
- Show a specific missing-layout state with a keyboard-settings action instead of reporting readiness without Russian/English sources. Diagnostics include macOS and build architecture.
- Native Apple Silicon checks and an Intel cross-build do not install the app or access third-party editors. They do not establish the cause of every reported failure on another Mac.

## 0.6.46 · build 85 · 2026-10-22

- Restored short Russian conversions including `bp → из`, `ds → вы`, `kb → ли`, and `vs → мы`. Uppercase abbreviations remain protected; a preceding known English word protects short English tokens in that field. Context stores only the language and resets on field, manual-source, or external-input changes.
- Added reviewed modern inflections, including `timezones` and `worktree's`, and enabled internal-capital spellings `DevOps`, `PowerShell`, and `eBPF` through the curated name policy.
- Recognize U+2010/U+2011 hyphens in compounds and exclusions. Correct source text is untouched; corrections use a physically typeable ASCII hyphen.
- Chromium Accessibility preparation can recover after a bounded cooldown instead of permanently stopping after three failures in the same process.
- Moved replacement observation off the input thread. Continued typing no longer cancels readback of the fixed replacement span. Observations never gate keys or repeat a write; unobserved results are counted separately.
- Deduplicate dictionary lookups within a decision, compile exclusions on settings changes, and bound focus-safety probing with one total budget. Mid-word pauses preserve the token. Intrinsically ambiguous punctuation remains unchanged.

## 0.6.45 · build 84 · 2026-10-22

- Adapted two MIT-licensed RuSwitcher protections: exclusions also check the selected replacement, while short English tokens `vs`, `DJ`, `KB`, `JR`, `BP`, `YE`, and `DS` remain unchanged. Explicit custom replacement rules still take priority over short-token protection.
- Integrated the guards with existing punctuation handling, preserving recognized whole words containing letters on punctuation keys and leaving ambiguous input unchanged.
- Retained dictionaries, physical layout tables, ordered text delivery, and the corrected language after a replacement. Recorded the upstream revision and bundled its license.

## 0.6.44 · build 83 · 2026-10-22

- Successful automatic corrections keep the corrected word's input source selected. Removed the unconditional 90 ms return that re-enabled the previous language before the next word. Refused preflights still restore the original source without changing text.
- Recreation of the same field's Accessibility wrapper after a committed correction no longer cancels ordered delivery or drops the next complete word. Uncommitted edits and genuine field changes remain subject to cancellation and exact text/field checks.
- An offline regression reproduced the skipped second word before the fix and passes afterward in both directions. Queued next-word keys captured before and after source selection were checked separately. This verifies the model and packages, not every third-party editor.

## 0.6.43 · build 82 · 2026-10-22

- Excluded a false Russian frequency entry from recognition, allowing `сфе` typed on a Russian layout to become `cat` without changing the upstream frequency files or their licenses.
- Added verified contemporary Russian and English spellings and inflections, including short words that the supplemental morphology source cannot safely admit wholesale. Ambiguous input still stays unchanged rather than producing a fragment.
- Audited the complete frequency lists against the supported physical layouts: no incorrect corrections or changes to accepted source words. Harvard's General Inquirer was reviewed but not bundled: its semantic categories are not a spelling lexicon, and independent redistribution is restricted.

## 0.6.42 · build 81 · 2026-10-22

- Trump Switcher runs as a menu-bar app: no Dock icon and no settings window opened automatically at launch. Settings and help remain available from the menu-bar icon.
- Closing the settings window leaves the app running. Apple Silicon and Intel packages were checked locally without installation.

## 0.6.41 · build 80 · 2026-10-21

- A reused Accessibility object with a different stable field identifier now starts a new token, so a prefix from the previous editor cannot be carried into the next one.
- The first word in a newly confirmed field is eligible for correction immediately. When only geometry matches after wrapper recreation, a retained prefix still requires exact whole-word verification before replacement.
- Passed 77,996 offline checks, including 240 reproducible input sequences. Apple Silicon and Intel builds and both disk images were verified without installation; this release does not claim runtime validation on Intel hardware or in third-party editors.

## 0.6.40 · build 79 · 2026-10-21

- Fixed cancellation of a pending correction when an editor recreates the Accessibility object for the same field with a stable identifier. A switch to another field still cancels the correction; matching geometry alone is not treated as proof of the same field.
- When recreated fields match only by geometry, typed characters are retained but a correction requires verification of the complete word in the current field. This prevents deleting part of a word in another field after a fast focus switch.
- Exact field/text verification before posting keys, ordered delivery, and return to the previous input source remain in place.

## 0.6.39 · build 78 · 2026-10-21

- Added 33 Russian and 17 English exact spellings missing from the bundled dictionaries, including current technical terms and selected inflections. Existing frequency packs and licenses are unchanged.
- When RussianWin exposes the same glyph on different physical keys, conversion now prefers the ordinary ANSI position. This fixes the mapping of ё to the grave key instead of the ISO section key.
- Checked all printable positions of the five supported layouts with Shift, Caps Lock and Option combinations. The expanded offline word and punctuation matrix passed; ambiguous spellings are still left unchanged.

## 0.6.38 · build 77 · 2026-10-21

- Automatic corrections now return to the input source active before that word. The return waits for the entire replacement batch to reach the editor, while keys already typed for the next word remain queued.
- A user-selected input source or another foreground app is never overridden.
- Renamed the custom-rule language label so it describes the replacement text rather than the input source left selected afterward.
- Audited the bundled RU/EN dictionaries and physical mappings for supported layouts. Ambiguous spellings remain unchanged to avoid corrupting correct text.

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
