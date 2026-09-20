<!DOCTYPE html>
<!-- trusttunnel-merlin-page-v1 -->
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Cache-Control" content="no-store">
<title>ASUSWRT-Merlin — TrustTunnel</title>
<link rel="stylesheet" href="/index_style.css"><link rel="stylesheet" href="/form_style.css">
<link rel="stylesheet" href="/user/trusttunnel/trusttunnel.css">
<script src="/state.js"></script><script src="/general.js"></script><script src="/popup.js"></script><script src="/help.js"></script>
<script src="/user/trusttunnel/connection.js"></script><script src="/user/trusttunnel/transfer.js"></script><script src="/user/trusttunnel/trusttunnel.js"></script>
</head><body class="bg" onload="ttmInitial()">
<div id="TopBanner"></div><div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" title="Результат команды" style="display:none"></iframe>
<form name="ttm_form" method="post" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page"><input type="hidden" name="next_page">
<input type="hidden" name="group_id" value=""><input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply"><input type="hidden" name="action_wait" value="2">
<input type="hidden" name="action_script"><input type="hidden" name="amng_custom" disabled>
<input type="hidden" name="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
</form>
<table class="content ttm-layout" style="margin:auto" cellpadding="0" cellspacing="0"><tr>
<td class="ttm-sidebar"><div id="mainMenu"></div><div id="subMenu"></div></td>
<td style="vertical-align:top"><div id="tabMenu" class="submenuBlock"></div>
<div class="FormTitle ttm-container">
<div class="ttm-heading ttm-titlebar"><h2>Настройки клиента TrustTunnel</h2><span class="ttm-badge" id="ttm-version">0.3.1-alpha.1</span></div>
<div class="ttm-banner"><strong>Тестовая сборка для AX86U.</strong> Проверки на роутере ещё не выполнены. Наличие процесса и TUN не подтверждает соединение с VPN.</div>
<div class="ttm-tabs ttm-navigation" role="tablist" aria-label="Настройки TrustTunnel">
<button role="tab" type="button" data-view-button="overview" onclick="ttmView('overview')">Обзор</button>
<button role="tab" type="button" data-view-button="connection" onclick="ttmView('connection')">Подключение</button>
<button role="tab" type="button" data-view-button="networks" onclick="ttmView('networks')">Сети</button>
<button role="tab" type="button" data-view-button="diagnostics" onclick="ttmView('diagnostics')">Диагностика</button>
</div>
<div class="ttm-draft"><span id="ttm-dirty">Изменения сохранены</span><button type="button" onclick="ttmReload()">Обновить данные</button></div>
<div id="ttm-message" class="ttm-note" role="status" aria-live="polite"></div>
<div id="ttm-transaction" class="ttm-banner" hidden><p id="ttm-transaction-state"></p><div class="ttm-actions"><button id="ttm-confirm" type="button" onclick="ttmTransaction('confirm')">Доступ проверен, подтвердить</button><button type="button" onclick="ttmTransaction('rollback')">Откатить</button></div></div>
<section class="ttm-section" data-view="overview" aria-labelledby="ttm-status-title">
<div class="ttm-heading"><h3 id="ttm-status-title">Управление клиентом</h3></div>
<dl class="ttm-grid">
<dt>Состояние</dt><dd id="ttm-state">Загрузка…</dd>
<dt>Сервер</dt><dd id="ttm-host">—</dd>
<dt>Процесс / интерфейс</dt><dd><span id="ttm-process">—</span> / <span id="ttm-tun">—</span></dd>
<dt>Получено / отправлено</dt><dd id="ttm-counter">—</dd>
<dt>Обновлено</dt><dd id="ttm-age">—</dd>
<dt>Последняя операция</dt><dd id="ttm-last">—</dd>
<dt>Блокировка обхода VPN</dt><dd id="ttm-guard">—</dd>
<dt>Ревизия настроек</dt><dd id="ttm-revision">—</dd>
</dl>
<div class="ttm-actions">
<button type="button" data-runtime onclick="ttmAction('start')" disabled>Запустить</button>
<button type="button" data-runtime onclick="ttmAction('pause')" disabled>Пауза с блокировкой</button>
<button type="button" data-runtime onclick="ttmAction('restart')" disabled>Перезапустить</button>
<button type="button" class="ttm-release" data-runtime onclick="ttmAction('disable')" disabled>Отключить VPN</button>
</div>
<p class="ttm-muted">Пауза сохраняет блокировку. Отключение возвращает выбранные сети к обычной маршрутизации Merlin.</p>
</section>
<section class="ttm-section" data-view="connection" aria-labelledby="ttm-connection-title" hidden>
<div class="ttm-heading"><h3 id="ttm-connection-title">Настройки подключения</h3><span class="ttm-step">HTTPS · приватное сохранение</span></div>
<p class="ttm-muted">Введите параметры вручную, вставьте ссылку или загрузите файл. Существующий пароль с роутера не загружается: сохранение заменяет конфигурацию подключения целиком.</p>
<div class="ttm-row"><label class="ttm-label" for="ttm-file">Импорт из файла</label><div class="ttm-value"><input type="file" id="ttm-file" accept=".json,.txt" onchange="ttmImportFile(this)"><small>JSON подключения или текст со ссылкой tt://, до 64 КиБ.</small></div></div>
<div class="ttm-row"><div class="ttm-label">Способ настройки</div><div class="ttm-value"><div class="ttm-tabs" role="tablist" aria-label="Способ настройки">
<button type="button" role="tab" id="ttm-tab-manual" aria-selected="true" aria-controls="ttm-manual" onclick="ttmConnectionMode('manual')">Вручную</button>
<button type="button" role="tab" id="ttm-tab-link" aria-selected="false" aria-controls="ttm-link-panel" onclick="ttmConnectionMode('link')">Ссылка tt://</button>
</div></div></div>
<div id="ttm-link-panel" role="tabpanel" aria-labelledby="ttm-tab-link" hidden>
<div class="ttm-row"><label class="ttm-label" for="ttm-link">Ссылка подключения</label><div class="ttm-value"><textarea id="ttm-link" autocomplete="off" spellcheck="false" placeholder="tt://?…" maxlength="65536"></textarea><small>Ссылка содержит учётные данные.</small></div></div>
<div class="ttm-actions"><button type="button" onclick="ttmParseLink()">Разобрать ссылку</button></div>
<p class="ttm-muted">Поддерживается официальный формат TrustTunnel v1. Неподдерживаемые параметры будут показаны как ошибка.</p>
</div>
<div id="ttm-manual" role="tabpanel" aria-labelledby="ttm-tab-manual">
<form id="ttm-endpoint-form" autocomplete="off" onsubmit="return false">
<div class="ttm-settings">
<div class="ttm-row"><label class="ttm-label" for="ttm-hostname">Имя сервера TLS</label><div class="ttm-value"><input type="text" id="ttm-hostname" placeholder="vpn.example.com" maxlength="253" spellcheck="false"><small>Должно совпадать с сертификатом сервера.</small></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-addresses">Адреса сервера с портом</label><div class="ttm-value"><textarea id="ttm-addresses" placeholder="203.0.113.10:443" spellcheck="false"></textarea><small>IPv4 или hostname:port, по одному в строке.</small></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-username">Имя пользователя</label><div class="ttm-value"><input type="text" id="ttm-username" maxlength="256" spellcheck="false" autocomplete="off"></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-password">Пароль</label><div class="ttm-value"><input type="password" id="ttm-password" maxlength="1024" autocomplete="new-password"><label class="ttm-check"><input type="checkbox" id="ttm-show-password" onchange="ttmShowPassword(this.checked)"> Показать пароль</label></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-protocol">Транспорт</label><div class="ttm-value"><select id="ttm-protocol"><option value="http2">HTTP/2 · TCP</option><option value="http3">HTTP/3 · QUIC</option></select></div></div>
<div class="ttm-row"><div class="ttm-label">Anti-DPI</div><div class="ttm-value"><label class="ttm-check"><input type="checkbox" id="ttm-anti-dpi"> Включить Anti-DPI</label><small>В соответствии с настройками подключения.</small></div></div>
</div>
<details><summary>Сертификат, DNS и дополнительные параметры</summary>
<div class="ttm-settings">
<div class="ttm-row"><label class="ttm-label" for="ttm-upstreams">DNS клиента TrustTunnel</label><div class="ttm-value"><textarea id="ttm-upstreams" spellcheck="false" placeholder="DNS из конфигурации подключения"></textarea><small id="ttm-dns-hint">DNS задаётся только в конфигурации подключения. Для ручного подключения укажите его здесь.</small></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-mtu">MTU</label><div class="ttm-value"><input type="number" id="ttm-mtu" min="1280" max="1500" value="1350"></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-wan">WAN-интерфейс</label><div class="ttm-value"><input type="text" id="ttm-wan" maxlength="15" placeholder="Автоматически" spellcheck="false"><small>Необязательно. Оставьте пустым для автоматического выбора.</small></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-certificate">Сертификат PEM</label><div class="ttm-value"><textarea id="ttm-certificate" spellcheck="false" maxlength="16384" placeholder="-----BEGIN CERTIFICATE-----"></textarea><small>Если выдан вашим сервером. Для доверенного публичного сертификата оставьте пустым. Проверка TLS всегда включена.</small></div></div>
</div>
</details>
<details class="ttm-exclusions-help" open><summary>Исключения из VPN</summary>
<p>Совпавшие назначения обходят TrustTunnel и выходят напрямую через WAN. Указывайте по одному правилу в строке.</p>
<div class="ttm-settings">
<div class="ttm-row"><label class="ttm-label" for="ttm-exclusion-domains">Домены сайтов</label><div class="ttm-value"><textarea id="ttm-exclusion-domains" spellcheck="false" placeholder="example.com&#10;*.example.net"></textarea><small><code>example.com</code> включает сам домен и его поддомены. <code>*.example.com</code> включает только поддомены. Полный URL, протокол и путь указывать нельзя.</small></div></div>
<div class="ttm-row"><label class="ttm-label" for="ttm-exclusion-networks">IPv4, сети и порты</label><div class="ttm-value"><textarea id="ttm-exclusion-networks" spellcheck="false" placeholder="203.0.113.10&#10;198.51.100.0/24&#10;203.0.113.20:443&#10;*:80"></textarea><small>Поддерживаются IPv4, канонический CIDR, IPv4:порт и <code>*:порт</code>. IPv6 заблокирован политикой аддона и здесь недоступен.</small></div></div>
</div>
<p class="ttm-error">Исключённый трафик не защищён VPN и использует внешний адрес провайдера. Правила <code>0.0.0.0/0</code> и <code>*:порт</code> могут вывести напрямую большой объём трафика; <code>*:53</code> может вывести DNS.</p>
</details>
</form>
<div class="ttm-actions"><button type="button" id="ttm-save-endpoint" class="ttm-primary" onclick="ttmSaveEndpoint()">Сохранить подключение</button><button type="button" onclick="ttmExportEndpoint()">Проверить и скачать конфигурацию</button><button type="button" onclick="ttmClearConnection()">Очистить данные</button></div>
</div>
<div id="ttm-connection-message" role="status" aria-live="polite" class="ttm-note"></div>
<details class="ttm-import-help"><summary>Как применить подключение на роутере</summary>
<p>Кнопка сохранения использует зашифрованную передачу через штатный интерфейс Merlin по HTTPS. Если этот экспериментальный канал недоступен, используйте импорт по SSH:</p>
<ol><li>Скачайте <code>trusttunnel-endpoint.json</code>, ограничьте доступ к нему на компьютере и перенесите по SCP/SFTP в <code>/tmp/</code> роутера.</li><li>Отключите аддон перед изменением подключения. В SSH выполните:</li></ol>
<pre>chmod 600 /tmp/trusttunnel-endpoint.json
/jffs/addons/trusttunnel/trusttunnel.sh import-endpoint /tmp/trusttunnel-endpoint.json
# После успешного импорта:
rm /tmp/trusttunnel-endpoint.json</pre>
<p class="ttm-muted">Скачанный файл содержит пароль. После импорта удалите свою временную копию из загрузок. Экспорт сам по себе не меняет настройки роутера.</p>
</details>
</section>
<section class="ttm-section" data-view="networks" aria-labelledby="ttm-routing-title" hidden>
<div class="ttm-heading"><h3 id="ttm-routing-title">Маршрутизация сетей через VPN</h3><span id="ttm-network-count" class="ttm-step">0 сетей</span></div>
<p class="ttm-muted">Выберите основную и гостевые сети. Сети показаны по именам Wi-Fi (SSID); привязку к интерфейсам определяет роутер. Можно уточнить IPv4-подсети или отдельные адреса /32. Неотмеченные сети сохраняют обычную маршрутизацию Merlin.</p>
<fieldset id="ttm-policy-fields" disabled>
<div class="ttm-actions"><button type="button" onclick="ttmSelectNetworks(true)">Выбрать все</button><button type="button" onclick="ttmSelectNetworks(false)">Снять выбор</button></div>
<div id="ttm-networks"></div><p id="ttm-networks-empty" class="ttm-note" hidden>Список сетей пока не получен от роутера. Дождитесь обновления статуса и проверьте настройки Wi-Fi.</p>
<p class="ttm-muted">Список формируется автоматически. Если несколько SSID используют одну сеть, они выбираются вместе. До 16 сетей и 32 записей подсетей суммарно.</p>
<p class="ttm-muted">Выбор устройства заменяет целые подсети списком адресов /32. Закрепите адрес в DHCP Merlin: правило привязано к IPv4, а не к MAC.</p>
<details><summary>Доступ к локальным ресурсам</summary><p>Разрешить обычную маршрутизацию к отмеченным локальным сетям. Ограничения гостевой изоляции Merlin сохраняются. Интернет и DNS остаются направлены через VPN.</p><div id="ttm-local-access" class="ttm-local-access"></div></details>

<label class="ttm-check ttm-acknowledgement"><input type="checkbox" id="ttm-v6ack"><span>Подтверждаю блокировку IPv6-транзита и IPv6 DNS к роутеру во <strong>всех выбранных сетях целиком</strong>, в том числе для IPv4-адресов вне указанных подсетей.</span></label>
</fieldset>
<div class="ttm-actions"><button type="button" class="ttm-primary" id="ttm-save" onclick="ttmAction('policy')" disabled>Сохранить маршрутизацию</button><button type="button" id="ttm-export-policy" onclick="ttmExportPolicy()" disabled>Скачать политику для SSH</button></div>
<p class="ttm-muted">При работающем клиенте изменения применяются временно. Проверьте доступ и подтвердите их в течение 3 минут; иначе контроллер запросит откат. До подтверждения удалённые из политики сети остаются заблокированы.</p>
</section>
<section class="ttm-section" data-view="diagnostics" aria-labelledby="ttm-diagnostics-title" hidden>
<div class="ttm-heading"><h3 id="ttm-diagnostics-title">Диагностика и история</h3></div>
<p class="ttm-muted">Отчёт содержит версии, доступность инструментов и результаты операций. Пароль, ссылка подключения и журнал клиента в него не включаются. Проверка прохождения трафика и ускорения HND требует роутера.</p>
<div class="ttm-actions"><button type="button" data-runtime onclick="ttmAction('diagnostics')">Обновить диагностику</button><button type="button" onclick="ttmDownloadDiagnostics()">Скачать отчёт</button></div>
<pre id="ttm-operation-list"></pre><details><summary>Совместимость и версии</summary><pre id="ttm-diagnostics"></pre></details>
</section>
</div></td></tr></table><div id="footer"></div></body></html>
