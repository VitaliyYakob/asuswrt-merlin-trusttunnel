# Архитектура 0.1.0-alpha.1

## Путь управления

`VPN tab (userN.asp) → штатный start_apply.htm → service-event → allowlist event dispatcher → shell controller → официальный trusttunnel_client`.

Статус: `controller → ограниченный JSON → /www/user/trusttunnel/status.json → XMLHttpRequest`. Страница не открывает сокет слушателя и не создаёт отдельной авторизации.

Runtime: BusyBox/POSIX shell + jq + iproute2 + iptables/ip6tables + flock. Python/Node — только средства разработки, не router dependencies.

## Владельцы состояния

| Объект | Владелец |
|---|---|
| `tt0`, внутренние соединения, криптография и транспорт | TrustTunnelClient |
| TUN default routes, source policy, DNS DNAT, IPv4 NAT и filter guards | Аддон |
| dnsmasq, resolv.conf, main table, остальные VPN и их метки | Merlin / соответствующие аддоны; TrustTunnel-addon их не переписывает |
| Исходный endpoint JSON и политика | Приватный config directory |
| Сгенерированный TOML, PID/starttime, ownership | Приватный tmpfs directory |
| Связь страницы с controller | Merlin Addons API |

Генерируется `device_name=tt0`, `use_existing=false`, `included_routes=[]`, `excluded_routes=[]`, `change_system_dns=false`. Внешние IPv6-потоки не направляются в клиент; `has_ipv6=false`. Username/password в JSON/TOML не экранируются вручную shell-подстановками: строки создаёт jq, round-trip проверяется tomllib в тестах.

## IPv4 data plane

Для источников из выбранного bridge:

1. DNS TCP/UDP 53 DNAT на внешний IPv4 resolver. Это включает DNS-запросы на IPv4 адрес самого роутера, которые после DNAT становятся транзитными.
2. `ip rule from SOURCE iif BRIDGE lookup 871` выбирает отдельную таблицу; маркеры других VPN не переиспользуются.
3. Таблица имеет `prohibit default metric 32760`. Рабочий default через `tt0 metric 10` появляется после создания интерфейса. Удаление `tt0` не должно превращать эту таблицу в пустую с проваливанием в main.
4. FORWARD guard допускает выбранные источники только через tt0; другой выход отклоняется. Возвратный established/related трафик допускается в выбранный bridge. NAT через TUN выполняет отдельная собственная цепочка.

Это проектное поведение, проверенное на уровне планов/модели, а не измерение реальных пакетов. Чужие более приоритетные маршруты могут блокировать желаемый VPN-путь. После reconcile прыжки в наши цепочки ставятся первыми через отдельную atomic restore-транзакцию. Чужой последующий ACCEPT или аппаратное ускорение всё ещё требуют аппаратной проверки.

Остальные IPv4-источники аддон не обязан отправлять в WAN: они остаются под обычной политикой Merlin/Xray/AWG. Межсегментный маршрутизируемый IPv4-трафик выбранных источников не имеет отдельного LAN-bypass в этой alpha; intranet-исключения отложены. Общение внутри одного bridge не является IP forwarding через маршрутизатор и этой PBR-политикой не фильтруется.

## IPv6 и DNS

В alpha IPv6 блокируется для всего указанного bridge на FORWARD. Дополнительно запрещается UDP/TCP 53 к самому роутеру через IPv6; иначе DNS к локальному resolver мог бы инициировать незатронутые upstream-запросы от роутера. ICMPv6/ND на INPUT целиком не отключаются.

Ограничение осознанно широкое: выбранные IPv4 /32 не определяют IPv6 privacy addresses устройства. Поэтому для первого испытания предпочтителен отдельный guest bridge. Индивидуальная защита IPv6 по устройствам, DUID/MAC и полноценная IPv6 PBR не реализованы.

IPv4 DoH/DoT выбранного источника идут по той же общей source policy; перехват 53 не декодирует DoH. DNS самого роутера и неизбранных устройств не меняется. Нет обещания, что hardware offload, кастомный transparent proxy или локальный прикладной proxy не изменит этот путь.

## Надёжность

Один controller lock (flock), PID + starttime + canonical executable path, секреты не в argv, ребёнок закрывает lock FD. Короткий `service-event` только выбирает разрешённое действие и запускает controller вне блокирующего handler. Завершение процесса не освобождает guard; явный disable освобождает.

Произвольная shell-конфигурация не поддерживается. Активная политика меняется только после disable. Таблица/priority/chain collisions до claim приводят к отказу; uninstaller использует сохранённую owned-policy, а не произвольную новую конфигурацию.

На services-start, WAN/firewall/nat events и Entware init вызывается idempotent reconcile. Наличие `/opt`/jq требуется; bootstrap guard до монтирования Entware отсутствует. Поэтому **безутечный boot, полный firewall rebuild и отказ USB не сертифицированы**.

## Границы UI

Non-secret policy передаётся через amng_custom с лимитом 2999 символов для значения и консервативным пределом 7600 символов сериализованного общего объекта. Данные чужих аддонов сохраняются в клиентском snapshot. Согласование конкурентного сохранения из нескольких вкладок/аддонов требует отдельной проверки/улучшения.

Точная menu anchor alpha — `Advanced_VPNClient_Content.asp`. Неизвестный layout отклоняется, а не модифицируется по догадке. Вкладка VPN не добавляет TrustTunnel в штатный VPN Director.
