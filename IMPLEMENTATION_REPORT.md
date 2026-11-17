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

1. Подключить реальные сервисы вместо отключённых incident/memory/watch adapters; добавить остальные операции из инвентаря (создание/редактирование камер, thresholds/overrides, missions, остальные разделы настроек).
2. Завершить авторизацию, единый audit для прямых GUI/domain вызовов, idempotency keys, deadlines, recovery/compensation. ACTION_BUSY предотвращает одновременные записи через реестр, но не является очередью или долговременной дедупликацией.
3. Проверить поведение настоящего Qwen с каталогом и подтверждениями; измерить влияние дополнительных шагов модели на задержку. Скриптовый transport этого не доказывает.
4. После перезапуска pending tokens в памяти отсутствуют: операция не исполняется, требуется новое предложение. Долговременное восстановление токенов не реализовано.
5. `camera.reconnect` не рекламируется в каталоге: подтверждение реального восстановления потока ещё не реализовано; default verification для мутаций теперь fail-closed.
6. Дополнить инвентарь всех UI controls и parity tests; провести регрессию и воспроизводимую проверку GUI.

Phase 2–4, TTS, vLLM Metal, выбор checkpoint и нагрузочные измерения не выполнены. Полное покрытие функций не заявляется.

## Рекомендуемая точка продолжения

Продолжать Phase 1 с реальных incident/memory/watch service adapters и их parity tests, затем расширять каталог только проверенными действиями. До этого не переходить к заявлению полного управления или завершению Phase 1. Настоящий Qwen, vLLM Metal, TTS и hardware/performance gates остаются следующими отдельными этапами с исходными ограничениями prompt.
