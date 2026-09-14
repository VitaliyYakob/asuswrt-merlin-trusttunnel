# Первичные источники и привязки

Изучены при реализации; upstream-репозитории не включены как vendored source.

1. Пример интеграции r0otx: https://github.com/r0otx/asuswrt-merlin-amneziawg
   Основной файл: addon/amneziawg.sh. Полученный blob SHA: 4784b13b86d8c6639d781dffc72e98defaa3d412. Использован как архитектурный образец, не как переименованный fork.
2. Merlin Addons API: https://github.com/RMerl/asuswrt-merlin.ng/wiki/Addons-API
   Используются am_get_webui_page, userN.asp, menuTree bind mount, amng_custom и service-event. Документированные ограничения shared settings — 2999 символов на значение и 8 KB суммарно. Реальную семантику сохранения/авторизации проверять на целевой версии прошивки.
3. TrustTunnelClient v1.1.5 schema: https://github.com/TrustTunnel/TrustTunnelClient/blob/v1.1.5/trusttunnel/README.md
   Полученный blob SHA: 8bb1b4c687cb3d26e52f0bdd72a863422636d2fb.
   Использованы device_name, use_existing, included_routes=[], change_system_dns=false, endpoint credentials и http2/http3.
4. Linux TUN implementation: https://github.com/TrustTunnel/TrustTunnelClient/blob/v1.1.5/net/src/os_tunnel_linux.cpp
   Дополнительное подтверждение external route management; на устройство код не загружался.

В проекте нет утверждений о более новых версиях, custom_sni, upstream_protocol=auto или tls_profile: эти поля не входят в зафиксированную alpha-схему. Новую версию клиента сначала сравнить с официальными исходниками и добавить regression tests.
