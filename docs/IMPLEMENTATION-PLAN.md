# Приёмка и выпуск alpha.13 — 18.10.2026

Исходное состояние: alpha.12/bf975f1. Пользователь разрешил реализацию предложенных исправлений и доработок.

| Направление | Реализация | Приёмка |
| --- | --- | --- |
| Сохранение политики / display-only поля | Синхронизация clean form, сохранение revision dirty draft, conflict banner, показ пароля не dirty | Offline + browser |
| Сохранённый профиль | Карточка, partial protocol/MTU/anti_dpi, private merge, прежняя transaction | Offline + encrypted browser model |
| Сети / исключения | Явные режимы с черновиками и подтверждением; отдельные SSID; add/remove, подтверждение URL → домен | Browser |
| Операции / диагностика | Progress, проверка прежнего operation ID, session errors, Date от роутера, RSS/CPU, allowlisted export | Offline + browser |
| Установка | Ограниченное чтение NVRAM, подготовка файлов, возврат кода/config/init/UI, приватный резерв, зависимость mkfifo | Автономно + IPK upgrade на AX86U; внутренние ошибки postinst ещё не проверены |
| Время / журнал | Uptime + boot ID, возврат старого журнала; ограниченный потребитель FIFO | Автономно; обычный запуск и начальные метрики на AX86U; длительная нагрузка не проверена |
| CLI | Trial 300 s, confirm/rollback, сохранение guards, отдельный downgrade | Offline; hardware NOT RUN |
| Поставка | Manifest + source identity, exact-commit full CI prerequisite, signed GitHub/Sigstore attestation workflow | Local package; remote NOT RUN |
| Доступ | Read-only anonymous checker; на alpha.12 ASP/JSON возвращают login | Anonymous GET only; full CSRF/WAN NOT RUN |

18.10.2026 на AX86U установлена alpha.13 из IPK: версии пакета/runtime/UI совпадают, конфигурация и CLI сохранены, проверены правила и двусторонний трафик. Сохранён приватный резерв и команда возврата; основная сеть оставалась доступной. Первоначальная сборка выявила отсутствующий mkfifo и прошла внешний автоматический возврат к прежнему пакету/VPN. Это не приёмка новых внутренних ветвей возврата установщика или CLI; их проверять отдельно.

Отдельные ворота выхода из alpha: clean IPK и failed postinst/reconfigure, DNS/IPv6/WAN capture при crash/pause/firewall/WAN reload, уже ускоренные HND-потоки, delayed/missing USB и ранняя загрузка. Раннюю firmware-only защиту проектировать после подтверждения окна; она не добавляется предположительно. Полная CSRF/session/WAN матрица и затраты FIFO/metrics требуют реальной среды. Linux namespace/packet tests остаются отдельным незавершённым направлением; мок-счётчики их не заменяют.

Обновление самого аддона кнопкой и расширение нескольких профилей/GeoIP/IPv6 — последующие этапы. Публиковать alpha.13 после полного CI точного коммита, проверки подписи/хешей файлов и описания границ аппаратных испытаний; опубликованные теги не перезаписывать.

Исторический план alpha.3 доступен в Git; фактические результаты текущего этапа — в TEST-REPORT.md.
