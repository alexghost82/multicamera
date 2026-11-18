# ACTA — отчёт о выполнении Phase 1

Дата: 2026-11-17. Статус: частичная реализация, приёмка Phase 1 не завершена.

### Текущая авторизация модельных действий

В production-путь подключён broker для `canvas.set_presentation`, `canvas.set_filter`, `canvas.set_arrange_mode`, `canvas.select_cameras` и `analysis.set_section`: локальная одноразовая проверка, SQLite-аудит до подтверждения, проверка окна и прежнего состояния до изменения. Для фильтров и выбора камер также проверяется соответствующий инвентарь. Старые сохранённые предложения и вызовы общего registry через legacy-путь не исполняются; остальные действия, кроме указанной ниже инспекции `camera.list`, возвращают UNSUPPORTED. Реальный GUI и голос не проверялись.
Инспекция `camera.list` выдаёт модели только ID, имя, признак включения и тип
источника; адреса потоков, пути и идентификаторы устройств исключены. Это не
гарантия удаления всех возможных секретов из произвольно заданного имени.

Автопоиск истории и legacy-инспекции теперь требуют capability локальной
сессии с проверкой отзыва и аудита; `run_readonly_sql` отключён. Production
сессия пока автоматически получает области чтения для всех сохранённых камер,
а не выбранное оператором подмножество. Проверены синтетические chat/voice
сессии, отказ аудита и отзыв; реальный GUI, микрофон и модель не проверены.
Остальные registry-действия по-прежнему недоступны модели: Phase 1 не завершена.

Контекст assistant сохраняется для новых ответов без предложений действий, помеченных приложением в той же транзакции; изменение содержимого снимает отметку. Старые ответы без такой provenance не отправляются модели: по сохранённому тексту нельзя доказать, что в нём нет пересказанных чувствительных данных legacy-review. Возобновляется только локально подтверждённая offline-цепочка с неизменённым ограниченным debt; непрозрачную legacy server chain безопасно восстановить невозможно. In-process MLX сам не поддерживает серверную цепочку. Обычное создание временного clip в `live_look` восстановлено. Сбой восстановления SQLite synchronous теперь явно сообщает, была ли запись аудита совершена.

GUI undo identity теперь проверяет треки всего перестраиваемого графа и
изменения принятых рёбер; сбой записи аудита откатывает транзакцию. Для HTML
подготовлен изолированный publisher с привязкой подтверждения к байтам и
эксклюзивным созданием файла, но он не подключён к production: выбор
назначения и изоляция других writers остаются обязанностью вызывающего кода.
Модельные identity undo и экспорт не опубликованы.
Подготовлен также неподключённый review-action для избранного: его контракт
требует атомарного согласования всех writers, которого `UserDefaults` не даёт.
Семь синтетических тестов нового контракта прошли; production-паритет этим не
подтверждается.

Ошибки чтения предыдущей narrative-главы теперь останавливают сохранение и
попадают в диагностику; зарезервированный пакет можно повторить. Порядок
исторических глав после отката системных часов всё ещё не гарантирован.
Некорректный результат inspection больше не подменяется пустым JSON.

Последний объединённый изолированный прогон scoped inspection, broker review,
canvas, memory, identity, publisher и registry: **111 XCTest и 52 Swift Testing, 0 ошибок**. Проверка локализации и
`git diff --check` прошли. Это не подтверждает полную GUI↔agent parity.
После подключения `camera.list` отдельный изолированный прогон проверил также
полный synthetic chat loop и прежнюю GUI-регистрацию камеры: **8 XCTest,
0 ошибок** (в двух последовательных прогонах). Реальная модель не запускалась.

## Исходное состояние и разрешение

Локальный проект: `/Users/alexandr.bogdanov/Documents/multicamera`, ветка `main`, исходный HEAD `c29c455a3adb4c1335c9531db76e814f8d9c397b`. Рабочее дерево перед правками чистое. Пользователь подтвердил, что для Phase 1 достаточно переданных инструкций и `CLAUDE_CODE_ACTA_PROMPT.md`, дополнительных правил нет.

Mac: Apple M5, 24 ГБ RAM, macOS 27.2, Xcode 27.2, Swift 6.4.2.

## Изменения

- `ACTAActionProtocol.swift`: класс security-sensitive для подтверждения изменений разрешений, явный результат UNSUPPORTED, безопасное JSON-кодирование ошибок.
- `ACTAActionRegistry.swift`: проверка известных/обязательных аргументов, примитивных типов, конечности чисел и enum до выполнения; подтверждение security-sensitive действий; в подтверждении показываются параметры с редактированием потенциально секретных полей; параллельные мутации отклоняются с ACTION_BUSY до завершения выполнения и проверки активной операции.
- `ACTAActionAdapters.swift`: неподключённые сервисы больше не сообщают об успешной операции; аналитика без provider не выдаёт default за реальное состояние; неизвестные переключатели отклоняются; расширена проверка настроек и разрешений после записи.
- `ACTACameraActionAdapters.swift`: исправлены исходные ошибки доступа; подключены MainActor providers к `saveSystemSettings`, `setFeatureEnabled`, `saveFeaturePolicy`, `localAnalyticsEngine.updateSettings`. Неоднозначное имя камеры не выбирает первую камеру; пароли и query tokens из stream URL не передаются модели. Для сброса layout проверяются runtime и сохранённый файл.
- `ACTAAnalyticsCoordinator.swift`: каталог 11 работающих действий экспортируется в запрос локальной модели с именами `acta__...`; цикл ограничен четырьмя шагами. До выполнения записывается audit intent. Запросы подтверждения сохраняются как `ghost_chat_actions` с тем же confirmation token.
- `WallModel.swift`: операторское подтверждение токена проходит через реестр; сохранённое предложение одноразово подтверждается до async выполнения, чтобы повторный клик не повторял операцию; результат записывается в tool audit и выводится в статус.
- `ACTAServiceAdapterTests.swift`: реальная временная конфигурация и SQLite, проверка live/persisted settings, подтверждений, редактирования URL и цепочки model tool catalogue → scripted local HTTP response → action → verified tool output. Синтетический transport не является проверкой настоящего Qwen. Audit arguments сохраняют параметры с редактированием потенциально секретных полей и URL credentials.
- `ACTAActionRegistryTests.swift`: добавлены проверки одноразовости/истечения токена, блокировки перекрывающихся мутаций, подтверждения privacy-sensitive features; проверяется отсутствие ложного успеха, валидация до изменения состояния, подтверждение разрешений и корректность JSON ошибок. Старый тест больше не считает заглушку удаления доказательством удаления данных.
- `GUI_TO_AGENT_COVERAGE.md`: исправлено число строк на 97; планы TTS/vLLM и полного покрытия больше не представлены как завершённая реализация.

## Проверки

Команда: `swift test --package-path native --disable-automatic-resolution --jobs 2 --filter ACTAActionRegistryTests`.

Первый запуск: exit code 1, тесты не запущены. Ошибка исходного кода: `initializer cannot be declared public because its parameter uses an internal type` (7 инициализаторов) и аналогичная ошибка функции `registerAllWallActions`. Лог: `/tmp/acta-phase1-tests.log`. Уровни доступа исправлены. Повторный запуск: exit code 0, все 12 тестов прошли; лог `/tmp/acta-phase1-tests-retry.log`.

Расширенная команда: `swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAActionRegistryTests|ACTAServiceAdapterTests|SettingsHubTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests'`.

Прогон `/tmp/acta-phase1-final.log`: exit code 0; 30 XCTest (два пропуска: настоящий Qwen и приватная копия истории), без ошибок; 14 Swift Testing tests, без ошибок. Финальный прогон после нормализации Boolean, проверки layout и защиты privacy-sensitive feature switches: `/tmp/acta-phase1-acceptance.log`, exit code 0. Результат: 30 XCTest, из них 2 пропущены, 0 ошибок; 15 Swift Testing tests, 0 ошибок. Сборка приложения и тестовых targets прошла. Два пропуска означают, что настоящий Qwen и приватная история в этом прогоне не проверялись.

В сборке остаются предупреждения SwiftPM о Cmlx bundle и deprecated API в существующих тестах видео; exit code успешный. Полный набор runtime/GUI/камерных испытаний не выполнялся.

`git diff --check`: exit code 0.

## Совместимость и откат

Миграций SQLite, изменений persistent keys, Keychain, моделей и зависимостей нет. Камеры, GUI приложения и реальные inference runtimes не запускались. Интеграционные тесты создавали локальные модели приложения и сервисы с временными хранилищами; HTTP transport был подставным. Внешние endpoints и инфраструктура не изменялись.

Откат: просмотреть diff и вернуть только перечисленные изменения к исходному HEAD; новые пользовательские правки при откате сохранять. Существующие пользовательские данные не затрагиваются. Build artifacts могут быть пересобраны обычным SwiftPM workflow; удаление данных приложения для отката не требуется.

## Осталось до завершения Phase 1

1. Завершить остальные операции из инвентаря и массовую очистку памяти (создание/редактирование камер, thresholds/overrides, missions, остальные разделы настроек).
2. Завершить авторизацию, единый audit для прямых GUI/domain вызовов, idempotency keys, deadlines, recovery/compensation. ACTION_BUSY предотвращает одновременные записи через реестр, но не является очередью или долговременной дедупликацией.
3. Проверить поведение настоящего Qwen с каталогом и подтверждениями; измерить влияние дополнительных шагов модели на задержку. Скриптовый transport этого не доказывает.
4. После перезапуска pending tokens в памяти отсутствуют: операция не исполняется, требуется новое предложение. Долговременное восстановление токенов не реализовано.
5. `camera.reconnect` не рекламируется в каталоге: подтверждение реального восстановления потока ещё не реализовано; default verification для мутаций теперь fail-closed.
6. Дополнить инвентарь всех UI controls и parity tests; провести регрессию и воспроизводимую проверку GUI.

Phase 2–4, TTS, vLLM Metal, выбор checkpoint и нагрузочные измерения не выполнены. Полное покрытие функций не заявляется.

## Рекомендуемая точка продолжения

Продолжать Phase 1 с оставшихся camera/analytics/settings/mission действий и их parity tests; массовую очистку памяти проектировать отдельно с recovery/compensation. До этого не переходить к заявлению полного управления или завершению Phase 1. Настоящий Qwen, vLLM Metal, TTS и hardware/performance gates остаются следующими отдельными этапами с исходными ограничениями prompt.


## Следующий участок Phase 1 — operational adapters

Исходный HEAD этого участка: `ad95a8c` (предыдущий checkpoint сохранён пользователем).
Рабочее дерево перед началом чистое. Миграций и изменения стандартных путей нет.

Изменения:

- Новый `ACTAOperationalActionAdapters.swift`: семь runtime adapters для списка/статуса инцидентов, удаления evidence, списка/создания/отмены watch rules и удаления одного кадра памяти. Используются существующие GUI/domain методы; после мутации проверяются сохранённые данные.
- `WallModel`: injectable memory store и URL watch rules для временных тестов; стандартные значения прежние. Все watch lifecycle paths используют один URL. Создание watch возвращает UUID. Общий GUI/agent метод удаления кадра проверяет отсутствие записи и физического файла.
- `LocalVideoAnalyticsEngine`: общий checked-метод удаления evidence проверяет сохранённые ссылки инцидента и отсутствие каталога; GUI оборачивает его прежним интерфейсом. Ошибки не превращаются в успешный agent result.
- `CameraMemoryStore` и `SafetyEvidenceStore`: безопасные проверки наличия физических файлов/каталогов; форматы данных не менялись.
- `IncidentTransitionStatusAction`: false_positive требует подтверждения, согласно исходной coverage policy.
- Каталог расширен с 11 до 18 действий; массовая очистка кадров остаётся UNSUPPORTED и не рекламируется.
- Новый `ACTAOperationalAdapterTests`: пять интеграционных сценариев на временных данных. Проверяются запись/перечитывание watch rules, отмена и неизвестные UUID, невалидный TTL, выключенная feature, сохранение повреждённого файла при ошибке, статус/заметка инцидента, подтверждение и физическое удаление кадра/evidence с сохранением записи инцидента.

Проверки до финального регрессионного прогона: `/tmp/acta-phase1-evidence-tests.log`, exit code 0; 37 XCTest без ошибок, 15 Swift Testing без ошибок.

Финальная команда:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraMemoryStoreTests|IncidentReliabilityTests|EvidenceReliabilityTests|OperationsPreferencesTests|SafetyIncidentCenterTests|SettingsHubTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests'
```

Лог: `/tmp/acta-phase1-domain-acceptance.log`. Exit code 0: 64 XCTest, из них 2 пропущены (настоящий Qwen и приватная копия истории), 0 ошибок; 15 Swift Testing tests, 0 ошибок. Итого 62 XCTest и 15 Swift Testing прошли. Сборка приложения и тестов прошла; `git diff --check` — exit code 0.

Оставшиеся ограничения этого участка: массовая очистка памяти не реализована; query text/custom suppression duration инцидентов не реализованы; транзакционный rollback между evidence-файлами и incident JSON при частичном сбое/падении процесса не добавлен. Такой сбой возвращает ошибку, а не успешную верификацию. Настоящие камеры, Qwen и GUI не проверялись. Полное покрытие приложения и завершение Phase 1 не заявляются.

Откат участка: просмотреть diff относительно `ad95a8c` и отменить только его изменения, сохранив любые новые пользовательские правки. Пользовательские хранилища при тестах не менялись, новых миграций нет. Реальное удаление пользователем evidence/кадров после запуска приложения необратимо и требует собственной резервной копии; откат кода удалённые файлы не восстанавливает.


## Analytics/canvas follow-up — Phase 1

Предыдущий operational checkpoint в начале этого участка ещё не закоммичен; его изменения сохранены. Новый участок не меняет persistent formats, Keychain, зависимости или пути хранения. Используются прежние `updateSettings`, `toggleExpanded` и `resetLayout`.

Добавлено:

- `ACTAAnalyticsActionAdapters.swift`: шесть новых мутаций (порог, FPS, overlay, camera override, создание/обновление и удаление прямоугольной зоны); заменён runtime read adapter для camera-specific/global settings.
- Все 12 advanced numeric settings имеют конечный список имён и проверку service limits. Не-целые значения integer thresholds и параметры, которые runtime изменил бы clamping-ом, отклоняются до записи.
- Все 15 глобальных switches сведены к общей таблице ключей для выполнения и проверки; добавлены ранее пропущенные inactivity/unusual movement/crowd/banner. Изменения evidence recording требуют подтверждения. Evidence buffers/quota тоже защищены подтверждением.
- Все восемь overlay switches доступны агенту.
- Per-camera enabled/FPS/inherit, rectangular zone lifecycle и camera-specific чтение полного effective config доступны через существующий settings service. Геометрическое редактирование сохраняет ID/политику существующей зоны, неоднозначные имена отклоняются.
- `EffectiveCameraAnalyticsConfig` получил Codable для полного typed JSON результата; persistent schemas не изменены.
- `CameraToggleExpandAction` и публикация `canvas.reset_layout`; проверяются UI state и сохранённый layout соответственно, а не реальная готовность видеопотока.
- Каталог вырос с 18 до 26 действий.
- Новый `ACTAAnalyticsActionAdapterTests`: четыре сценария, проверяющие весь набор numeric/overlay/global fields, invalid inputs без записи, camera override, lifecycle zones с сохранением policy/ID, canvas state и ошибку сохранения layout.

Первый build gate: exit code 1 (`/tmp/acta-phase1-analytics-build.log`), новая локальная функция проверки камеры нуждалась в явном MainActor. Ошибка исправлена в этом же участке. Повторный gate `/tmp/acta-phase1-analytics-tests.log`: exit code 0.

Финальная команда:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAAnalyticsActionAdapterTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraMemoryStoreTests|IncidentReliabilityTests|EvidenceReliabilityTests|OperationsPreferencesTests|SafetyIncidentCenterTests|SettingsHubTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests|LocalAnalyticsEngineCoreTests|VideoLayoutTests|VideoInteractionTests'
```

Лог `/tmp/acta-phase1-analytics-acceptance.log`: exit code 0. 84 XCTest, 2 пропущены (настоящий Qwen и приватная копия истории), 0 ошибок: 82 XCTest прошли. Дополнительно 15 Swift Testing tests прошли. Сборка приложения/тестов прошла. `git diff --check`: exit code 0.

Ограничения: не реализованы sensitivity profile actions, execution-mode changes, удаление всего camera override, остальные per-camera detector switches/cooldown, polygon/policy редактирование зон. Это обнаруженные дополнительные GUI gaps; их следует добавить в полный инвентарь перед заявлением паритета. Реальные камеры, inference hardware и GUI interactions не проверялись. Массовая очистка памяти остаётся неподключённой.

Откат: отменить только analytics/canvas изменения текущего diff после просмотра; сохранить предыдущий operational checkpoint и пользовательские правки. Изменённые агентом во время будущего использования настройки сохраняются в прежнем JSON; откат кода сам по себе их не отменяет, для отката значений нужна копия settings/layout. В этом прогоне использовались только временные тестовые хранилища.

Следующая точка продолжения: расширенные поля camera override и зоны/профили, затем оставшиеся camera/settings/mission операции; Phase 1 не завершена.


## Profiles / advanced overrides / narrative review — Phase 1

Предыдущие незакоммиченные участки сохранены. В этом участке нет миграций, новых зависимостей, изменений Keychain, инфраструктуры или стандартных путей хранения.

Реализация:

- Глобальный профиль: выбор отдельно от применения preset (`apply_values=false` повторяет GUI picker, значение по умолчанию применяет preset).
- Camera override: все девять дополнительных detector switches, профиль камеры, FPS/cooldown и явный сброс обоих custom values. Конфликтующие set/clear или inherit=true с изменением dormant fields отклоняются до записи. Полное удаление override проходит подтверждение и проверку JSON.
- Зона по UUID: переименование, enabled/hold/severity, перемещение, добавление и удаление отдельных точек полигона. Проверяются индексы, нормализованные координаты и диапазон 3...64 точек. ID зоны сохраняется.
- Главы памяти: `memory.set_chapter_text` и `memory.toggle_pin` используют общие checked-методы с GUI, перечитывают SQLite и сохраняют исходный aiSummary. Pin задаёт состояние, а не инвертирует его. Оба действия требуют review перед созданием операторской отметки. У текста агента лимит 16000 символов и явный clear=true; этот лимит не ограничивает прежний GUI workflow.
- Карточка подтверждения: раскрываемые полные параметры с text selection, native DisclosureGroup и accessibility identifier; секретные поля/URL credentials редактируются. Новые подписи переведены RU/EN. Полный текст аннотации не обрезается до 256 символов описания.
- Каталог: 31 действие. Матрица дополнена четырьмя обнаруженными analytics contracts: теперь 101 строка (97 baseline + 4). Execution mode остаётся явно не реализованным scope gap, не одобренным исключением из полного покрытия.

Проверки:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAAnalyticsActionAdapterTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraMemoryStoreTests|IncidentReliabilityTests|EvidenceReliabilityTests|OperationsPreferencesTests|SafetyIncidentCenterTests|SettingsHubTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests|LocalAnalyticsEngineCoreTests|VideoLayoutTests|VideoInteractionTests|AgentMemoryReliabilityTests|AgentRetrievalTests|LanguageSettingsTests'
make -C native localization-audit
swift build --package-path native --disable-automatic-resolution --jobs 2
```

Тесты: `/tmp/acta-phase1-final-reviewed-acceptance.log`, exit code 0. 105 XCTest: 103 прошли, два пропущены (настоящий Qwen и приватная копия истории), 0 ошибок. Дополнительно 15 Swift Testing tests прошли. Новые тесты покрывают все profiles/camera flags, clear FPS/cooldown, confirmed override removal, zone policy/points/invalid inputs, reviewed annotations и сохранение AI provenance в SQLite.

Localization gate сначала завершился с exit code 2: 73 непереведённых вхождения из добавленных action adapters/ошибок, включая предыдущие участки. Добавлены RU/EN переводы без потери placeholders. Повторный промежуточный gate нашёл CONFIRM- внутри выражения Label как UI string; проверка ID вынесена в локальную переменную, правило audit не ослаблялось. Финальный `/tmp/acta-phase1-final-localization.log`: exit code 0, untranslated source occurrences 0, plutil OK.

Финальная компиляция последнего UI refactor: `/tmp/acta-phase1-final-reviewed-build.log`, exit code 0, Build complete (3.62 secs). Сохраняется существующее предупреждение SwiftPM о Cmlx bundle; ошибок компиляции нет. `git diff --check`: exit code 0.

Не проверены вручную клавиатура/VoiceOver/экранная компоновка запущенного приложения. Использованы native SwiftUI controls и автоматические проверки, это не доказательство полной accessibility conformance. Новые действия не проверены настоящим Qwen; runtime/performance gates остаются открытыми. Polygon validation соответствует существующему service contract (количество/диапазон), отдельная геометрическая проверка самопересечений не добавлена.

Откат: отменить только изменения этого участка после просмотра diff, сохранив предыдущие незакоммиченные участки. Persistent schemas не менялись; для восстановления значений, изменённых при будущем использовании приложения, нужна копия прежнего settings JSON/SQLite. В тестах изменялись только временные хранилища.

Следующий участок: оставшиеся camera lifecycle/settings/mission действия, затем завершение авторизации/idempotency/recovery и проверка настоящим Qwen. Phase 1, full GUI parity и release acceptance не завершены.


## Mission lifecycle / history / consultation — Phase 1

Предыдущие незакоммиченные участки сохранены. Добавлены восемь mission actions: list,
create, edit, delete, history, clear_consult, run_now, ask_consult. Каталог: **39 действий**.
В матрице 102 строки: добавлен отдельный контракт mission.history. Phase 1 не завершена.

Изменения:

- Новый `ACTAMissionActionAdapters.swift`: конечные схемы аргументов, проверка UUID,
  interval/clock schedules, CSV clock times/weekdays, явного IANA time zone для новых
  clock schedules, limits и запрет пустых/конфликтующих изменений. Миссия создаётся
  выключенной по умолчанию; enabled меняется тем же edit action.
- `WallModel` использует injectable `missionStoreURL` во всех lifecycle/consult/run
  paths; стандартный путь `CameraWall/missions.json` сохранён. Существующая JSON
  schemaVersion 3 и поддержка предыдущих форматов не менялись.
- Общая проверка runtime/диск до записи: unreadable/corrupt/duplicate-ID/stale data
  не перезаписываются. Сравнение нормализует существующую ISO-8601 точность дат, не
  меняя сам формат. Это проверка снимка, не межпроцессная блокировка или CAS-файл.
- CRUD использует GUI domain methods и post-write read-back. Удаление и очистка
  консультации требуют подтверждения. Run history сохраняется, включая историю уже
  удалённой миссии; при редактировании сохраняются runs и consults.
- Ручной run возвращает только verified queued/running admission с completed=false.
  Один слот не перезаписывается другой миссией; повторный запрос того же ID не создаёт
  второй слот. Disconnect/restart очищает очередь; durable queue recovery не добавлена.
- Consultation использует прежний локальный workflow. Вопрос сохраняется, tool
  возвращает accepted=true/completion_verified=false; ответ читается через history.
  Добавлена optional dependency injection для теста ответчика, default runtime прежний.
  Тестовый ответчик не является проверкой настоящего Qwen и не включён в продуктовый UI.
- Execution inputs миссии сравниваются перед commit; изменение brief/camera/schedule
  отменяет старый запрос. Исторические поля и точность дат не считаются новым запросом.
  Отвергнутый late commit бросает CancellationError, а не порождает статус complete без
  сохранённого результата. Полный runtime сценарий с реальными кадрами ещё не проверен.
- Mission list/history JSON дополняется явными mission_id/run_id/event_id, camera_id,
  временем и типом источника. Общий AgentEvidenceLedger получает проверяемые ссылки;
  вопросы консультации и ответы отмечены отдельно от mission_run. Persistent JSON
  не менялся. Embedded JSON в текстах не декодируется в ссылки.
- Новый `ACTAMissionActionAdapterTests`: шесть сценариев на временных хранилищах:
  CRUD/history preservation, clock/timezone validation, corrupt/stale file preservation,
  idempotent queue receipt, execution-request identity, scripted consultation + ledger.

Проверки:

Первый `/tmp/acta-phase1-mission-tests.log` завершился с exit code 1: тест после проверки
corrupt storage попытался создать новую фикстуру через save в том же повреждённом файле;
store правильно отказал в перезаписи. Тест исправлен явным удалением временной broken
фикстуры перед независимым сценарием. Повторный gate exit code 0.

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAMissionActionAdapterTests|CameraMissionTests|ACTAAnalyticsActionAdapterTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraMemoryStoreTests|IncidentReliabilityTests|EvidenceReliabilityTests|OperationsPreferencesTests|SafetyIncidentCenterTests|SettingsHubTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests|LocalAnalyticsEngineCoreTests|VideoLayoutTests|VideoInteractionTests|AgentMemoryReliabilityTests|AgentRetrievalTests|LanguageSettingsTests'
make -C native localization-audit
```

Финальный лог `/tmp/acta-phase1-missions-provenance-final.log`, exit code 0: 129 XCTest,
из них 127 прошли и 2 пропущены (настоящий Qwen и приватная копия истории), 0 ошибок.
Дополнительно прошли 15 Swift Testing tests. Приложение и test targets собраны успешно.

Localization первоначально нашла 15 непереведённых вхождений в новом mission layer;
переводы добавлены. `/tmp/acta-phase1-missions-provenance-localization.log`: exit code 0,
untranslated source occurrences 0, plutil OK. `git diff --check`: exit code 0.

Ограничения: admission не доказывает завершение inference; реальные кадры/Qwen,
производительность и восстановление активной очереди после перезапуска не проверены.
Cross-process atomic update/rollback между файловыми хранилищами не реализован.
Новые тесты используют временные хранилища; стандарты запуска приложения/моделей и
локальные production defaults не менялись, пакеты не устанавливались.

Откат: просмотреть diff и отменить только mission checkpoint, сохранив предыдущую
незакоммиченную работу. Новых миграций нет. Восстановление удалённой консультации при
будущем использовании приложения требует копии прежнего missions.json; откат кода её
не восстанавливает. Следующий участок: оставшиеся camera lifecycle/settings действия,
затем recovery/idempotency/security и реальная model/hardware приёмка.


## Camera configuration / credential safety — Phase 1

Предыдущий незакоммиченный diff сохранён. В каталог добавлены шесть действий:
camera.add_network, camera.add_local, camera.add_screen, camera.add_file, camera.edit,
camera.set_processing. Итого **45 действий**, в матрице 103 строки (добавлен контракт
camera.set_processing). Полный паритет функций камеры не заявляется.

Изменения:

- Новый `ACTACameraConfigurationActions.swift`: регистрация источников DISABLED,
  метаданные/безопасные URL, YOLO/AI switches, полная проверка сохранённого Camera в
  конфигурации. Успех означает configured=true, connection_verified=false. Регистрация
  USB/display ID не доказывает существование устройства; bookmark не доказывает decoder
  readiness. Реальные capture/network/permissions gate не пройдены.
- Новый общий `saveCameraConfigurationChecked` используется GUI и агентом. Прежние GUI
  defaults продолжают запускать добавленные источники. Агент не запускает остановленную
  стену при сохранении выключенного источника; уже работающая стена может переподключиться.
  Избежан двойной start в существующем GUI network-save workflow.
- Перед мутацией checked-сервисы сравнивают config/runtime с cameras.json; corrupt/stale
  файлы не перезаписываются. Это не межпроцессный CAS. Идентификаторы камер/форматы/пути
  хранения сохраняются. Изменение enabled по старому GUI объекту меняет только актуальный
  флаг и не восстанавливает устаревшие метаданные.
- camera.set_enabled вызывает checked-сервис, enabling требует подтверждения; receipt не
  утверждает готовность потока. AI flag и URL changes также защищены review.
- Network additions пока только anonymous RTSP/RTSPS/ONVIF без query/fragment/credentials.
  Пароли не принимаются как tool arguments. Нативный secure editor остаётся для credentials,
  URL других форм и discovery. У existing camera agent edit не переносит сохранённые
  credentials на другой scheme/host/port даже после подтверждения; нужен secure GUI.
- CameraCredentialStore/SystemCameraCredentialStore добавлены как test seam к прежнему
  CameraKeychain; service `CameraWall.RTSP` и account UUID не переименованы. Checked delete
  проверяет OSStatus/отсутствие credentials; camera remove проверяет JSON и runtime.
  При ошибке config commit предпринимается компенсация credentials. Это не атомарная
  транзакция Keychain+файл и не доказательство recovery при падении процесса.
- Новый validate hook протокола вызывается реестром до confirmation token. URL с raw
  credentials/query и oversized/conflicting narrative arguments не могут стать durable
  approval proposals. Operational wrapper делегирует hook спецификации. Ошибки поиска
  камеры не повторяют исходный входной URL; streams/arguments redacted как прежде.
- camera.list/get теперь проверены на временной конфигурации; get включает локальные
  source IDs/file path и ISAPI flags, не bookmark/credentials. ISAPI editing, credential
  provisioning, snapshot, verified reconnect и изменение device/file identity ещё не
  реализованы. Дополнительные импорты/экспорты GUI тоже требуют полного инвентаря.
- Новый `ACTACameraConfigurationActionTests`: пять сценариев с временными config/bookmark
  и fake credentials, без обращения этих сценариев к live Keychain. Проверяются source
  registration/filter/get, flags/metadata/URL preservation, stale GUI merge, invalid inputs
  до proposals, endpoint reuse denial, reviewed removal и credential compensation на
  детерминированном config-write failure, сохранение corrupt JSON.

Проверки:

Первый `/tmp/acta-phase1-camera-build.log`: exit code 1, ошибки нового кода — shadowed
error в catch и порядок параметра enabled. Исправлены. Повторный build/test gate прошёл.
Localization первоначально нашла непереведённые новые ошибки; RU/EN строки добавлены.

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTACameraConfigurationActionTests|ACTAMissionActionAdapterTests|CameraMissionTests|ACTAAnalyticsActionAdapterTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraMemoryStoreTests|IncidentReliabilityTests|EvidenceReliabilityTests|OperationsPreferencesTests|SafetyIncidentCenterTests|SettingsHubTests|SettingsTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests|LocalAnalyticsEngineCoreTests|VideoLayoutTests|VideoInteractionTests|AgentMemoryReliabilityTests|AgentRetrievalTests|LanguageSettingsTests|ConfigurationTests|LocalCameraTests|LocalCameraStartupTests|VideoFileSourceConfigurationTests'
make -C native localization-audit
swift build --package-path native --disable-automatic-resolution --jobs 2
```

Финальные tests `/tmp/acta-phase1-camera-validated-final.log`: exit code 0; 156 XCTest,
154 прошли, два пропущены (настоящий Qwen и приватная копия истории), 0 ошибок.
Swift Testing: 18 tests в двух suites, все прошли. Localization:
`/tmp/acta-phase1-camera-validated-localization.log`, exit code 0, untranslated source
occurrences 0, plutil OK. `git diff --check`: exit code 0.

После уточнения tool descriptions выполнена отдельная финальная компиляция:
`/tmp/acta-phase1-camera-final-build.log`, exit code 0, Build complete (4.12 secs).

Откат: просмотреть diff и вернуть только camera checkpoint, сохранив все предыдущие
незакоммиченные участки. Новых миграций/зависимостей нет, модели не устанавливались.
Откат кода не восстанавливает удалённые пользователем credentials/config автоматически;
для реальной эксплуатации нужны штатные резервные копии и отдельная recovery приёмка.
Новые camera-тесты не запускали реальные камеры и не меняли пользовательский Keychain.

Следующий участок: оставшиеся настройки/ISAPI/snapshot/reconnect и безопасный credential
workflow, затем закрытие idempotency/audit/recovery и реальные Qwen/vLLM Metal gates.
Phase 1 и production acceptance остаются незавершёнными.

## Продолжение Phase 1: настройки выполнения, памяти, расписания и правил (2026-11-17)

Каталог расширен до 53 действий: восемь новых мутаций и расширенный
`settings.get_section`. Использован навык ai1-architect-system-designer; область
ограничена ранее разрешённой Phase 1. Форматы JSON, постоянные ключи, SQLite и
Keychain identifiers сохранены; новых зависимостей и миграций нет.

Реализованы runtime fall (22 расширенных поля GUI), crop (9), storage (6), events (5),
политика памяти, расписание и создание/изменение/удаление alert rules через существующие
методы WallModel. Storage, memory, schedules и rules требуют двухфазного подтверждения.
Четыре общих поля fall остаются в analytics actions; включение памяти — отдельное действие.
Сохранение политики очистки не подтверждает выполнение janitor; расписание не подтверждает
завершение inference. Фиксированный предел sampled frames в семь дней отражён в результате.

Проверки сохранения используют реальные временные файлы, а не только кэш координатора.
Повреждённые и изменённые на диске runtime/features/operations/AI preferences отклоняются
до перезаписи. OperationsPreferences URL внедряется для изоляции тестов; production default
сохранён. Инспекция разделов скрывает query/credentials URL и не заявляет готовность моделей
или здоровье сервисов; identity явно возвращает UNSUPPORTED. Редактирование backend,
endpoint, ключей, переключение/перезагрузка моделей здесь не реализованы.

Новый ACTASettingsActionAdapterTests содержит шесть сценариев: поля GUI и валидация,
review/reject, сохранение несвязанных настроек/permissions, lifecycle правил, redaction,
corrupt/stale stores. Реальные камеры, модели, Keychain и внешняя инфраструктура в этих
сценариях не использовались.

Проверки:
- Первый целевой gate `/tmp/acta-phase1-settings-tests.log`: 49 XCTest и 15 Swift Testing,
  без ошибок.
- Общая регрессия `/tmp/acta-phase1-settings-regression.log`: exit code 0;
  186 XCTest (184 passed, 2 skipped — real Qwen/private history), 20 Swift Testing passed
  (18 registry/local-camera и 2 startup tests). Фильтр прежнего camera checkpoint расширен
  ACTASettingsActionAdapterTests, CameraFeatureCoordinatorTests, FeaturePreferencesTests,
  FallDetectorTests. Команда: `swift test --package-path native --disable-automatic-resolution
  --jobs 2 --filter 'ACTASettingsActionAdapterTests|ACTACameraConfigurationActionTests|ACTAMissionActionAdapterTests|CameraMissionTests|ACTAAnalyticsActionAdapterTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraMemoryStoreTests|IncidentReliabilityTests|EvidenceReliabilityTests|OperationsPreferencesTests|SafetyIncidentCenterTests|SettingsHubTests|SettingsTests|UnifiedAgentHistoryTests|ACTAAnalyticsTests|ACTATransportSecurityTests|LocalAnalyticsEngineCoreTests|VideoLayoutTests|VideoInteractionTests|AgentMemoryReliabilityTests|AgentRetrievalTests|LanguageSettingsTests|ConfigurationTests|LocalCameraTests|LocalCameraStartupTests|VideoFileSourceConfigurationTests|CameraFeatureCoordinatorTests|FeaturePreferencesTests|FallDetectorTests'`.
- Первичная localization audit: exit code 2, 29 непереведённых occurrences. Добавлены
  23 уникальные RU/EN строки. Повторный `make -C native localization-audit`: exit code 0,
  `/tmp/acta-phase1-settings-localization-final.log`.
- Финальная сборка: `swift build --package-path native --disable-automatic-resolution --jobs 2`,
  `/tmp/acta-phase1-settings-final-build.log`, exit code 0. `git diff --check`: exit code 0.

Откат: выборочно вернуть изменения settings checkpoint по diff, сохранив пользовательские
коммиты и другие участки; резервные копии preferences нужны для восстановления уже
сохранённых оператором значений. Автоматической обратной миграции нет, схема не менялась.

Остаётся Phase 1: модели/backend/credentials, ISAPI/snapshot/reconnect, другие строки
матрицы, idempotency/audit/recovery и сквозной UI/agent сценарий. Реальный Qwen/vLLM Metal,
voice/TTS и performance gates остаются отдельными незавершёнными этапами.

## Первая read-only волна: incident.get

Пользователь подтвердил архитектуру от 2026-11-17, отсутствие дополнительных правил
и первую волну из трёх действий. Три направления исследовались параллельно.
Реализован только `incident.get`: зарегистрирован в action registry и каталоге
модели, читает минимальные метаданные через общий `UnifiedIncidentManager`.
Свободный текст и пути evidence не возвращаются; неверный UUID, отсутствие записи,
недоступность сервиса и ошибка хранилища различаются. Полный состав экрана инцидента
и настоящий Qwen не проверены. Изменений форматов, миграций и зависимостей нет.

Проверки:

- `swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAIncidentReadActionsTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|ACTATransportSecurityTests'`:
  exit code 0, 15 XCTest и 15 Swift Testing прошли. Тесты используют синтетические
  и временные данные, включая повреждённый файл инцидентов.
- `make -C native localization-audit`: первый запуск exit code 2 из-за двух строк,
  после добавления RU/EN переводов повторный запуск exit code 0.
- `swift build --package-path native --disable-automatic-resolution --jobs 2`:
  exit code 0. `git diff --check`: exit code 0.
- SwiftPM выводит существующее предупреждение о Cmlx bundle.

`alert.vlm_list` и `monitor.get_isapi_events` не реализованы: источники не дают
надёжно отличить ошибку загрузки от пустого списка, а некоторые существующие
методы чтения изменяют хранилище. Требуется отдельный проект безопасного источника
и согласование его изменений. Phase 1 остаётся незавершённой.

Откат этого участка — выборочно вернуть относящиеся к `incident.get` изменения,
сохранив другие правки. Данные приложения не требуют миграции или удаления.

## Продолжение read-only волны: alerts и ISAPI

Пользователь отдельно согласовал изменения источников и существующую audit-запись.
Добавлены `alert.vlm_list` и `monitor.get_isapi_events` в реестр и каталог модели.
Выдаются минимальные метаданные; ограничение списка 1...100. ISAPI snapshot применяет
существующую retention без записи; snapshot reviews использует уже открытую SQLite
и не выполняет purge. Проверяются успешная первоначальная загрузка и совпадение
источника с GUI. Повреждение, отсутствие файлов или несовпадение не выдаются за пустой
список. Не подтверждается межпроцессная атомарность или состояние реальных камер.

Ограничения: после ошибки загрузки или отслеживаемой ошибки сохранения источник
остаётся недоступным до перезапуска; успешное включение alerts восстанавливает статус
только если ранее не было ошибки. Отсутствие файла на первом запуске трактуется как
недоступность, а не пустая история. Retention применяется к сохранённым и GUI-записям
ISAPI перед сравнением. Audit вызова по-прежнему записывается. JSON/SQLite схемы и
зависимости не изменены; ранее скрытая ошибка сохранения safety alerts теперь
показывается через notice.

Проверки:

- `swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAAlertReadActionsTests|ACTAISAPIReadActionsTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTAActionRegistryTests|CameraFeatureCoordinatorTests|FeaturePreferencesTests|ACTATransportSecurityTests'`:
  exit code 0; 34 XCTest и 15 Swift Testing прошли, только синтетические и временные данные.
- `make -C native localization-audit`: сначала exit code 2 из-за семи строк,
  после добавления переводов exit code 0.
- `swift build --package-path native --disable-automatic-resolution --jobs 2`: exit code 0.
  Сохраняется предупреждение SwiftPM о Cmlx bundle.

Откат — выборочно вернуть diff этой волны, сохраняя пользовательские изменения и данные.
Реальный Qwen, камеры, Keychain и полная Phase 1 не проверены.

Независимое ревью указало на повторное включение alerts, retention ISAPI и порядок
очистки acknowledgement; добавлены исправления и тесты. Повторное ревью выявило
влияние изменения retention и ошибок watch rules на чтение alerts; оба сценария
исправлены и покрыты тестами. Для согласованности с текущим GUI читаются также ещё
не очищенные reviews с истекшим retention, без выполнения очистки при запросе.
Ревью не имело доступа к git diff и не выдало PASS. После реальной ошибки записи
автоматическое восстановление доверия намеренно не реализовано и требует отдельного
безопасного recovery.

## Защита незавершённого camera.reconnect

При регистрации действий незавершённый `camera.reconnect` удаляется из реестра,
в том числе если он был зарегистрирован ранее. Вызов через реестр и прямой вызов
адаптера возвращают `UNSUPPORTED` до любого reconnect; существующая GUI-команда не менялась.
Реальное переподключение через агента по-прежнему не реализовано и требует проверки
восстановления потока. Миграций и изменений пользовательских данных нет.

Проверки: `swift test --package-path native --disable-automatic-resolution --jobs 2
--filter 'ACTAServiceAdapterTests|ACTAActionRegistryTests'` — exit code 0, 3 XCTest
и 15 Swift Testing прошли; `make -C native localization-audit` — exit code 0;
`git diff --check` — exit code 0. Откат — выборочно вернуть изменения этого участка
без удаления пользовательских данных.

## Продолжение Phase 1: подтверждения, поиск и VLM-оповещения

- Реестр не доверяет переданному вызывающим `isConfirmed`; новые одноразовые
  токены содержат полный UUID, имеют срок действия и отзываются при замене
  действия. Подтверждение в чате сверяет показанные оператору параметры с
  токеном и неизменённой записью. Старые нетокенные registry-предложения не
  выполняются: необходимо создать новый запрос. Отдельный legacy identity flow
  не переведён на этот механизм. Публичный API подтверждения сам по себе не
  аутентифицирует оператора; действие и запись журнала не образуют одну транзакцию.
- `incident.list` фильтрует camera name, локализованный title, explanation и
  operator notes до применения limit; свободный query скрывается в audit arguments.
  Существующий полный формат `SafetyIncident`, включая чувствительный текст и
  пути, сохранён ради совместимости и остаётся privacy-риском. Транспорт,
  как и раньше, нормализует JSON-значения в строки.
- `alert.vlm_acknowledge` и `alert.vlm_review` зарегистрированы и рекламируются.
  Используется GUI-сервис, сверяются GUI-снимок, хранилище и история; свободная
  заметка скрывается в audit arguments. Тестируется реальная SQLite-блокировка
  в отдельной временной директории. После ошибки записи источник остаётся
  недоверенным до восстановления существующим приложением; автоматическое
  восстановление доверия не доказано. SwiftUI и реальные устройства не тестировались.
  Изменение review требует отдельного подтверждения оператора.
- `CriticalAlertClipStore` можно внедрить при создании `WallModel`; значение по
  умолчанию и поведение приложения не изменены. Это позволяет новым тестам не
  обращаться к пользовательскому хранилищу клипов.

Проверка: `swift test --package-path native --disable-automatic-resolution --jobs 2
--filter 'ACTAActionRegistryTests|ACTAIncidentSearchTests|ACTAAlertMutationActionsTests|testLegacyRegistryFallbackFailsClosedWithoutChangingProposal|testTokenReviewClaimsProposalAndExecutesOnce|testActionsApplyToLiveModelAndPersistThroughGUIService'`
— 15 XCTest и 23 Swift Testing прошли. `make -C native localization-audit` и
`git diff --check` прошли. Полный suite не запускался: некоторые существующие
тесты создают `WallModel` с реальным default-хранилищем клипов, где `clips()`
может выполнять retention и удалять файлы. Предыдущие выборочные тесты с такими
fixtures могли запустить эту штатную очистку; наличие фактических изменений
пользовательских данных не проверено. Предупреждение SwiftPM о Cmlx сохраняется.
Миграций нет. Откат — выборочно вернуть эти изменения кода, тестов и документации,
не удаляя пользовательские данные.

## Продолжение: заметки инцидентов и изоляция тестов

`incident.update_note` использует GUI-сервис, требует подтверждения и проверяет
неизменность статуса, GUI и сохранённых данных. Заметка скрыта в audit arguments
агента и полностью видна оператору при подтверждении. Существующий GUI-журнал
инцидентов сохраняет текст заметки в `details`; это остаётся privacy-ограничением.
Legacy identity review в UI дополнительно сравнивает отображённое предложение
с сохранённым, однако отдельный legacy API не переведён на registry token.

В шести наборах ACTA-тестов пользовательские пути и Keychain заменены
синтетическими зависимостями. Изолированный запуск проверил 59 XCTest и
23 Swift Testing; полный suite по-прежнему не заявлен безопасным: остаются
non-ACTA fixtures и сценарии реальных потоков/устройств.
`settings.update_reid_calibration` не реализовано: GUI вычисляет рекомендацию,
а ранее указанные сохраняемые настройки отсутствуют. Экспорт отчёта требует
общего проверяемого UI-сервиса выбора пути; произвольная запись не включена.

Добавлено отдельное `reid.calibrate`: GUI и агент используют общий расчёт по
локальным размеченным парам; агент получает только агрегированные показатели
и не сохраняет порог. Подтверждение `incident.update_note` теперь объявляет
заметку обязательной, допускает пустую строку для очистки и ограничивает длину
исходной строки до 4000 символов.

Целевой изолированный прогон с ReID, заметками, alert, registry и выбранными
GUI/store fixtures: **64 XCTest + 24 Swift Testing, 0 ошибок**. Проверка
локализации и `git diff --check` прошли. Полный suite и оборудование не проверены.

Язык интерфейса подключён к тому же экземпляру `LanguageSettings`, что и GUI.
Он меняется отдельным вызовом, чтобы не смешивать записи в разные хранилища;
проверка `UserDefaults` подтверждает чтение в процессе, но не durability после
аварийного завершения. Переход инцидента с непустой заметкой теперь тоже
требует подтверждения; заметка в аргументах аудита скрывается.

`camera.reconnect` остаётся недоступным: существующий GUI путь не связывает
новые кадры с идентификатором попытки. `monitor.export_report_html` пока не
уточняет тип отчёта (операционный или отчёт миссий) и доверенное назначение.
Чтение номера не подключено: GUI OCR может сохранять evidence при включённой
настройке, а отдельное только-чтение не обеспечивало бы паритет этого поведения.

Финальная проверка этой волны (код возврата `0`): **69 XCTest + 24 Swift
Testing**, без ошибок:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAActionRegistryTests|ACTAIncidentSearchTests|ACTAIncidentNoteActionTests|ACTAAlertMutationActionsTests|ACTALegacyReviewIntegrityTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTACameraConfigurationActionTests|ACTAAnalyticsActionAdapterTests|ACTAMissionActionAdapterTests|ACTASettingsActionAdapterTests|ACTAReIDCalibrationActionTests|ACTASystemLanguageActionTests|IdentityTrackingTests.testValidationPairsNormalizeLabelsAndReplaceDifferentWithOperatorGroup|SettingsHubTests.testCentralSettingsApplyPortsAndAIConfigurationWithoutChangingCameras'
make -C native localization-audit
git --no-pager diff --check
```

Последние две проверки также вернули `0`; предупреждение SwiftPM о Cmlx
сохраняется. Phase 1 не завершена: полный inventory и непокрытые операции,
безопасный полный suite и проверка UI/устройств остаются открытыми.
В текущей матрице 30 строк помечены `PLANNED` или `GAP`; это не оценка
полного количества недостающих GUI-контролов, поскольку inventory не завершён.

`settings.run_health_check` использует общий с GUI in-app monitor, выдаёт
уникальную проверяемую квитанцию и сообщает о возможной записи истории.
История внедряется отдельно для тестов; обнаруженная до проверки повреждённая
или изменённая другим процессом история не перезаписывается. Проверка и запись
не образуют межпроцессную транзакцию. При ошибке записи действие
сообщает о возможном частичном изменении. Независимого фонового watcher оно
не создаёт; живые камеры и аппаратные сценарии не проверены.
Заметки скрываются и в кратком тексте запроса подтверждения; исходные параметры
всё ещё сохраняются в записи предложения для показа оператору.

Последующий прогон после подключения health check и изоляции двух дополнительных
fixtures: **78 XCTest + 24 Swift Testing, 0 ошибок** (код возврата `0`):

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAActionRegistryTests|ACTAIncidentSearchTests|ACTAIncidentNoteActionTests|ACTAAlertMutationActionsTests|ACTALegacyReviewIntegrityTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTACameraConfigurationActionTests|ACTAAnalyticsActionAdapterTests|ACTAMissionActionAdapterTests|ACTASettingsActionAdapterTests|ACTAReIDCalibrationActionTests|ACTASystemLanguageActionTests|ACTARunHealthCheckActionTests|IdentityTrackingTests.testValidationPairsNormalizeLabelsAndReplaceDifferentWithOperatorGroup|SettingsHubTests.testCentralSettingsApplyPortsAndAIConfigurationWithoutChangingCameras|TrackResearchTests.testEmptyHistoryAndEnablingPersistenceKeepTheCurrentConversation|StreamingTests.testPerCameraAnalysisFlagsPersistIndependently'
make -C native localization-audit
git --no-pager diff --check
```

Последние две проверки также прошли с кодом `0`. Полный suite не запускался.
В форме подтверждения параметры больше не свёрнуты по умолчанию; полная
визуальная проверка SwiftUI не проводилась. `settings.update_models` и
`settings.update_ai_budget` не подключены: первый требует защиты объекта пути
до отложенной загрузки, второй — строгой проверки типов и безопасного
сохранения privacy-настроек без потери конкурентных изменений.
Закрытие главы памяти не подключено: существующий GUI-путь освобождает
буфер до сохранения, а восстановление при ошибке не доказано.
Массовая очистка VLM-оповещений не подключена к агенту.

В следующей доработке GUI сначала сохраняет пустой список и только при успехе
очищает связанное состояние. Ошибки удаления клипов и отзывов показываются как
частичный результат; удаление файла клипа больше не подавляет ошибки. Записи
списка, индекса клипов, файлов и SQLite не образуют транзакцию: например, при
ошибке удаления каталога индекс уже может быть изменён. Восстановление после
частичного сбоя не доказано, поэтому `alert.clear_all` не опубликован.

Для вызовов реестра от модели сохраняется исходный JSON: типы, обязательные и
неизвестные параметры проверяются до подтверждения и исполнения с захватом
действия и схемы внутри actor. Недопустимые вызовы записываются в audit без
исходных аргументов; отсутствие audit store возвращает ошибку. Совместимость
legacy tools и отзыв токена при замене действия покрыты изолированными тестами.
Независимое ревью изменений JSON осталось заблокировано: reviewer не имел
доступа к diff; полная проверка не заявляется.

Расширенный изолированный прогон после этих изменений прошёл: **84 XCTest +
28 Swift Testing**, без ошибок. После добавления audit отклонённых вызовов
отдельно прошли **6 XCTest + 28 Swift Testing**, затем после дополнительных
тестов недоступного audit и удаления каталога — **8 XCTest**, без ошибок:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAJSONActionRegistryTests|ACTAModelGeneratedRegistryJSONTests|ClearVLMAlertsTests|UnifiedAgentHistoryTests.testFrameQuestionEntryUsesOneHistoryAgentEvenWithNoLiveCameras|ACTAActionRegistryTests|ACTAIncidentSearchTests|ACTAIncidentNoteActionTests|ACTAAlertMutationActionsTests|ACTALegacyReviewIntegrityTests|ACTAOperationalAdapterTests|ACTAServiceAdapterTests|ACTACameraConfigurationActionTests|ACTAAnalyticsActionAdapterTests|ACTAMissionActionAdapterTests|ACTASettingsActionAdapterTests|ACTAReIDCalibrationActionTests|ACTASystemLanguageActionTests|ACTARunHealthCheckActionTests|IdentityTrackingTests.testValidationPairsNormalizeLabelsAndReplaceDifferentWithOperatorGroup|SettingsHubTests.testCentralSettingsApplyPortsAndAIConfigurationWithoutChangingCameras|TrackResearchTests.testEmptyHistoryAndEnablingPersistenceKeepTheCurrentConversation|StreamingTests.testPerCameraAnalysisFlagsPersistIndependently'
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAModelGeneratedRegistryJSONTests|ACTAJSONActionRegistryTests|ClearVLMAlertsTests|ACTAActionRegistryTests'
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAModelGeneratedRegistryJSONTests|ClearVLMAlertsTests'
make -C native localization-audit
git --no-pager diff --check
```

Локализация и проверка diff прошли; полная тестовая серия не запускалась
из-за не полностью изолированных fixtures в общей пользовательской среде.

Независимая проверка операций идентичностей не обнаружила безопасного общего
контракта для публикации: устаревшие предложения могут ссылаться на удалённый
трек; последствия отмены слияния зависят от изменившегося графа; удаление
трека может завершиться частично; очистка номера не гарантирует удаление из
поискового индекса. Эти действия остаются недоступными агенту.

Последующий изолированный прогон с подготовленным, но не подключённым ISAPI
clear, проверкой главы и дополнительными изолированными fixtures: **95 XCTest +
30 Swift Testing**, без ошибок. `make -C native localization-audit` и
`git diff --check` прошли. В этом прогоне не использовались живые камеры,
Keychain или сетевой transport; полный suite по-прежнему не запускался.

Во время работы появился коммит `ed51491`, включивший временные файлы
`.isapi-validation-20261117/`; последующая очистка агентом оставила эти
отслеживаемые файлы в состоянии удаления. Позднее коммит `0c80b97` зафиксировал
их удаление; изменения пользователя не отменялись.

Независимое ревью новой очереди глав обнаружило проблемы privacy при ожидании
слота модели, восстановления после частичной записи JPEG, сверки с операторскими
правками, изменения privacy при повторе, dry-run и порядка кадров. Исправления
покрыты тестами, но повторное ревью выявило ещё три проблемы: отзыв разрешения
внешнего AI при ожидании permit, подтверждение уже записанной главы после
отключения retention и использование системных часов для watermark. Исправления
покрыты тестами; их независимая перепроверка выполняется.

Narrative flush теперь резервирует по камере batch со стабильным ID в RAM и
принимает новые кадры в отдельный буфер; допускается один in-flight flush на
камеру. Предел — один batch и до 28 активных кадров на камеру, без общего
лимита байт. При переполнении новые кадры не принимаются и GUI предупреждает.
Retry происходит при следующем предложенном кадре или ручном закрытии; если
кадры больше не поступают, автоматического таймера retry нет.

Перед повторной записью выполняется сверка SQLite и JPEG с сохранённым в RAM
ожидаемым результатом. Вставка не обновляет существующую запись; JPEG создаётся
эксклюзивно или используется только при полном совпадении. Конфликтующий или
неполный orphan JPEG не перезаписывается и может блокировать восстановление.
Отмена, ошибка и неоднозначный результат сохраняют batch в памяти процесса.
Последняя сводка обновляется только после проверки записи и JPEG; сравнение
дат нормализовано через SQLite Unix epoch. GUI не раскрывает детали исключения.

GUI проверяет актуальное разрешение памяти и сохранения JPEG после AI `await`
непосредственно перед синхронной записью; кэш AI для narrative отключён. Уже
отправленный AI-запрос нельзя отозвать. Перед отправкой narrative-запроса
разрешение и версия AI-конфигурации проверяются после получения background
permit и перед каждым dispatch, включая primary и backup в hybrid; изменение
конфигурации отменяет устаревшую попытку. Если разрешение
JPEG отозвано после commit, существующая запись и JPEG сверяются только чтением;
файл не удаляется автоматически. Произвольный внешний вызов координатора без privacy
callback использует переданный снимок настройки; это не проверенный общий
контракт. Ошибка, некорректный ответ модели и dry-run не фиксируются как готовая
глава: batch остаётся в RAM для retry.
Семантическая достоверность ответа модели не доказана. SQLite и JPEG не
составляют единую транзакцию, orphan-файлы возможны,
и сохранённые только в RAM batches не переживают завершение процесса. Немедленное
чтение не доказывает crash durability. Поэтому `memory.close_chapter_now` не
опубликован. Focused тесты используют изолированный SQLite и fake-model transport.

Повторная сверка не перезаписывает операторские пометки и учитывает только
неизменяемые поля и JPEG. При ошибке записи незавершённый JPEG удаляется только
до SQLite insert и после проверки совпадения inode; чужой файл или результат
неопределённого commit не удаляются. Проверка inode и unlink не атомарны против
враждебной замены пути другим процессом того же пользователя. При отсутствии
записи после отключения retention повторная вставка выполняется без JPEG, но
ранее созданный orphan намеренно не удаляется. Устаревший или повторный кадр
отклоняется отдельным результатом `staleFrame`; GUI показывает уведомление.
Focused фикстуры используют fake-model transport,
а не реальные устройства, сеть или Keychain.

Проверка narrative после очереди permit не является атомарной с передачей в
backend: политика или конфигурация могут измениться между проверкой и отправкой,
а уже отправленный запрос отозвать нельзя. Watermark и интервалы narrative
используют monotonic timestamp. При откате wall clock активная глава отделяется
в pending batch, а новый кадр поступает в отдельный active buffer. Если pending
уже занят, разделение невозможно: новый кадр отклоняется с явным backpressure,
а принятые кадры сохраняются в памяти для retry. Начало и конец новых глав —
даты первого и последнего кадров без регрессии. Ранее сохранённые главы не
изменяются. Модель по-прежнему генерирует event offsets без временных меток
отдельных кадров в prompt, поэтому точность самих offsets не гарантируется.
После отката часов сортировка по `ended_at` может выбрать более старую главу
как последнюю после перезапуска и исключить более новую из ограниченного
списка. Надёжный порядок создания исторически не сохранялся; исправление
требует отдельного решения по устойчивой последовательности и старым записям.
Alert ring, rate-limit
и dedup измеряют интервалы monotonic clock. Для несовместимого или
недекодируемого SQLite row reconciliation остаётся неподтверждённым.
Последний целевой запуск: **134 XCTest + 30 Swift Testing**, без ошибок,
включая события, temporal query, backpressure, reconciliation и privacy;
использовались изолированные фикстуры и fake transport.
Проверки `make -C native localization-audit` и `git diff --check` прошли.
Полный suite и визуальная проверка GUI не выполнялись.

GUI теперь запрашивает подтверждение удаления распознанного текста автомобиля
и предупреждает, что копии могут остаться в поиске. Полная очистка индексов и
агентское действие не реализованы; проверка изменений перед подтверждением
основана на состоянии в памяти и не является межпроцессной транзакцией.

Подготовлен отдельный helper для переподключения с идентификатором попытки,
timeout и проверкой атрибутированного свежего кадра; восемь fake-session тестов
прошли. `CameraSession` маркирует опубликованные кадры идентификатором сессии;
synthetic-frame тесты проверяют эту маркировку и остановку. Helper не подключён
к lifecycle камер: нужны отмена позднего запуска, ограничение времени регистрации relay и проверка
установленной сессии. `camera.reconnect` остаётся недоступным; реальное
оборудование не проверялось.

Последний изолированный прогон после изменений OCR и `CameraSession`: **138 XCTest
+ 30 Swift Testing**, без ошибок. Проверены сохранение и удаление только поля OCR
трека, сохранность поисковых таблиц и обработка отсутствующего трека. Полное
удаление копий OCR из индексов не реализовано. `make -C native localization-audit`
и `git diff --check` прошли. Полный suite, GUI и реальные устройства не проверялись.
Отдельно успешно проверены OCR removal с заполненным поисковым индексом и два
существующих теста сохранения/валидации vehicle evidence.

Дополнительная выборочная инвентаризация обнаружила неподтверждённое агентное
покрытие общего запуска камер, импорта источников, избранного, фильтров,
выделения и расстановки плиток, управления диалогами и отмены запроса.
Кандидаты перечислены в матрице; позднее `camera.set_favorite`,
`canvas.select_cameras`, `canvas.set_arrange_mode` и частично `canvas.set_filter` реализованы,
остальные агентные действия не подтверждены.

Добавлено `settings.update_ai_budget`: подтверждённое изменение настроек
размытия и бюджета через GUI-сервис с проверкой файла и конфигурации клиента.
Оно не предоставляет внешнему ИИ разрешения, не доказывает анонимизацию и не
гарантирует лимит расходов: учёт приблизительный и хранится в памяти.
Проверка файла и запись не являются межпроцессной транзакцией; ошибка после
записи может оставить файл и runtime несогласованными.
Изолированный прогон после этого изменения: **22 XCTest**, без ошибок, включая
три теста budget, две изолированные GUI-сервисные фикстуры и OCR/reconnect.
Аудит локализации и `git diff --check` прошли.

Добавлено `settings.update_ai_config` только для языка аналитических запросов
(`ru`, `en`, `he`), с подтверждением и проверкой настроек, feature policy и
конфигурации клиента. Остальные настройки AI backend остаются неподдержанными.
Оба действия используют неизменённый GUI save workflow: расписание сбрасывается
и при запущенных службах возможна подготовка моделей; это указано в подтверждении.
Расширенный focused прогон: **13 XCTest**, без ошибок, включая оба действия,
их взаимодействие и три изолированные GUI-сервисные фикстуры. Это не проверка
реальных моделей, сети или GUI.

Добавлено `camera.set_favorite`: агент и GUI используют общий формат настройки
избранных камер; проверяется текущее чтение предпочтения, но не синхронизация
на диск и не отображение в работающем GUI. Оба действия AI settings теперь
включены в каталог модели; их discovery проверяется тестами. Последний
изолированный прогон: **16 XCTest**, без ошибок, включая favorite и два
дополнительно изолированных теста чтения событий.

`camera.set_all_running` не опубликован: остановка `CameraSession` асинхронна,
а `WallModel.running` не подтверждает готовность потоков. Подменяемого
lifecycle/relay для полноценной изолированной проверки пока нет. Для ScreenCaptureKit
добавлено ограждение позднего запуска: если остановка произошла во время запуска,
после его завершения повторно запрашивается остановка; её ошибки логируются.
Шесть fake-тестов прошли, но завершение реальной остановки не подтверждено.
Повторная проверка `camera.reconnect` выявила другие блокеры: поздний relay
PATCH может завершиться после отмены, `AVCaptureSession` может стартовать после
stop, а GUI устанавливает сессию до свежего кадра. Relay timeout и установка
GUI-сессии не доказаны fake-тестами; действие остаётся неподключённым.

`memory.clear_all_frames` также не опубликован: подтверждение GUI не фиксирует
список кадров, индекс сохраняется до удаления JPEG, а ошибки удаления подавляются.
Журнал восстановления и межэкземплярная блокировка отсутствуют; загрузка
хранилища может удалять orphan-файлы. Тесты с реальными пользовательскими
файлами не проводились.

Последний целевой прогон: **28 XCTest**, без ошибок, включая screen lifecycle,
reconnect helper, favorite и AI settings; локализация и `git diff --check` прошли.

Добавлено `canvas.set_filter` для поиска, статуса, избранного и сохранённых
VLM/ISAPI событий через состояние единственного подключённого окна. Фильтр
местоположения и выбор камер действие не меняет; состояние может изменяться,
даже если в этом окне открыт другой раздел. Проверены состояние и логика
фильтрации, но не реальная отрисовка. Последний targeted прогон: **25 XCTest**,
без ошибок.

Дополнительно изолированы фикстуры заметок и поиска инцидентов и мутации
оповещений. Прогон этих шести тестов вместе с четырьмя тестами canvas:
**10 XCTest**, без ошибок; локализация и `git diff --check` прошли.
Полный suite по-прежнему небезопасен: есть другие неизолированные фикстуры и
smoke-тесты реальной модели.

Добавлено `canvas.select_cameras` для всех, ни одной или подмножества включённых
камер; снимок выбора и текущий набор камер проверяются перед подтверждением
результата. Живой GUI и подключения не проверялись. Целевой прогон: **24 XCTest**,
без ошибок. Тестовые пропуски миссий, предложенные при попытке изоляции, не
оставлены; запуск полного suite остаётся небезопасным.

Настройки AI backend/URL не добавлены: подтверждение не фиксирует исходное
состояние backend и feature policy, HTTP endpoint может получить существующий
ключ, а отложенная загрузка и уже выполняющиеся запросы не проверяются.

Добавлено `canvas.set_arrange_mode` для переключателя расстановки в единственном
подключённом окне. Настройка не сохраняется между запусками; фактическая
отрисовка и сохранение геометрии плиток не подтверждены. Последний targeted
прогон: **27 XCTest**, без ошибок. Проверка identity proposal показала, что GUI
может принять предложение с удалённым треком; межхранилищной атомарности нет,
поэтому действие не опубликовано.

Обнаружение моделей теперь допускает подмену в тестах без изменения
production-default. Фикстуры миссий используют временные хранилища и fake
discovery; все шесть тестов миссий прошли без пропусков. Совместный targeted
прогон с тестами discovery и canvas: **16 XCTest**, без ошибок. Реальные модели
и устройства не запускались.

Фильтр canvas дополнен выбором доступной группы расположения и очисткой выбора.
Проверяется актуальный набор включённых камер и состояние GUI, но не реальная
отрисовка. Дополнительно изолированы фикстуры настроек, сервисов, камер и
аналитики. Совместный targeted прогон: **30 XCTest**, без ошибок.
Дополнительно изолированы проверки очистки VLM-оповещений и два теста истории
чата: соответственно **4 и 2 XCTest** прошли. Очистка по-прежнему может
завершиться частично; это не доказывает recovery между хранилищами.
С отключёнными тестовыми моделями прошли ещё **7 XCTest** проверки мониторинга.
Изолированный тест запуска стены с отключённой синтетической локальной камерой
и тест поиска комплектного helper прошли: **2 Swift Testing**. Физическое
устройство и relay не запускались.

Прототип устойчивого порядка narrative-глав и его синтетические тесты были
отозваны: автоматический backfill не обеспечивал надёжного уведомления о
миграции. Порядок после отката часов и перезапуска, crash durability
JPEG/SQLite и действие принудительного закрытия остаются открытыми.
Поздний отказ разрешения камеры больше не меняет статус остановленной сессии;
полный reconnect и его остановка остаются неподтверждёнными.

Добавлено `canvas.set_presentation` (grid/list в единственном окне); отрисовка
не проверена. Попытка подключить `speechEnabled` отозвана: общий AI-клиент
может отправить контекст во внешний backend, а подтверждение не фиксировало
смену backend. Дополнительно изолированы operational fixtures. Предыдущий
совместный targeted прогон после отката: **37 XCTest**, без ошибок; аудит локализации
и `git diff --check` прошли.
Прямое изменение геометрии плитки не подключено: текущая запись всего layout
может затереть изменения другого процесса или незавершённое перетаскивание.
Массовое удаление кадров также не подключено: старые процессы не соблюдают
межэкземплярную блокировку и могут перезаписать индекс или удалить новый JPEG.

При проверке отозванного прототипа narrative агент запустил также
`testModelFailurePreservesBatchForRetry` с backend `mlxInProcess`. В этом тесте
`localVLM` не задан; `callMLX` возвращает ошибку до обращения к модели. Это
не считается подтверждением работы реальной модели.
Повторный изолированный прогон narrative после отката миграции: **25 XCTest**,
без ошибок; регрессия аналитики и памяти: ещё **13 XCTest**, без ошибок.

Обновление: агентский inference теперь допускает только явно выбранный MLX
внутри процесса; cloud, hybrid и HTTP vLLM отклоняются без fallback. Это
ограничение маршрутизации, а не сетевая изоляция инструментов или ОС;
совместимость реальной модели не проверена. Обычные неагентские AI-вызовы
сохраняют собственные правила. Проверка использовала только подставной inference
и транспорт без реальных запросов.

GUI reconnect сетевой камеры ожидает свежий кадр новой сессии, а поздний
PATCH изолируется уникальным именем relay. Старые регистрации могут оставаться
до перезапуска, после 64 попыток требуется перезапуск видеостены.
`camera.reconnect` опубликован для включённых сетевых камер запущенной
видеостены; успех требует свежего кадра и проверки актуальной сессии.
Отмена ограждает поздний запуск decoder. `Go2RTC.stop` не ожидает выхода
процесса блокирующим вызовом; резервирование портов внутри процесса сохраняется
до уведомления о завершении, ожидание ограничено. Локальные источники,
реальная сеть и завершение реального go2rtc не проверены; межпроцессная
эксклюзивность портов не гарантируется. Targeted-прогон reconnect, lifecycle
и адаптера: **40 XCTest**, без ошибок, только с подставными зависимостями.

Удаление кадров в GUI привязано к снимку индекса; добавлены журнал, явное
восстановление и advisory lock. Старые процессы lock не соблюдают, а
устойчивость к потере питания не доказана. Массовое агентское удаление
не опубликовано. Дополнительная проверка очистки обнаруживает новые записи,
повторно созданные файлы и незавершённое восстановление; снимок не фиксирует
байты изображений. Изолированные тесты хранилища: **16 XCTest**, без ошибок.
Проверка identity отклоняет изменённые треки и снимок
графа. Совместимые записи feature policy используют advisory lock и ревизию;
занятый lock возвращает ошибку без ожидания. Старые процессы могут обходить
lock, а crash-атомарность разных хранилищ не доказана; action не опубликован.
Добавлены подготовка решения по ID и
проверка сохранённого решения, связей и аудита; **20 XCTest**, без ошибок.

Совместный targeted прогон этих изменений: **68 XCTest**, без ошибок;
локализация и `git diff --check` прошли. Реальные устройства, сеть,
Keychain, установленная модель и полный suite не проверялись.

Добавлено `settings.retry_model_loading`: повторяются только отказавшие
включённые модели через общий runtime; успех означает готовность подготовки,
а не проверку inference. Уже выполняющийся loader может продолжить работу
после отмены. Прогон action, настроек и локального агентского сценария:
**16 XCTest**, без ошибок, с подставными загрузчиками.

Добавлено `analysis.set_section`: выбор вкладки Chat, Schedule или Alerts в
единственном окне без открытия панели и обновления заданий. Переход из Chat
отклоняется во время запуска или записи диктовки. Проверка состояния, включая
существующие фильтры и регистрацию action: **11 XCTest**, без ошибок;
фактическая отрисовка не проверена.

После ограничения agent inference обновлены регрессионные тесты retrieval,
истории и интеграции под подставной MLX. Отдельно проверено, что поздний
ответ отменённого запроса не добавляется в чат: **9 XCTest**, без ошибок.

Поиск GUI по описаниям проверен на 503 синтетических треках: совпадения
за пределами последних 500 находятся и подсчитываются. Agent action для
этого поиска не опубликован: контекст action не содержит авторизации чтения
истории. Для существующего `search_tracked_objects` поисковый запрос теперь
редактируется в аудите, не меняя результаты. Итоговый совместный
прогон новых действий и связанных регрессий: **35 XCTest**, без ошибок.
Повторная проверка local-only agent, retrieval, model retry и диктовки:
**25 XCTest**, без ошибок с подставными зависимостями.

Для очистки оповещений подготовлены планирование и журнал восстановления
с проверкой снимков хранилищ; **11 тестов** прошли на подставных хранилищах
и изолированном GUI-сервисе. Agent action не опубликован: реальные хранилища
ещё не поддерживают общую блокировку и атомарную замену данных.

Реестр поддерживает привязку подготовленного снимка и текста проверки к
одноразовому токену. Экран подтверждения показывает этот текст и проверяет
его совпадение до выполнения; подтверждение подготовленного снимка без
точного текста отклоняется. Число ожидающих подтверждений ограничено.
Подготовлены, но не опубликованы действия массового удаления и восстановления
кадров, экспорта снимка, заданий описания и геометрии плитки: их производственные
зависимости ещё не обеспечивают безопасной изоляции и проверки. В canvas
совместимые записи используют ревизии и сохраняют конфликтный черновик для
повтора, но старые процессы обходят блокировку, а при закрытии canvas черновик
теряется. Совместный targeted-прогон: **140 XCTest и 52 Swift Testing**, без ошибок;
реальные камеры, графический интерфейс, сеть и полный suite не проверялись.
Дополнительная проверка существующих действий canvas и GUI-сервиса:
**17 XCTest**, без ошибок.

Команды последней проверки (код выхода 0):

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAActionRegistryTests|ACTAOperationalAdapterTests/testTokenReviewClaimsProposalAndExecutesOnce|ACTACameraMemoryClearActionTests|ACTACameraMemoryRecoveryActionTests|CameraMemoryDeletionTests|CameraMemoryStoreTests|CrossCameraIdentityReviewServiceTests|FeaturePreferencesTests|CameraFeatureCoordinatorTests|ACTASettingsActionAdapterTests|ACTASnapshotExportFoundationTests|ACTASnapshotActionTests|ACTAAlertClearRecoveryTests|ClearVLMAlertsTests|ACTACanvasGestureTrackerTests|ACTACanvasLayoutStoreTests|ACTACanvasTileDraftTests|ACTACanvasTileFrameActionTests|VideoInteractionTests|ACTADescriptionJobActionsTests|Go2RTCLifecycleTests|CameraReconnectIntegrationTests|CameraReconnectAttemptTests|CameraSessionProvenanceTests'
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAAnalyticsActionAdapterTests/testCanvasActionsShareGUIStateAndVerifySavedLayout|ACTAServiceAdapterTests/testActionsApplyToLiveModelAndPersistThroughGUIService|ACTACanvasFilterActionTests|ACTACanvasPresentationActionTests|ACTACanvasArrangeActionTests|ACTACanvasSelectCamerasActionTests'
env -u ACTA_TEST_CRASH_RECOVERY_ROOT swift test --package-path native --skip-build --filter CameraCoreTests
make -C native localization-audit
git diff --check
```

`settings.update_reid_calibration` изменяет только временное значение ползунка
в единственном открытом представлении, проверяет шаг 0,005 и не применяет
порог. Регистрация, каталог и проверки состояния: **10 XCTest**, без ошибок;
фактическая отрисовка и обновление метрик не проверены. Навигационное action
не опубликовано: сохранность диалогов и состояния при смене раздела не доказана.
Регрессионный прогон ReID, регистрации, вкладок анализа и диктовки:
**21 XCTest**, без ошибок:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAReIDCalibrationActionTests|ACTAServiceAdapterTests/testActionsApplyToLiveModelAndPersistThroughGUIService|ACTAAnalysisSectionActionTests|LocalVoiceInputLifecycleTests'
```

Диктовка теперь отменяет ожидающий запуск при уходе из Chat и игнорирует
поздние разрешения и callbacks. Проверены **17 XCTest** с подставными
разрешениями и захватом; реальный микрофон и системный диалог не проверялись.

Дополнительно изолированно проверен CameraCore из обновлённого тестового
бинарника: **190 XCTest и 53 Swift Testing**, без ошибок. Весь CameraWall suite
и реальное оборудование при этом не запускались.

## Продолжение Phase 1: идентификаторы источников и защита снимков

`camera.edit` теперь поддерживает изменение идентификатора существующего
отключённого local/screen-источника, когда стена и обработка камер остановлены.
Проверены сохранение, readback и аудит на изолированных фикстурах; доступность
устройств и реальный захват не проверялись.

Удаление текста автомобиля в GUI теперь сравнивает подтверждённое evidence с
записью SQLite и использует условное обновление, не удаляя более новую запись.
Удаляется только поле трека: копии в поисковых индексах остаются. Агентское
действие не опубликовано; авторизация и полная семантика удаления не доказаны.

Для геометрии canvas добавлен provider и изолированные проверки состояния,
конфликтов и жизненного цикла. Действие не зарегистрировано: старые процессы и
жесты других процессов обходят координацию. Для повторного запуска description
job добавлены проверка ревизии и транзакционная квитанция (аддитивная миграция
SQLite до версии 7); проверены конфликт, отмена и повторное открытие хранилища.
Действие не зарегистрировано: доверенная авторизация и интеграция с production
provider не реализованы, старые записи политики могут обходить блокировку.
При первом открытии существующая база feature jobs обновляется до версии 7.
Старая сборка, поддерживающая только версию 6, откажется открыть её; откат
бинарника без восстановления совместимой резервной копии не проверен.

Проверка изолированных тестов: **50 XCTest**, без ошибок. Реальные камеры, GUI,
модели и полный набор тестов не запускались. Phase 1 остаётся незавершённой.
Дополнительные **7 XCTest** проверили настоящий переход тестовой базы с версии
6 на 7, отмену транзакции, сохранность квитанции и отказ GUI-модели удалять
текст, изменённый другим соединением. Они не являются проверкой отрисовки GUI.

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'CameraFeatureStoreTests|CameraFeatureCoordinatorTests|VehicleTextRemovalSafetyTests|VehicleTextRemovalReviewTests|ACTACameraConfigurationActionTests|ACTACanvasTileFrameActionTests|ACTACanvasTileFrameProviderTests|ACTADescriptionJobActionsTests'
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'VehicleTextRemovalSafetyTests|VehicleTextRemovalReviewTests|CameraFeatureStoreTests/testVersionSixJobsGainRevisionsAndRetryReceipts|CameraFeatureStoreTests/testDescriptionRetryRejectsStaleRevisionAndCommitsReceiptAtomically|CameraFeatureCoordinatorTests/testDescriptionRetryRejectsChangedFeaturePolicy'
make -C native localization-audit
git diff --check
```

Дополнительно подготовлены изолированные основы:

- Отдельный opt-in реестр с локальными capabilities и их отзывом. Существующий
  production/shared реестр им не заменён и не получил авторизацию; нужен
  доверенный broker, подключение GUI и аудит. Это не граница безопасности ОС.
- Вызовы модели теперь сверяются с каталогом конкретного запроса и действующим
  allowlist; нерекламируемые имена и альтернативные transport-имена отклоняются
  с аудитом без аргументов. Это ограничение каталога не заменяет авторизацию.
- Журнал закрытия главы с транзакционным сохранением и повторной сверкой.
  GUI и agent action не подключены; политика хранения чувствительных входных
  данных и восстановление после реального сбоя не доказаны.
- Проверка identity обычного файла модели через descriptor и hash. Она не
  подключена к path-based загрузчикам и не защищает каталоги моделей.
- Provider снимка проверяет свежесть при выборе кадра и удерживает полученные
  JPEG-байты на время подтверждения, не требуя остановки потока. Пиксели BGRA
  и NV12 копируются перед асинхронным кодированием. Операция не опубликована:
  посторонняя запись во время копирования и атомарность production-записи не
  исключены; отклонённое подтверждение может удерживать ограниченные ресурсы.

Изолированный прогон этих основ: **10 XCTest и 39 Swift Testing**, без ошибок:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAActionRegistryTests|SelectedModelFileIdentityTests|ACTANarrativeCloseJournalTests'
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTASnapshotExportFoundationTests|ACTASnapshotActionTests|ACTASnapshotFrameProviderTests'
```

Проверка основы снимков: **28 Swift Testing**, без ошибок; реальные камеры и
публикация через production backend не проверялись.

Проверка каталога модели, аудита, адаптеров и реестра: **22 XCTest и
39 Swift Testing**, без ошибок:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAModelGeneratedRegistryJSONTests|ACTAIncidentSearchTests|ACTACameraConfigurationActionTests|ACTAServiceAdapterTests|ACTAActionRegistryTests'
```

Критичные классы реестра теперь требуют подтверждения даже если конкретный
action ошибочно его отключает. Дополнительная регрессия адаптеров и реестра:
**37 XCTest и 41 Swift Testing**, без ошибок:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAActionRegistryTests|ACTAAnalyticsActionAdapterTests|ACTASettingsActionAdapterTests|ACTAServiceAdapterTests|ACTAModelGeneratedRegistryJSONTests|ACTAOperationalAdapterTests'
```

Подготовлен local broker: в нём все модельные мутации требуют подтверждения
и действуют сессионные capabilities. Изначально он не был подключён; текущее
ограниченное подключение и оставшиеся legacy-пути описаны в начале отчёта.
Первоначально проверены **48 Swift Testing и 2 XCTest** на синтетических действиях:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTALocalActionBrokerTests|ACTABrokerReviewViewTests|ACTAActionRegistryTests'
```

`incident.get` дополнен сроком подавления инцидента из GUI domain service.
Свободный текст и evidence не раскрываются. Изолированная проверка:
**5 XCTest**, включая повторное чтение после изменения статуса.

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter ACTAIncidentReadActionsTests
```

`settings.update_system` явно отклоняет неподдерживаемые порты и путь,
нечисловые и неконечные значения; сохранено ограничение числовых диапазонов.
Несовпадение конфигурации с диском обнаруживается при чтении, но проверка и
запись не образуют межпроцессную CAS. Проверены **16 XCTest и 41 Swift Testing**:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTASystemPortActionTests|ACTASystemLanguageActionTests|ACTASettingsActionAdapterTests|ACTAActionRegistryTests'
```

`analytics.set_restricted_zone` поддерживает как прямоугольники, так и простые
полигоны с нормализованными координатами; некорректная геометрия отклоняется
до сохранения. Сырые ответы локальной модели больше не записываются в
`agentTrace`. Проверены **26 XCTest** для аналитики, приватности, инцидентов
и каталога вызовов:

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTAAnalyticsActionAdapterTests|ACTAAIAgentPrivacyTests|ACTAModelGeneratedRegistryJSONTests|ACTAIncidentReadActionsTests'
```

`camera.reconnect` для файловых источников планирует перезапуск и проверяет
замену сессии, не утверждая успешное воспроизведение или получение кадра.
Обновление устаревшего bookmark при агентском вызове не сохраняется; GUI сохраняет
прежнее поведение. Отмена после замены не восстанавливает прежнюю сессию.
Реальное воспроизведение, stale bookmark и local/screen источники не проверены.

HTML отчёта миссии получил CSP, а операционный отчёт сообщает об ограничении
числа строк. Два теста рендереров прошли; агентский экспорт не подключён:
доверенное назначение и безопасная публикация ещё не реализованы.

Для удаления трека подготовлен неподключённый журнал с проверкой снимка и
повторной очисткой crop-файлов. Проверка: **9 XCTest**, включая stale state,
partial failure и замену файла. Он не подключён к GUI или агенту: старые
процессы обходят координацию, восстановление при запуске отсутствует, а
производные индексные копии не удаляются.

```sh
swift test --package-path native --disable-automatic-resolution --jobs 2 --filter 'ACTATrackDeletionJournalTests|VehicleTextRemovalSafetyTests'
```
