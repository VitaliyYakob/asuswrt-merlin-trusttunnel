# Фактически выполненные проверки — 0.1.0-alpha.1

## Локальный результат

| Проверка | Результат |
|---|---|
| `make test` — Python unittest | **PASS: 53 теста**, включая наборы отрицательных входных вариантов внутри subtests. |
| Синтаксис shell через sh и BusyBox ash | PASS, включено в unittest. |
| Синтаксис JS через `node --check` | PASS. |
| `tests/test_web.js` | **PASS: 10 assertions**. |
| Browser smoke test | PASS: Chromium, DOM/кнопки/подтверждение IPv6, 0 JS errors и 0 network requests. |
| Визуальный просмотр screenshot | Выполнен; текст/поля/кнопки читаются, перекрытий не обнаружено в проверенном viewport. |
| ShellCheck | **NOT RUN** локально; инструмент отсутствовал. |
| GitHub Actions | **NOT RUN**; workflow только добавлен в исходники, удалённый репозиторий не публиковался. |
| TrustTunnel executable, TUN traffic, реальный TLS/HTTP2/HTTP3 | **NOT RUN**. |
| ASUS/Merlin WebUI integration, firewall/IPv6/DNS leak tests | **NOT RUN**. |

## Среда

- Python 3.13.5
- v22.16.0
- jq-1.7
- BusyBox v1.37.0 (Debian 1:1.37.0-6+b8) multi-call binary.
- Browser output: `PASS: Chromium 144.0.7559.96; DOM/actions/IPv6 acknowledgement; 0 page errors; 0 network requests`

Browser smoke test подавал самодостаточный preview HTML через Playwright `set_content`, а не в реальный httpd Merlin. Это не проверка ASP tags, авторизации, CSRF или применения router events. Стандартный Playwright browser binary в окружении отсутствовал; использован установленный Chromium. Навигация `file://` в окружении запрещена политикой браузера, поэтому отдельно не заявляется как проверенная здесь.

## Что проверено моделью сетевых команд

Повторный guard без дубликатов, сохранение prohibit/default protection при down, снятие только собственных ресурсов, отказ на существующую routing table/priority, отказ после ошибки restore до policy rule creation, сохранение чужого конфликтующего правила, восстановление рабочего default route при живом процессе и перестановка guard перед сторонним ACCEPT.

`tests/mock_net.py` — recorder и модель команд/объектов. Это **не Linux kernel, не эмулятор ASUS и не packet simulator**. Тесты не могут доказать соответствие моделей синтаксису конкретного iptables в Merlin или отсутствие leak windows.

## Найдено и исправлено во время локальной проверки

Синтаксис JQ плана; ошибочное скрытие ошибки первой команды pipeline; сравнение executable path при /opt symlink; восстановление потерянного TUN-маршрута без гибели процесса; место guard jump после вставки стороннего ACCEPT. Секретный amng_custom вообще не используется, а на start/pause shared-settings field исключён из POST.

Полный вывод: `test-output.txt`, `browser-test-output.txt`. Аппаратная матрица H01–H17 — `HARDWARE-TESTS.md` (всё NOT RUN).
