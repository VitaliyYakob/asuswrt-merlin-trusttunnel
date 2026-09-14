<!DOCTYPE html>
<!-- trusttunnel-merlin-page-v1 -->
<html lang="ru"><head>
<meta charset="utf-8"><meta http-equiv="Cache-Control" content="no-store">
<title>ASUSWRT-Merlin — TrustTunnel</title>
<link rel="stylesheet" href="/index_style.css"><link rel="stylesheet" href="/form_style.css">
<link rel="stylesheet" href="/user/trusttunnel/trusttunnel.css">
<script src="/state.js"></script><script src="/general.js"></script><script src="/popup.js"></script><script src="/help.js"></script>
<script>window.ttmCustomSettings = <% get_custom_settings(); %>;</script>
<script src="/user/trusttunnel/trusttunnel.js"></script>
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
<h2>TrustTunnel Client</h2><div class="ttm-muted">ASUSWRT-Merlin addon · <span id="ttm-version">0.1.0-alpha.1</span></div>
<div class="ttm-banner"><strong>Лабораторная версия — на роутере не проверена.</strong><br>
Создание процесса и TUN не подтверждает VPN-соединение. Не используйте эту сборку как проверенную защиту от утечек.</div>
<dl class="ttm-grid">
<dt>Состояние</dt><dd id="ttm-state">Загрузка…</dd>
<dt>TLS hostname</dt><dd id="ttm-host">—</dd>
<dt>Процесс клиента</dt><dd id="ttm-process">—</dd>
<dt>Интерфейс</dt><dd id="ttm-tun">—</dd>
<dt>Получено / отправлено</dt><dd id="ttm-counter">—</dd>
<dt>Статус сформирован</dt><dd id="ttm-age">—</dd>
<dt>Последняя операция</dt><dd id="ttm-last">—</dd>
</dl>
<div class="ttm-actions">
<button type="button" onclick="ttmAction('start')">Запустить</button>
<button type="button" onclick="ttmAction('pause')">Остановить с блокировкой</button>
<button type="button" onclick="ttmAction('restart')">Перезапустить</button>
<button type="button" class="ttm-release" onclick="ttmAction('disable')">Отключить и вернуть обычный маршрут</button>
</div>
<div id="ttm-message" class="ttm-note" role="status"></div>
<h3>Маршрутизация</h3>
<p class="ttm-muted">IPv4 выбранных адресов направляется в TrustTunnel. Укажите реальный bridge своей LAN или гостевой сети; имя нельзя определить без проверки роутера.</p>
<fieldset id="ttm-policy-fields">
<label for="ttm-lan">LAN / Guest bridge</label><input type="text" id="ttm-lan" value="br1" maxlength="15" spellcheck="false">
<label for="ttm-sources">IPv4-адреса / подсети (CIDR, по одной записи в строке)</label>
<textarea id="ttm-sources" spellcheck="false">192.168.50.0/24</textarea>
<label for="ttm-dns">Внешний DNS IPv4 для перенаправления TCP/UDP 53 в туннель</label>
<input type="text" id="ttm-dns" value="1.1.1.1" maxlength="15" spellcheck="false">
<label><input type="checkbox" id="ttm-v6ack"> Подтверждаю: IPv6-транзит и IPv6 DNS к роутеру будут блокироваться для <strong>всего выбранного bridge</strong>, не только для IPv4-адресов выше.</label>
</fieldset>
<div class="ttm-actions"><button type="button" id="ttm-save" onclick="ttmAction('policy')">Сохранить политику</button></div>
<p class="ttm-muted">Изменение политики доступно только после явного отключения аддона. Доменные списки, GeoIP и полноценная IPv6-маршрутизация ещё не реализованы.</p>
<h3>Подключение к серверу</h3>
<p>В этой версии учётные данные импортируются по SSH из приватного JSON-файла. Пароль не передаётся через <code>custom_settings</code> и не публикуется в статусе.</p>
<p><code>trusttunnel.sh import-endpoint /tmp/endpoint.json</code></p>
<p class="ttm-muted">Формат: examples/endpoint.example.json. Журнал клиента доступен только локально: /tmp/trusttunnel/client.log.</p>
</div></td></tr></table><div id="footer"></div></body></html>
