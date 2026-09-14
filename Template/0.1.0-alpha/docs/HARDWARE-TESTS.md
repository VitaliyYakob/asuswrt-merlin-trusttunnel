# Аппаратная приёмка: пока NOT RUN

Все строки ниже ожидают настоящего роутера. Локальный mock не заменяет ни один пункт. Первое испытание: отдельный guest bridge, одно тестовое устройство, Ethernet/другой независимый способ восстановления; не единственный удалённый WAN-канал.

| ID | Испытание | Критерий |
|---|---|---|
| H01 | RT-AX86U: uname, firmware, архитектура, libc/kernel ABI | Официальный зафиксированный бинарник запускается, /dev/net/tun доступен. |
| H02 | UI: штатная/модифицированная тема Merlin, существующие аддоны | TrustTunnel находится в VPN; страницы Xray/AWG и settings не потеряны. |
| H03 | Аутентификация и CSRF | Действия недоступны без авторизованной сессии; статус/ресурсы проверены отдельно. |
| H04 | Имя гостевого bridge, IPv4 адресация, dnsmasq | Источники политики действительно приходят через выбранный iif. |
| H05 | HTTP/2 и HTTP/3 отдельно | Handshake, DNS, TCP/UDP и внешний IP подтверждены server/client logs и независимым запросом. |
| H06 | LAN/guest выбранный и неизбранный клиент | Только выбранный IPv4 идёт в TT; admin WebUI/SSH не теряется. |
| H07 | DNS на router IPv4, внешний IPv4, IPv6 router, DoH/DoT | tcpdump WAN не показывает прямой DNS выбранного клиента; IPv6 router DNS запрещён. |
| H08 | Аварийный SIGKILL клиента и удаление tt0 | Выбранный клиент не выходит через WAN/чужой VPN; non-selected IPv4 не ломается. |
| H09 | Pause, restart и explicit disable | Pause сохраняет блокировку; restart не снимает её; только disable выпускает в обычную policy. |
| H10 | WAN reconnect, IP смена, default interface смена | Uplink не зацикливается в TUN; configured bound_if не устарел. |
| H11 | Firewall/NAT rebuild | Зафиксировать пакетами весь интервал, включая время до hook; отсутствие утечек не предполагать. |
| H12 | Перезагрузка, задержанный /opt, удаление USB | Оценить bootstrap gap; это release blocker для заявления fail-closed. |
| H13 | CTF/runner/flow cache/HND acceleration | Аппаратный обход filter/PBR исключён измерениями, не только nvram флагом. |
| H14 | Соседний Xray/AWG/VPN Director | Нет захвата чужих marks/tables, конфликтов маршрутов и захвата uplink TT. |
| H15 | MTU/MSS, большие файлы, видео, UDP, длительная нагрузка | Нет MTU blackhole, неприемлемого CPU/RAM, утечек ресурсов; скорость измерена. |
| H16 | Удаление/reinstall/ошибка установки | Другие hooks/menu/правила сохранены, конфигурация и backups управляемы. |
| H17 | Параллельные GUI действия, cron, firmware events | Нет двойного клиента, deadlock, потерянного policy save или сломанного menu bind. |

## Read-only сведения перед испытанием

```sh
uname -a
nvram get productid
nvram get firmver
nvram get buildno
nvram get extendno
nvram get rc_support
nvram get jffs2_scripts
nvram get ctf_disable
nvram get fc_disable
nvram get runner_disable
ip -4 addr show
ip -4 rule show
ip -4 route show table main
ip -4 route show table 871
ip -6 rule show
ls -l /dev/net/tun
command -v jq ip iptables ip6tables iptables-restore ip6tables-restore flock
```

Отдельно собрать `iptables-save`/`ip6tables-save` до/после, предварительно оценив чувствительность топологии и других данных. Проверять доступность внешнего ресурса именно с выбранного LAN-клиента и сопоставлять наблюдения с WAN packet capture. Один `curl` с самого роутера не подтверждает source PBR клиентов.

Не публиковать `nvram show`, реальные endpoint.json/client.toml или журналы целиком: они могут содержать секреты других служб.
