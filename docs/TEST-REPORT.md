# Фактические проверки 0.3.0-alpha.1

Дата: **20.09.2026**. Проверялась рабочая копия проекта, без SSH и без реального роутера. Исходный Template не используется как доказательство готовности этой версии.

| Проверка | Результат |
|---|---|
| `make test`, Python unittest | **PASS — 134 теста**, 109.243 с; дополнительные отрицательные варианты внутри subtests. |
| POSIX sh / настоящий BusyBox ash: синтаксис | PASS, входит в unittest. |
| JavaScript syntax и policy/connection | PASS — 19 групп маршрутизации и 33 группы подключения. |
| Web Crypto → OpenSSL CLI | PASS — 6 групп: полный импорт, повтор, конфликт ревизии, повреждённый OAEP, привязка к сессии, все 256 значений байта, Unicode и очистка по сроку. |
| Транзакции с моделью сетевых команд | PASS — 11 сценариев, включая endpoint/policy, подтверждение, срок, ошибку запуска, паузу, rollback, reboot-модель, чужие ресурсы и возврат rp_filter исключённой сети. |
| `make lint`, ShellCheck 0.10.0 | **PASS** для warning/error severity по entry points с sourced libraries. Информационные замечания не входят в этот gate. |
| `make preview` | PASS, автономный HTML с четырьмя вкладками. |
| Chromium / Playwright, 1280 и 390 px | PASS; формы, DNS, экспорт с 14 серверными валидациями, SSID, subset, выбор /32 и локальных исключений, неизменяемый bridge, IPv6 acknowledgement, активная политика и блокировка при pending transaction. Нет горизонтального переполнения, ошибок JS и HTTP-запросов из offline preview. |
| Браузер с имитацией HTTPS роутера | PASS; JSON-файл → зашифрованные native events → подтверждённое сохранение. Проверены отсутствие plaintext в форме/статусе, очистка формы после успеха, сохранение ввода при конфликте ревизий. Это НЕ Merlin httpd. |
| Визуальная проверка | Выполнена для desktop/mobile screenshots: вкладки и табличные формы в стиле пользовательского референса Merlin, подписи и элементы не перекрываются. |
| Исходный пакет | PASS — ZIP/TAR.GZ, 86 файлов, SHA-256 и целостность архивов; исключены Template/Git/private key/runtime-конфигурации. |
| Проверка подписей релиза | **Только control-flow PASS с GPG stub**: pinned fingerprint, другой подписант, ошибка GPG. Настоящие binary/signature и GnuPG **NOT RUN**. |
| GitHub Actions | **NOT RUN**; обновлено только локальное определение CI. |
| Linux packet-flow / TrustTunnel TLS/TUN / DNS / IPv6 / HND | **NOT RUN**. Модель команд не подтверждает передачу пакетов. |
| Настоящий Merlin HTTPS/auth/CSRF/service-event, AX86U | **NOT RUN**, по согласованной границе задачи. |

## Что подтверждают новые проверки

Конфигурация не изменяется от неполной или испорченной передачи. Применение использует полностью принятый документ и проверяет ревизию под lock. Повтор ID не запускает действие второй раз в пределах runtime-истории. Шифрованные команды не превышают native limit; ключи и plaintext остаются в приватных файлах, удаляются после завершения/отказа/срока.

Модель проверяет trial guards для объединения старых/новых сетей, удержание удалённых источников до подтверждения, восстановление обеих конфигураций и paused intent. Ошибка восстановления оставляет quarantine/journal. Reboot-модель с пустой таблицей восстанавливает прежнюю политику, а с неизвестными занятыми ресурсами отказывает. Backoff пропускает попытку клиента, но восстанавливает guards.

Schema4 требует identity сети; SSID rename его не меняет, изменение членов bridge меняет. Локальные исключения ограничены каноническими private CIDR и обнаруженной топологией. Планы используют RETURN к фильтрам Merlin и маршруты только в 871. Несколько локальных маршрутов сохраняются при reconcile и удаляются адресно при disarm.

Предыдущие регрессии DNS/tt://, X.509, резервов, прав доступа, инъекций и сохранения чужих hooks/settings/rules продолжают проходить.

## Среда и воспроизведение

macOS arm64; Python **3.14.7**, Node **22.23.1**, jq **1.7.1-apple**, BusyBox **1.37.0**, flock **0.4.0**, ShellCheck **0.10.0**, Playwright **1.62.1**, Chromium **151.0.7922.34**. OpenSSL CLI в runtime PATH: **LibreSSL 3.3.6**. Это не OpenSSL/BusyBox целевого роутера.

Временное окружение: `/private/tmp/ttm-host-tests.wJHyq1/env.sh`. В нём находятся собранные host tools и browser; глобальная установка не менялась. Происхождение и сборка: [HOST-TEST-ENVIRONMENT.md](HOST-TEST-ENVIRONMENT.md). Chromium требует разрешения macOS IPC; все browser requests ограничены offline preview или локальной имитацией router.test.

Повтор: `make test`, `make lint`, `make browser-test`, `make package`. Полные журналы: [test-output.txt](test-output.txt), [browser-test-output.txt](browser-test-output.txt). Аппаратная матрица H01–H35: [HARDWARE-TESTS.md](HARDWARE-TESTS.md).

## Предел вывода

Ни один локальный результат не объявляет AX86U защищённым от утечек. Перед реальной эксплуатацией нужны проверка настоящих событий/авторизации, пакетные наблюдения с выбранных и невыбранных устройств, guest isolation, перезапуск firewall/WAN/Entware и HND. Полный VPN health check пока отсутствует: статус всегда `connection_verified:false`.
