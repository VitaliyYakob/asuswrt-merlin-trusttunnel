<!DOCTYPE html>
<!-- trusttunnel-merlin-page-v1 -->
<html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Cache-Control" content="no-store">
<title>ASUSWRT-Merlin — TrustTunnel</title>
<link rel="stylesheet" href="/index_style.css"><link rel="stylesheet" href="/form_style.css">
<link rel="stylesheet" href="/user/trusttunnel/trusttunnel.css">
<script src="/state.js"></script><script src="/general.js"></script><script src="/popup.js"></script><script src="/help.js"></script>
<script>window.ttmCustomSettings = <% get_custom_settings(); %>;</script>
<script src="/user/trusttunnel/connection.js"></script><script src="/user/trusttunnel/trusttunnel.js"></script>
</head><body class="bg" onload="ttmInitial()">
<div id="TopBanner"></div><div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" title="Результат команды" style="display:none"></iframe>
<form name="ttm_form" method="post" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page"><input type="hidden" name="next_page">
<input type="hidden" name="group_id" value=""><input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply"><input type="hidden" name="action_wait" value="2">
<input type="hidden" name="action_script"><input type="hidden" name="amng_custom">
<input type="hidden" name="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
</form>
<table class="content" style="margin:auto" cellpadding="0" cellspacing="0"><tr>
<td style="width:202px;vertical-align:top"><div id="mainMenu"></div><div id="subMenu"></div></td>
<td style="vertical-align:top"><div id="tabMenu" class="submenuBlock"></div>
<div class="FormTitle ttm-container">
<div class="ttm-heading"><div><span class="ttm-eyebrow">VPN / ASUSWRT-MERLIN</span><h2>TrustTunnel</h2><p class="ttm-muted">Подключение и маршрутизация домашних сетей</p></div><span class="ttm-badge" id="ttm-version">0.2.0-alpha.1</span></div>
<div class="ttm-banner"><strong>Тестовая сборка для AX86U.</strong> Проверки на роутере ещё не выполнены. Наличие процесса и TUN не подтверждает соединение с VPN.</div>
<section class="ttm-section" aria-labelledby="ttm-status-title">
<div class="ttm-heading"><h3 id="ttm-status-title">Состояние клиента</h3><strong id="ttm-state">Загрузка…</strong></div>
<dl class="ttm-grid">
<dt>Сервер</dt><dd id="ttm-host">—</dd>
<dt>Процесс / интерфейс</dt><dd><span id="ttm-process">—</span> / <span id="ttm-tun">—</span></dd>
<dt>Получено / отправлено</dt><dd id="ttm-counter">—</dd>
<dt>Обновлено</dt><dd id="ttm-age">—</dd>
<dt>Последняя операция</dt><dd id="ttm-last">—</dd>
</dl>
<div class="ttm-actions">
<button type="button" data-runtime onclick="ttmAction('start')" disabled>Запустить</button>
<button type="button" data-runtime onclick="ttmAction('pause')" disabled>Пауза с блокировкой</button>
<button type="button" data-runtime onclick="ttmAction('restart')" disabled>Перезапустить</button>
<button type="button" class="ttm-release" data-runtime onclick="ttmAction('disable')" disabled>Отключить VPN</button>
</div>
<p class="ttm-muted">Пауза сохраняет блокировку. Отключение возвращает выбранные сети к обычной маршрутизации Merlin.</p>
</section>
<div id="ttm-message" class="ttm-note" role="status" aria-live="polite"></div>
<section class="ttm-section" aria-labelledby="ttm-connection-title">
<div class="ttm-heading"><h3 id="ttm-connection-title">1. Подключение к серверу</h3><span class="ttm-step">Локальная подготовка</span></div>
<p class="ttm-muted">Введите параметры вручную или вставьте ссылку TrustTunnel. Пароль остаётся в памяти этой страницы до экспорта; автоматического сохранения нет.</p>
<div class="ttm-tabs" role="tablist" aria-label="Способ настройки">
<button type="button" role="tab" id="ttm-tab-manual" aria-selected="true" aria-controls="ttm-manual" onclick="ttmConnectionMode('manual')">Вручную</button>
<button type="button" role="tab" id="ttm-tab-link" aria-selected="false" aria-controls="ttm-link-panel" onclick="ttmConnectionMode('link')">Ссылка tt://</button>
</div>
<div id="ttm-link-panel" role="tabpanel" aria-labelledby="ttm-tab-link" hidden>
<label for="ttm-link">Ссылка подключения</label><textarea id="ttm-link" autocomplete="off" spellcheck="false" placeholder="tt://?…" maxlength="65536"></textarea>
<div class="ttm-actions"><button type="button" onclick="ttmParseLink()">Разобрать ссылку</button></div>
<p class="ttm-muted">Поддерживается официальный формат TrustTunnel v1. Неподдерживаемые параметры будут показаны как ошибка. Ссылка содержит учётные данные.</p>
</div>
<div id="ttm-manual" role="tabpanel" aria-labelledby="ttm-tab-manual">
<form id="ttm-endpoint-form" autocomplete="off" onsubmit="return false">
<div class="ttm-fields">
<div><label for="ttm-hostname">Имя сервера TLS</label><input type="text" id="ttm-hostname" placeholder="vpn.example.com" maxlength="253" spellcheck="false"><small>Должно совпадать с сертификатом сервера.</small></div>
<div><label for="ttm-addresses">Адреса сервера с портом</label><textarea id="ttm-addresses" placeholder="203.0.113.10:443" spellcheck="false"></textarea><small>IPv4 или hostname:port, по одному в строке.</small></div>
<div><label for="ttm-username">Имя пользователя</label><input type="text" id="ttm-username" maxlength="256" spellcheck="false" autocomplete="off"></div>
<div><label for="ttm-password">Пароль</label><input type="password" id="ttm-password" maxlength="1024" autocomplete="new-password"><label class="ttm-check"><input type="checkbox" id="ttm-show-password" onchange="ttmShowPassword(this.checked)"> Показать пароль</label></div>
<div><label for="ttm-protocol">Транспорт</label><select id="ttm-protocol"><option value="http2">HTTP/2 · TCP</option><option value="http3">HTTP/3 · QUIC</option></select></div>
<div><label class="ttm-check"><input type="checkbox" id="ttm-anti-dpi"> Anti-DPI</label><small>Включайте в соответствии с настройками подключения.</small></div>
</div>
<details><summary>Сертификат, DNS и дополнительные параметры</summary>
<div class="ttm-fields">
<div><label for="ttm-upstreams">DNS клиента TrustTunnel</label><textarea id="ttm-upstreams" spellcheck="false">tls://1.1.1.1</textarea><small>По одному адресу в строке.</small></div>
<div><label for="ttm-mtu">MTU</label><input type="number" id="ttm-mtu" min="1280" max="1500" value="1350"><label for="ttm-wan">WAN-интерфейс (необязательно)</label><input type="text" id="ttm-wan" maxlength="15" placeholder="Автоматически" spellcheck="false"></div>
</div>
<label for="ttm-certificate">Сертификат PEM (если выдан вашим сервером)</label><textarea id="ttm-certificate" spellcheck="false" maxlength="16384" placeholder="-----BEGIN CERTIFICATE-----"></textarea>
<p class="ttm-muted">Проверка TLS всегда включена. Для доверенного публичного сертификата поле можно оставить пустым.</p>
</details>
</form>
<div class="ttm-actions"><button type="button" class="ttm-primary" onclick="ttmExportEndpoint()">Проверить и скачать конфигурацию</button><button type="button" onclick="ttmClearConnection()">Очистить данные</button></div>
</div>
<div id="ttm-connection-message" role="status" aria-live="polite" class="ttm-note"></div>
<details class="ttm-import-help"><summary>Как применить подключение на роутере</summary>
<p>В этой alpha конфигурация переносится по SSH. Штатное общее хранилище Merlin не используется для пароля.</p>
<ol><li>Скачайте <code>trusttunnel-endpoint.json</code>, ограничьте доступ к нему на компьютере и перенесите по SCP/SFTP в <code>/tmp/</code> роутера.</li><li>Отключите аддон перед изменением подключения. В SSH выполните:</li></ol>
<pre>chmod 600 /tmp/trusttunnel-endpoint.json
/jffs/addons/trusttunnel/trusttunnel.sh import-endpoint /tmp/trusttunnel-endpoint.json
# После успешного импорта:
rm /tmp/trusttunnel-endpoint.json</pre>
<p class="ttm-muted">Скачанный файл содержит пароль. После импорта удалите свою временную копию из загрузок. Экспорт сам по себе не меняет настройки роутера.</p>
</details>
</section>
<section class="ttm-section" aria-labelledby="ttm-routing-title">
<div class="ttm-heading"><h3 id="ttm-routing-title">2. Сети через VPN</h3><span id="ttm-network-count" class="ttm-step">0 сетей</span></div>
<p class="ttm-muted">Выберите основную и гостевые сети. В каждой строке укажите реальный bridge и IPv4-подсети либо отдельные адреса /32. Неотмеченные сети сохраняют обычную маршрутизацию Merlin.</p>
<fieldset id="ttm-policy-fields" disabled>
<div class="ttm-actions"><button type="button" onclick="ttmSelectNetworks(true)">Выбрать все</button><button type="button" onclick="ttmSelectNetworks(false)">Снять выбор</button><button type="button" onclick="ttmAddNetwork()">Добавить сеть</button></div>
<div id="ttm-networks"></div>
<p class="ttm-muted">br0–br3 — примеры имён, их нужно проверить на роутере. Поддерживается до 16 сетей и 32 записей подсетей суммарно.</p>
<label for="ttm-dns">Внешний DNS IPv4 для выбранных сетей</label><input type="text" id="ttm-dns" value="1.1.1.1" maxlength="15" spellcheck="false">
<label class="ttm-check"><input type="checkbox" id="ttm-v6ack"><span>Подтверждаю блокировку IPv6-транзита и IPv6 DNS к роутеру на <strong>каждом выбранном bridge целиком</strong>, в том числе для IPv4-адресов вне указанных подсетей.</span></label>
</fieldset>
<div class="ttm-actions"><button type="button" class="ttm-primary" id="ttm-save" onclick="ttmAction('policy')" disabled>Сохранить маршрутизацию</button><button type="button" id="ttm-export-policy" onclick="ttmExportPolicy()" disabled>Скачать политику для SSH</button></div>
<p class="ttm-muted">Изменения доступны при отключённом аддоне. После сохранения проверьте результат операции. Переключение работающей политики без отключения пока не поддерживается.</p>
</section>
</div></td></tr></table><div id="footer"></div></body></html>
