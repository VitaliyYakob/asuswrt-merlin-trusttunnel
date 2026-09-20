# Первичные источники

Актуальное исследование для 0.2.0-alpha.1 находится в [RESEARCH.md](RESEARCH.md).

- [TrustTunnelClient v1.1.5](https://github.com/TrustTunnel/TrustTunnelClient/tree/v1.1.5): стабильная версия схемы клиента, исследованная 14.09.2026.
- [Deep link specification v1.0.33](https://github.com/TrustTunnel/TrustTunnel/blob/v1.0.33/DEEP_LINK.md): формат tt://, закреплённый зависимостью клиента v1.1.5.
- [Merlin Addons API](https://github.com/RMerl/asuswrt-merlin.ng/wiki/Addons-API): userN.asp, helper.sh, menuTree, amng_custom и service-event.
- [AmneziaWG](https://github.com/r0otx/asuswrt-merlin-amneziawg), [XrayUI](https://github.com/DanielLavrushin/asuswrt-merlin-xrayui): архитектурные примеры нативной интеграции и редактора настроек.
- [Статья автора XrayUI](https://habr.com/ru/articles/875148/): обзор UX и практики автора; не нормативная спецификация Merlin.

Upstream custom_sni поддерживается стабильным кодом; его отклонение в нашем parser — ограничение аддона. tls_profile исследовался как Unreleased, в эту стабильную схему не добавлен. Сторонние исходники и исполняемые файлы в поставку не включены.

- [Merlin 3004.388.12_2 state.js](https://github.com/RMerl/asuswrt-merlin.ng/blob/3004.388.12_2/release/src/router/www/state.js): gn_array каждого радио ограничивается первыми тремя гостевыми слотами, кроме BRT-AC828. Проверено также в /www/state.js настоящего RT-AX86U. Это основание фильтра BSS, а не эвристика по длине SSID. Подсети по-прежнему определяются по активным адресам bridge, не по номеру Wi-Fi слота.

- [CLI reference TrustTunnelClient v1.1.5](https://github.com/TrustTunnel/TrustTunnelClient/blob/v1.1.5/trusttunnel/README.md): отдельный listener.socks.address использован только для ограниченной loopback-пробы связи без системных маршрутов.

- [Merlin 3004.388.12_2 xt_SKIPLOG.c](https://github.com/RMerl/asuswrt-merlin.ng/blob/3004.388.12_2/release/src-rt-5.02L.07p2axhnd/kernel/linux-4.1/net/netfilter/xt_SKIPLOG.c): target вызывает blog_skip для совпавшего пакета, возвращает XT_CONTINUE, family NFPROTO_UNSPEC. На AX86U target есть в IPv4 и IPv6; встроенная справка fc подтверждает flush --if. Это основание выборочной изоляции, но не замена аппаратной проверке утечек/действующих потоков.
- [Merlin amvpn_routing.c](https://github.com/RMerl/asuswrt-merlin.ng/blob/3004.388.12_2/release/src/router/libovpn/amvpn_routing.c): штатная source-policy маршрутизация VPN; универсальное требование отключить ускорение всего роутера отсюда не следует. Marks сторонних VPN не копируются и не занимаются аддоном.
