/* Native Merlin control; connection credentials stay in memory until explicit local export. */
(function (root) {
    'use strict';
    var api = {}, latest = null, initialized = false, lastSeen = 0, rowIndex = 0, pending = false;
    var networkModels = new WeakMap(), importedDns = null;
    function ipv4(s) {
        if (typeof s !== 'string' || !/^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$/.test(s)) return null;
        var a = s.split('.').map(Number);
        return a.every(function (x) { return x <= 255; }) ? a : null;
    }
    function validCidr(s) {
        var parts = s.split('/'), a = ipv4(parts[0]);
        if (!a || parts.length !== 2 || !/^(0|[1-9]\d?)$/.test(parts[1])) return false;
        var n = Number(parts[1]), size = Math.pow(2, 32 - n);
        return n <= 32 && ((a[0] === 10 && n >= 8) || (a[0] === 172 && a[1] >= 16 && a[1] <= 31 && n >= 12) ||
            (a[0] === 192 && a[1] === 168 && n >= 16)) &&
            (a[0] * 16777216 + a[1] * 65536 + a[2] * 256 + a[3]) % size === 0;
    }
    function policyFromNetworks(rows, acknowledge) {
        var total = 0, seen = [], networks = rows.filter(function (row) { return row.selected !== false; }).map(function (row) {
            var lan = row.lan_if.trim(), cidrs = Array.isArray(row.sources) ? row.sources : row.sources.trim().split(/[\s,;]+/).filter(Boolean);
            if (!/^br[0-9]+(?:\.[0-9]+)?$/.test(lan) || lan.length > 15) throw new Error('Не удалось определить сетевой интерфейс. Обновите страницу.');
            if (seen.indexOf(lan) >= 0) throw new Error('Одна сеть указана несколько раз. Объедините её подсети.');
            seen.push(lan);
            if (!cidrs.length || cidrs.some(function (s) { return !validCidr(s); })) throw new Error('Укажите корректные частные IPv4-подсети, например 192.168.50.0/24, или адреса /32.');
            if (new Set(cidrs).size !== cidrs.length) throw new Error('В сети есть повторяющиеся подсети.');
            total += cidrs.length;
            return {lan_if: lan, sources: cidrs};
        });
        if (!networks.length || networks.length > 16 || total > 32) throw new Error('Выберите от 1 до 16 сетей, не более 32 записей подсетей суммарно.');
        if (!acknowledge) throw new Error('Подтвердите блокировку IPv6 в выбранных сетях.');
        return {schema: 3, networks: networks, block_ipv6_bridge: true, table: 871, priority: 17100};
    }
    function makeEnvelope(settings, policy) {
        // Only construct an allowlisted non-secret policy; never serialize arbitrary input.
        if ([1,2,3].indexOf(policy.schema) < 0) throw new Error('Неподдерживаемая версия политики.');
        var checked = policyFromNetworks(policy.schema === 1 ? [{lan_if:policy.lan_if,sources:policy.sources}] : policy.networks, policy.block_ipv6_bridge);
        var clone = Object.assign({}, settings || {}), encoded = root.btoa(JSON.stringify(checked));
        if (encoded.length > 2999) throw new Error('Политика превышает лимит Merlin. Скачайте её и импортируйте по SSH.');
        clone.ttm_policy = encoded;
        var serialized = JSON.stringify(clone);
        if (new TextEncoder().encode(serialized).length > 7600) throw new Error('Недостаточно места в хранилище аддонов. Используйте импорт политики по SSH.');
        return serialized;
    }
    api.policyFromNetworks = policyFromNetworks; api.makeEnvelope = makeEnvelope;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    if (!root.document) return;
    function el(id) { return document.getElementById(id); }
    function text(id, value) { el(id).textContent = String(value); }
    function message(value, error, target) { target = target || 'ttm-message'; text(target,value); el(target).className = error ? 'ttm-error' : 'ttm-note'; }
    function controls(ok) {
        document.querySelectorAll('[data-runtime]').forEach(function (button) { button.disabled = !ok || pending; });
        el('ttm-policy-fields').disabled = !ok || pending || !!(latest && latest.enabled);
        el('ttm-save').disabled = el('ttm-export-policy').disabled = el('ttm-policy-fields').disabled;
    }
    function networkTitle(network) {
        return Array.isArray(network.ssids) && network.ssids.length ? network.ssids.join(' / ') : 'Локальная сеть — SSID не определён';
    }
    function addNetwork(network, selected, available) {
        var index = ++rowIndex, row = document.createElement('div'); row.className = 'ttm-network';
        var info = document.createElement('div'), choice = document.createElement('label'), checkbox = document.createElement('input'), caption = document.createElement('span');
        checkbox.type = 'checkbox'; checkbox.className = 'ttm-selected'; checkbox.checked = !!selected;
        checkbox.addEventListener('change',function () {
            if (!networkModels.get(row).available && !checkbox.checked) checkbox.disabled=true;
            updateCount();
        }); caption.className = 'ttm-caption';
        caption.textContent = available ? networkTitle(network) : 'Сохранённая сеть недоступна';
        choice.appendChild(checkbox); choice.appendChild(caption); info.appendChild(choice);
        var hint = document.createElement('small'); hint.className = 'ttm-network-hint'; info.appendChild(hint); row.appendChild(info);
        var box = document.createElement('div'), name = document.createElement('label'), sources = document.createElement('textarea');
        sources.id = 'ttm-network-' + index + '-sources'; sources.className = 'ttm-cidrs'; sources.spellcheck = false;
        sources.value = (network.sources || []).join('\n'); sources.placeholder = '192.168.50.0/24';
        name.htmlFor = sources.id; name.textContent = 'Подсети / адреса IPv4'; box.appendChild(name); box.appendChild(sources); row.appendChild(box);
        // The firmware association is held in memory, never read from an editable DOM field.
        networkModels.set(row,{identity:Object.freeze({lan_if:network.lan_if}),available:!!available});
        el('ttm-networks').appendChild(row); return row;
    }
    function updateCount() { text('ttm-network-count',document.querySelectorAll('.ttm-selected:checked').length + ' сетей выбрано'); }
    function rows() { return Array.from(document.querySelectorAll('.ttm-network')).map(function (row) {
        var model = networkModels.get(row);
        return {selected:row.querySelector('.ttm-selected').checked,available:model.available,lan_if:model.identity.lan_if,sources:row.querySelector('.ttm-cidrs').value};
    }); }
    function policy() {
        if (rows().some(function (row) { return row.selected && !row.available; })) throw new Error('Выбранная сеть больше не обнаружена. Снимите её выбор и проверьте настройки Wi-Fi роутера.');
        return policyFromNetworks(rows(),el('ttm-v6ack').checked);
    }
    root.ttmSelectNetworks = function (value) { document.querySelectorAll('.ttm-network').forEach(function (row) {
        var checkbox=row.querySelector('.ttm-selected'), available=networkModels.get(row).available;
        checkbox.checked = !!value && available; checkbox.disabled=!available;
    }); updateCount(); };
    function reconcileNetworks(status) {
        var inventory = Array.isArray(status.discovered_networks) ? status.discovered_networks : [];
        var selected = status.policy ? (status.policy.schema === 1 ? [{lan_if:status.policy.lan_if,sources:status.policy.sources}] : status.policy.networks) : [];
        if (!initialized) {
            el('ttm-networks').textContent=''; rowIndex=0;
            inventory.forEach(function (network) {
                var saved=selected.find(function (n) { return n.lan_if===network.lan_if; });
                addNetwork(Object.assign({},network,{sources:saved?saved.sources:network.sources}),!!saved,true);
            });
            selected.forEach(function (network) {
                if (!inventory.some(function (n) { return n.lan_if===network.lan_if; })) addNetwork(network,true,false);
            });
            if (status.policy) el('ttm-v6ack').checked=status.policy.block_ipv6_bridge;
            initialized=true;
        } else {
            inventory.forEach(function (network) {
                if (!rows().some(function (r) { return r.lan_if===network.lan_if; })) addNetwork(network,false,true);
            });
        }
        document.querySelectorAll('.ttm-network').forEach(function (row) {
            var model=networkModels.get(row), network=inventory.find(function (n) { return n.lan_if===model.identity.lan_if; });
            model.available=!!network;
            row.querySelector('.ttm-selected').disabled=!network && !row.querySelector('.ttm-selected').checked;
            row.querySelector('.ttm-cidrs').disabled=!network;
            row.querySelector('.ttm-caption').textContent=network?networkTitle(network):'Сохранённая сеть недоступна';
            row.querySelector('.ttm-network-hint').textContent=!network?'Эта сеть не обнаружена. Её нельзя включить в новую политику.':
                (Array.isArray(network.ssids)&&network.ssids.length>1?'Эти SSID используют одну сеть и выбираются вместе.':
                (network.ssids&&network.ssids.length?'Сетевое подключение определено роутером.':'Имя Wi-Fi получить не удалось. Сеть можно определить по её подсети.'));
        });
        el('ttm-networks-empty').hidden=inventory.length>0;
        updateCount();
    }
    function render(status) {
        if (!status || typeof status.enabled !== 'boolean' || typeof status.timestamp !== 'number') throw new Error('Invalid status');
        latest = status; lastSeen = Date.now();
        var labels = {disabled:'Отключён',paused_protected:'Пауза; блокировка запрошена',blocked_or_start_failed:'Процесс остановлен / ошибка',tun_ready_unverified:'TUN создан; связь не проверена'};
        text('ttm-state',labels[status.state] || 'Неизвестное состояние'); text('ttm-version',status.version);
        text('ttm-host',status.hostname || 'Подключение ещё не импортировано');
        text('ttm-process',status.process_running ? 'Запущен' : 'Не запущен'); text('ttm-tun',status.interface_up ? 'tt0' : 'Нет TUN');
        text('ttm-counter',(status.rx_bytes/1048576).toFixed(2) + ' / ' + (status.tx_bytes/1048576).toFixed(2) + ' MiB');
        text('ttm-age',new Date(status.timestamp*1000).toLocaleTimeString()); text('ttm-last',status.last_result || 'none');
        var fresh = !!root.TTM_PREVIEW || Math.abs(Date.now()/1000-status.timestamp) < 150;
        controls(fresh);
        if (!fresh) message('Статус устарел. Управление заблокировано до обновления контроллера.',true);
        reconcileNetworks(status);
    }

    function refresh() {
        if (root.TTM_PREVIEW) { render(root.TTM_PREVIEW); return; }
        var request = new XMLHttpRequest(); request.open('GET','/user/trusttunnel/status.json?t='+Date.now(),true); request.timeout=5000;
        request.onload = function () { try { if (request.status !== 200) throw new Error('Unavailable'); render(JSON.parse(request.responseText)); }
            catch (_) { controls(false); message('Не удалось прочитать статус. Проверьте контроллер по SSH.',true); } };
        request.onerror = request.ontimeout = function () { controls(false); message('Нет актуального статуса роутера.',true); }; request.send();
    }
    function send(action,p) {
        if (['start','pause','restart','disable','policy'].indexOf(action)<0) throw new Error('Unknown action');
        if (root.TTM_PREVIEW) { message('Демонстрация: проверка пройдена, команда не отправлена на роутер.',false); return; }
        if (!latest || Date.now()-lastSeen>15000 || Math.abs(Date.now()/1000-latest.timestamp)>150 || pending) throw new Error('Дождитесь актуального статуса и завершения предыдущей команды.');
        var form = document.forms.ttm_form;
        form.elements.amng_custom.disabled = !p;
        form.elements.amng_custom.value = p ? makeEnvelope(root.ttmCustomSettings || {},p) : '';
        form.elements.action_script.value = 'start_ttm_'+action;
        form.elements.current_page.value = form.elements.next_page.value = location.pathname.substring(1);
        pending = true; controls(false); form.submit();
        message('Команда отправлена. Проверьте последнюю операцию и время обновления статуса.',false);
        root.setTimeout(function () { pending=false; refresh(); },12000);
    }
    root.ttmAction = function (action) { try {
        if (action==='disable' && !root.confirm('Вернуть выбранные сети к обычной маршрутизации Merlin?')) return;
        if (action==='policy' && latest && latest.enabled) throw new Error('Сначала отключите аддон.');
        send(action,action==='policy' ? policy() : null);
    } catch(e) { message(e.message,true); } };
    function download(value,name) {
        var url = URL.createObjectURL(new Blob([JSON.stringify(value,null,2)+'\n'],{type:'application/json'})), a=document.createElement('a');
        a.href=url; a.download=name; document.body.appendChild(a); a.click(); a.remove(); root.setTimeout(function () { URL.revokeObjectURL(url); },1000);
    }
    root.ttmExportPolicy = function () { try { download(policy(),'trusttunnel-policy.json'); message('Политика скачана. Импорт по SSH: trusttunnel.sh import-policy /tmp/trusttunnel-policy.json',false); } catch(e) { message(e.message,true); } };
    root.ttmConnectionMode = function (mode) {
        el('ttm-manual').hidden=mode!=='manual'; el('ttm-link-panel').hidden=mode!=='link';
        el('ttm-tab-manual').setAttribute('aria-selected',String(mode==='manual')); el('ttm-tab-link').setAttribute('aria-selected',String(mode==='link'));
    };
    var fields = {hostname:'hostname',addresses:'addresses',username:'username',password:'password',protocol:'protocol',certificate:'certificate',anti_dpi:'anti-dpi',mtu:'mtu',wan_if:'wan'};
    function readEndpoint() {
        var result={}; Object.keys(fields).forEach(function (key) { var field=el('ttm-'+fields[key]); result[key]=key==='anti_dpi'?field.checked:field.value; });
        result.dns_upstreams=importedDns===null?el('ttm-upstreams').value:importedDns.slice();
        return root.TTMConnection.endpointFromFields(result);
    }
    function fillEndpoint(endpoint) { Object.keys(fields).forEach(function (key) { var field=el('ttm-'+fields[key]), value=endpoint[key];
        if (key==='anti_dpi') field.checked=value; else field.value=Array.isArray(value)?value.join('\n'):value;
    });
        importedDns=endpoint.dns_upstreams.slice();
        el('ttm-upstreams').value=importedDns.join('\n'); el('ttm-upstreams').readOnly=true;
        text('ttm-dns-hint',importedDns.length?'DNS из конфигурации tt://. Значение сохраняется без изменений.':'В конфигурации tt:// DNS не задан. Для запуска нужна конфигурация с DNS.');
    }
    root.ttmParseLink = function () { try {
        var result=root.TTMConnection.parseLink(el('ttm-link').value.trim()); fillEndpoint(result.endpoint); el('ttm-link').value='';
        root.ttmConnectionMode('manual'); message('Ссылка разобрана.'+(result.name?' Профиль: '+result.name+'.':'')+' Проверьте параметры перед экспортом.'+(result.warnings.length?' '+result.warnings.join(' '):''),false,'ttm-connection-message');
    } catch(e) { message(e.message,true,'ttm-connection-message'); } };
    root.ttmExportEndpoint = function () { try { var endpoint=readEndpoint(); download(endpoint,'trusttunnel-endpoint.json');
        message('Конфигурация проверена и скачана. Примените её по SSH по инструкции ниже. На роутере пока ничего не изменено.',false,'ttm-connection-message');
    } catch(e) { message(e.message,true,'ttm-connection-message'); } };
    root.ttmShowPassword = function (show) { el('ttm-password').type=show?'text':'password'; };
    root.ttmClearConnection = function () { el('ttm-endpoint-form').reset(); importedDns=null; el('ttm-upstreams').readOnly=false; text('ttm-dns-hint','DNS задаётся только в конфигурации подключения. Для ручного подключения укажите его здесь.'); el('ttm-link').value=''; root.ttmShowPassword(false); message('Данные подключения очищены из формы.',false,'ttm-connection-message'); };
    root.done_validating = function () { refresh(); };
    root.ttmInitial = function () {
        if (typeof root.show_menu==='function') root.show_menu();
        refresh(); if (!root.TTM_PREVIEW) root.setInterval(refresh,5000);
    };
    root.TTM=api;
}(typeof window!=='undefined'?window:globalThis));
