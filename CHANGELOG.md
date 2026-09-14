# 0.2.0-alpha.1 — 2026-09-14

- Ручная форма подключения и импорт официальных tt:// v0/v1 с валидацией, предупреждениями и DER → PEM.
- Приватный JSON export с явной инструкцией применения по SSH; credentials не передаются в Addons API.
- Политика schema2: несколько bridge, все/выбранные сети, до 32 CIDR; сохранена совместимость schema1.
- Обновлён интерфейс для основной и трёх гостевых сетей, добавлены проверки CIDR/DNS и актуальности статуса.
- Резервирование конфигурации и файлов аддона, Entware PATH и проверка JFFS scripts в установщике.
- Восстановление guards выполняется до client preflight; ошибки backup hooks прекращают изменение; custom PEM проверяется как X.509 до импорта.
- Дополнены регрессионные проверки, браузерная проверка и документация. Поставка остаётся лабораторной: аппаратных результатов нет.

# Changelog

## 0.1.0-alpha.1

Initial independently implemented native Merlin addon, shell controller, policy/endpoint validation,
TOML generator, declarative routing plans, ownership-aware cleanup, hooks/menu integration,
private credential import, frontend, offline preview and host-side tests.

Fixed during initial local verification: JSON-plan syntax, validation failure propagation through
pipelines, canonical executable matching for symlinked /opt, restoration of a lost tunnel route while
the client remains alive, and atomic repositioning of guard jumps before subsequently inserted rules.

No hardware, upstream-client execution or end-to-end VPN tests have been performed.
