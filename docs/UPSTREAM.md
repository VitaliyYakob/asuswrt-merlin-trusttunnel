# Первичные источники

Актуальное исследование для 0.2.0-alpha.1 находится в [RESEARCH.md](RESEARCH.md).

- [TrustTunnelClient v1.1.5](https://github.com/TrustTunnel/TrustTunnelClient/tree/v1.1.5): стабильная версия схемы клиента, исследованная 14.09.2026.
- [Deep link specification v1.0.33](https://github.com/TrustTunnel/TrustTunnel/blob/v1.0.33/DEEP_LINK.md): формат tt://, закреплённый зависимостью клиента v1.1.5.
- [Merlin Addons API](https://github.com/RMerl/asuswrt-merlin.ng/wiki/Addons-API): userN.asp, helper.sh, menuTree, amng_custom и service-event.
- [AmneziaWG](https://github.com/r0otx/asuswrt-merlin-amneziawg), [XrayUI](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui): архитектурные примеры нативной интеграции и редактора настроек.
- [Статья автора XrayUI](https://habr.com/ru/articles/875148/): обзор UX и практики автора; не нормативная спецификация Merlin.

Upstream custom_sni поддерживается стабильным кодом; его отклонение в нашем parser — ограничение аддона. tls_profile исследовался как Unreleased, в эту стабильную схему не добавлен. Сторонние исходники и исполняемые файлы в поставку не включены.
