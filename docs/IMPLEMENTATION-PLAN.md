# Согласованные изменения alpha.13 — 18.10.2026

Исходное состояние: alpha.12/bf975f1. Пользователь разрешил реализацию предложенных исправлений и доработок.

| Направление | Реализация | Приёмка |
| --- | --- | --- |
| Сохранение политики / display-only поля | Синхронизация clean form, сохранение revision dirty draft, conflict banner, показ пароля не dirty | Offline + browser |
| Сохранённый профиль | Карточка, partial protocol/MTU/anti_dpi, private merge, прежняя transaction | Offline + encrypted browser model |
| Сети / исключения | Явные режимы с черновиками и подтверждением; отдельные SSID; add/remove, подтверждение URL → домен | Browser |
| Операции / диагностика | Progress, проверка прежнего operation ID, session errors, Date от роутера, RSS/CPU, allowlisted export | Offline + browser |
| Установка | Bounded preflight, complete staging, code/config/init/UI rollback, private retained backup | Filesystem tests; hardware NOT RUN |
| Время / журнал | Uptime + boot ID, conservative legacy recovery; bounded FIFO consumer | Offline; performance/hardware NOT RUN |
| CLI | Trial 300 s, confirm/rollback, сохранение guards, отдельный downgrade | Offline; hardware NOT RUN |
| Поставка | Manifest + source identity, exact-commit full CI prerequisite, signed GitHub/Sigstore attestation workflow | Local package; remote NOT RUN |
| Доступ | Read-only anonymous checker; на alpha.12 ASP/JSON возвращают login | Anonymous GET only; full CSRF/WAN NOT RUN |

До установки alpha.13 на единственный роутер: сохранить текущие code/config/CLI и план возврата, выделить гостевую сеть, обеспечить доступ по основной. Выполнить controlled CLI trial/expiry/confirm/rollback, а затем IPK/hotfix → IPK при выключенном VPN. Новая версия не получает аппаратные PASS от предыдущих alpha.

Отдельные ворота выхода из alpha: clean IPK и failed postinst/reconfigure, DNS/IPv6/WAN capture при crash/pause/firewall/WAN reload, уже ускоренные HND-потоки, delayed/missing USB и ранняя загрузка. Раннюю firmware-only защиту проектировать после подтверждения окна; она не добавляется предположительно. Полная CSRF/session/WAN матрица и затраты FIFO/metrics требуют реальной среды. Linux namespace/packet tests остаются отдельным незавершённым направлением; мок-счётчики их не заменяют.

Обновление самого аддона кнопкой и расширение нескольких профилей/GeoIP/IPv6 — последующие этапы после проверки штатной IPK-поставки и восстановления. Публикация/перезапись тегов/замена работающего аддона в текущем локальном этапе не выполняются.

Исторический план alpha.3 доступен в Git; фактические результаты текущего этапа — в TEST-REPORT.md.
