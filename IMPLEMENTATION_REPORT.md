# ACTA — отчёт о выполнении Phase 1

Дата: 2026-11-17. Статус: частичная реализация, приёмка Phase 1 не завершена.

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
