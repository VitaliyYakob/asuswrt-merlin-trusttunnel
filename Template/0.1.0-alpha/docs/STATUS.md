# Состояние проекта

## P0 — сделано в 0.1.0-alpha.1

Исходный код контроллера и native WebUI, приватная конфигурация, валидаторы, TOML generation, declarative network plans и их исполнитель, hooks/init/reconcile, status, lab-only installers, offline preview, тестовый набор. Это не только схема каталогов и не набор заглушек; при lab-only запуске backend выполняет реальные команды. Вместе с тем binary/пакетная передача/прошивка не испытаны.

## P1 — продолжение возможно без роутера

Тесты аварийных путей installer/menu rollback, process lifecycle на эмуляторе файловой системы, рандомизированные проверки валидаторов, richer schema diagnostics без раскрытия credentials, защита от конкурентного сохранения общих Addons settings, упаковка исходников в IPK с корректными pre/post scripts. Проверить shutdown во время работы USB init. Привязать CI actions к проверенным commit SHA перед публикацией.

Для полного ввода credentials в WebUI нужен отдельно спроектированный безопасный transport приватных данных через штатный httpd, без долгого хранения в общих custom_settings и без отдельного web-сервиса. Нельзя просто добавить password field в существующий policy envelope.

## P2 — аппаратные release blockers

Пройти H01–H17. Особенно bootstrap gap до доступности jq/Entware, firmware firewall rebuild, hardware acceleration, маршрутизация upstream клиента, TUN/NAT возврат, DNS/IPv6 и доступ к HTTP resources. Только после этого менять alpha-ограничения или делать заявления о защите от утечек.

## P3 — расширение функций

Индивидуальная IPv6 политика или полноценный IPv6 tunnel, private intranet bypass, domain/ipset/GeoIP, несколько профилей/health probes, обновления с pin/signature/rollback, расширенная diagnostics UI. Не превращать проект в общий управляющий addon для всех VPN без отдельного согласования.
