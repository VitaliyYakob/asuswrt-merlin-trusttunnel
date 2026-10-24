/* Native Merlin control. Secrets leave memory only on explicit encrypted save/export. */
(function (root) {
    'use strict';
    var api = {}, latest = null, initialized = false, lastSeen = 0, rowIndex = 0, pending = false, statusNotice = false;
    var networkModels = new WeakMap(), importedDns = null, dirty = {}, editRevision = null, policyRevision = null;
    var activeAction = null, unresolvedOperation = null, profileConfigured = null, lastMetrics = null, lastCpu = '—', routerTime = null, routerTimeSeen = 0;
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
    function contains(cidr,address) {
        if (!validCidr(cidr)||!ipv4(address)) return false;
        function number(s) { return ipv4(s).reduce(function (a,n) { return a*256+n; },0); }
        var parts=cidr.split('/'), start=number(parts[0]); return number(address)>=start && number(address)<start+Math.pow(2,32-Number(parts[1]));
    }
    function clientsForSsid(clients, network, ssid) {
        return (clients||[]).filter(function (client) {
            if (!(network.sources||[]).some(function (source) { return contains(source,client.ip); })) return false;
            if (!ssid) return true;
            var associations=Array.isArray(client.wireless)?client.wireless:[];
            var bindings=new Set(associations.map(function (w) { return JSON.stringify([w.lan_if,w.ssid]); }));
            return bindings.size===1 && associations.some(function (w) { return w.lan_if===network.lan_if && w.ssid===ssid; });
        });
    }
    function policyFromNetworks(rows, acknowledge, ports) {
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
        if ((!networks.length && !(ports||[]).length) || networks.length > 16 || total > 32) throw new Error('Выберите сеть, устройство или LAN-порт; до 16 сетей и 32 записей подсетей.');
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
    function publicDiagnostics(status) {
        var diag=status.diagnostics||{}, report={schema:1,version:status.version,state:status.state,
            process_running:!!status.process_running,interface_up:!!status.interface_up,network_count:(status.policy && status.policy.networks||[]).length};
        report.tools=(diag.tools||[]).filter(function (tool) { return /^[a-z0-9-]{1,32}$/.test(tool.name); }).map(function (tool) { return {name:tool.name,available:!!tool.available}; });
        report.operations=(status.operations||[]).map(function (op) { return {action:/^[a-z_-]{1,32}$/.test(op.action)?op.action:'unknown',state:/^(running|failed|succeeded)$/.test(op.state)?op.state:'unknown',code:/^[a-z_]{1,48}$/.test(op.code)?op.code:'unknown'}; });
        report.model=/^[A-Za-z0-9_-]{1,32}$/.test(diag.model)?diag.model:'unknown';
        report.architecture=/^(aarch64|armv7l|offline)$/.test(diag.architecture)?diag.architecture:'unknown';
        report.firmware=/^[0-9._]{1,32}$/.test(diag.firmware)?diag.firmware:'unknown';
        return report;
    }
    api.publicDiagnostics=publicDiagnostics;
    function connectionAction(status) { return status && status.process_running ? 'disable' : 'start'; }
    api.connectionAction = connectionAction;
    api.policyFromNetworks = policyFromNetworks; api.makeEnvelope = makeEnvelope; api.contains=contains; api.clientsForSsid=clientsForSsid;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    if (!root.document) return;
    function monotonicNow() { return root.performance ? root.performance.now() : Date.now(); }
    function observeServerTime(value) { var time=Date.parse(value||''); if (Number.isFinite(time)) { routerTime=time/1000; routerTimeSeen=monotonicNow(); } }
    function routerNow() { return routerTime===null?Date.now()/1000:routerTime+(monotonicNow()-routerTimeSeen)/1000; }
    function statusFresh(status) { var now=routerNow(); return !!root.TTM_PREVIEW || !!status && Math.abs(now-status.timestamp)<150; }
    function el(id) { return document.getElementById(id); }
    function updateDirty() { text('ttm-dirty',Object.keys(dirty).length?'Есть несохранённые изменения':'Нет несохранённых изменений'); }
    function markDirty(kind) { if (!Object.keys(dirty).length) editRevision=latest ? latest.revision||'0' : '0'; dirty[kind]=true; updateDirty(); controls(true); }
    root.ttmView=function (name) {
        document.querySelectorAll('[data-view]').forEach(function (section) { section.hidden=section.dataset.view!==name; });
        document.querySelectorAll('[data-view-button]').forEach(function (button) { button.setAttribute('aria-selected',String(button.dataset.viewButton===name)); button.tabIndex=button.dataset.viewButton===name?0:-1; });
    };
    root.ttmReload=async function () {
        if (pending) return;
        if (unresolvedOperation) { await root.ttmCheckOperation(); return; }
        if (Object.keys(dirty).length && !root.confirm('Сбросить несохранённые изменения?')) return;
        initialized=false; dirty={}; editRevision=null; root.ttmClearConnection(); updateDirty();
        if (root.TTM_PREVIEW) { refresh(); return; }
        pending=true; controls(false);
        try {
            var id=root.TTMTransfer.id(root.crypto);
            message('Запрашивается новый статус контроллера…',false);
            await wire('start_ttm_do_'+id+'_status');
            await waitOperation(id);
            statusNotice=false; message('Статус обновлён.',false);
        } catch(e) { message(e.message,true); }
        finally { pending=false; controls(true); refresh(); }
    };
    function text(id, value) { el(id).textContent = String(value); }
    function dateLabel(value, fallback) {
        if (typeof value!=='number' || !Number.isFinite(value) || value<=0) return fallback;
        var date=new Date(value*1000);
        return Number.isNaN(date.getTime()) ? fallback : date.toLocaleString('ru-RU');
    }
    var startErrors={update_pending:'Сначала подтвердите новую версию CLI или верните предыдущую.',update_check_failed:'Не удалось получить официальный список релизов. Проверьте доступ к GitHub и повторите поиск.',update_failed:'Обновление не завершилось. Обновите статус; при незавершённом восстановлении потребуется recover-client по SSH.',endpoint_missing:'Сначала сохраните корректное подключение.',policy_missing:'Выберите сети во вкладке «Сети» и нажмите «Сохранить маршрутизацию».',client_missing:'Не установлен проверенный клиент TrustTunnel.',forwarding_disabled:'На роутере отключена пересылка IPv4.',dns_missing:'В подключении не задан DNS.',dns_conflict:'Не удалось проверить внутренний адрес DNS.',ports_unavailable:'Проверьте доступность LAN-портов, WAN/IPTV/агрегацию и конфликтующие правила других VPN. Снимите недоступные порты во вкладке «Сети».',network_changed:'Состав выбранных сетей изменился. Проверьте вкладку «Сети».',offload_unavailable:'Прошивка не предоставляет SKIPLOG или выборочное управление кешем потоков. Запуск заблокирован для защиты выбранных сетей.',offload_flush_failed:'Не удалось очистить ускоренные потоки выбранной сети. Защитные правила сохранены.',tun_unavailable:'Не удалось загрузить штатный TUN-модуль роутера.',missing_dependency:'На роутере отсутствует необходимая утилита.'};
    function operationLabel(op) {
        var actions={status:'Обновление статуса',start:'Запуск',pause:'Пауза',restart:'Перезапуск',disable:'Отключение',endpoint:'Подключение',exclusions:'Исключения',policy:'Маршрутизация',endpoint_settings:'Параметры подключения',downgrade_client:'Переход на предыдущую сборку',confirm_client:'Подтверждение CLI',rollback_client:'Возврат предыдущего CLI',diagnostics:'Диагностика',check_updates:'Поиск обновлений',update_client:'Обновление CLI',channel_stable:'Стабильный канал',channel_nightly:'Ночной канал'};
        var states={running:'выполняется',succeeded:'выполнено',failed:'ошибка'};
        var codes={confirmation_required:'нужно подтверждение',revision_conflict:'настройки изменены в другой вкладке',transaction_pending:'сначала завершите пробное применение',invalid_configuration:'некорректная конфигурация',apply_failed:'не удалось применить',action_failed:'не удалось выполнить'};
        return (actions[op.action]||'Операция')+' · '+(startErrors[op.code]||codes[op.code]||states[op.state]||'результат неизвестен');
    }
    function message(value, error, target) { target = target || 'ttm-message'; text(target,value); el(target).className = error ? 'ttm-error' : 'ttm-note'; }
    function controls(ok) {
        var disconnect=connectionAction(latest)==='disable';
        text('ttm-toggle',pending && activeAction==='start'?'Подключение…':pending && activeAction==='disable'?'Отключение…':disconnect?'Отключить':'Подключить');
        el('ttm-toggle').classList.toggle('ttm-release',disconnect);
        // A paused or failed client can resume without releasing its guards.
        // Explicit release remains reachable under advanced actions.
        el('ttm-release-guards').hidden=!(latest && latest.enabled && !latest.process_running);
        ok=ok && !!latest && statusFresh(latest) && !unresolvedOperation;
        document.querySelectorAll('[data-runtime]').forEach(function (button) { button.disabled = !ok || pending || !!unresolvedOperation || !!latest.transaction; });
        document.querySelectorAll('[data-view="connection"] input,[data-view="connection"] textarea,[data-view="connection"] select,[data-view="connection"] button').forEach(function (field) { field.disabled=pending; });
        el('ttm-policy-fields').disabled = !ok || pending || !!unresolvedOperation || !!(latest && latest.transaction) || !!(latest && latest.health && !latest.health.details_ready);
        el('ttm-save').disabled = el('ttm-export-policy').disabled = el('ttm-policy-fields').disabled;
        el('ttm-save-endpoint').disabled = !ok || pending || !!unresolvedOperation || !!(latest && latest.transaction) || !!((latest||{}).client_updates||{}).recovery_pending;
        el('ttm-nightly').disabled=!ok || pending || !!latest.transaction || !!((latest||{}).client_updates||{}).recovery_pending;
        var updates=(latest||{}).client_updates||{}, check=updates.check;
        el('ttm-update-client').disabled=!ok || pending || !!latest.transaction || !updates.dependencies_ready || updates.recovery_pending || !check || ['available','older'].indexOf(check.state)<0 || !check.candidate || check.channel!==updates.channel || (!root.TTM_PREVIEW && (routerNow()-check.checked_at>3600 || check.checked_at>routerNow()));
        text('ttm-update-client',check && check.state==='older'?'Перейти на предыдущую сборку':'Обновить CLI');
        el('ttm-confirm-client').disabled=!ok || pending || !updates.trial || updates.trial.remaining_seconds<=0 || !latest.process_running;
        el('ttm-rollback-client').disabled=!ok || pending || !!latest.transaction || !(updates.rollback_available || updates.recovery_pending);
        el('ttm-policy-fields').disabled=el('ttm-policy-fields').disabled || !!updates.recovery_pending;
        el('ttm-save').disabled=el('ttm-export-policy').disabled=el('ttm-policy-fields').disabled;
        var conflict=!!latest && Object.keys(dirty).length>0 && editRevision!==(latest.revision||'0');
        el('ttm-conflict').hidden=!conflict;
        el('ttm-save').disabled=el('ttm-save').disabled || conflict;
        el('ttm-save-endpoint').disabled=el('ttm-save-endpoint').disabled || conflict;
        el('ttm-save-exclusions').disabled = el('ttm-save-endpoint').disabled || !(latest && latest.endpoint && latest.endpoint.configured) || !!dirty.endpoint;
        el('ttm-save-settings').disabled=el('ttm-save-exclusions').disabled;
        el('ttm-operation-progress').hidden=!pending && !unresolvedOperation;
        text('ttm-operation-progress',pending?(activeAction==='start'?'Подключение клиента…':activeAction==='disable'?'Отключение клиента…':'Ожидание подтверждения от роутера…'):
            'Ответ не получен. Нажмите «Проверить результат», прежде чем повторять действие.');
        el('ttm-check-operation').hidden=!unresolvedOperation;
        el('ttm-check-operation').disabled=pending;
    }
    function networkTitle(network) {
        if (Array.isArray(network.ssids) && network.ssids.length>1) return 'Общая подсеть · '+(network.sources||[]).join(', ');
        if (typeof network.display_name==='string' && network.display_name) return network.display_name;
        return Array.isArray(network.ssids) && network.ssids.length ? network.ssids.join(' / ') : 'Локальная сеть — SSID не определён';
    }
    function addNetwork(network, selected, available, allSources) {
        var index = ++rowIndex, row = document.createElement('div'); row.className = 'ttm-network';
        var info = document.createElement('div'), choice = document.createElement('label'), checkbox = document.createElement('input'), caption = document.createElement('span');
        checkbox.type = 'checkbox'; checkbox.className = 'ttm-selected'; checkbox.checked = !!selected;
        checkbox.addEventListener('change',function () {
            if (!networkModels.get(row).available && !checkbox.checked) checkbox.disabled=true;
            updateCount();
        }); caption.className = 'ttm-caption';
        caption.textContent = available ? networkTitle(network) : 'Сохранённая сеть недоступна';
        choice.appendChild(checkbox); choice.appendChild(caption); info.appendChild(choice);
        var hint = document.createElement('small'); hint.className = 'ttm-network-hint'; info.appendChild(hint);
        row.appendChild(info);
        var box = document.createElement('div'), name = document.createElement('label'), sources = document.createElement('textarea');
        sources.id = 'ttm-network-' + index + '-sources'; sources.className = 'ttm-cidrs'; sources.spellcheck = false;
        sources.value = (network.sources || []).join('\n'); sources.placeholder = '192.168.50.0/24';
        name.htmlFor = sources.id; name.textContent = 'Подсети / адреса IPv4'; box.appendChild(name); box.appendChild(sources); row.appendChild(box);
        // The firmware association is held in memory, never read from an editable DOM field.
        var original=(allSources||network.sources||[]).slice(), current=(network.sources||[]).slice();
        var mode=current.slice().sort().join()===original.slice().sort().join()?'whole':current.length && current.every(function (v) { return /\/32$/.test(v); })?'devices':'custom';
        networkModels.set(row,{identity:Object.freeze({lan_if:network.lan_if,token:network.identity}),available:!!available,
            mode:mode,original:original,drafts:{whole:original.join('\n'),devices:mode==='devices'?current.join('\n'):'',custom:current.join('\n')}});
        var modeLabel=document.createElement('label'), modes=document.createElement('select');
        modes.className='ttm-network-mode'; modes.id='ttm-network-'+index+'-mode'; modeLabel.htmlFor=modes.id; modeLabel.textContent='Направлять через VPN';
        modes.add(new Option('Вся сеть','whole')); modes.add(new Option('Выбранные устройства','devices')); modes.add(new Option('Свои подсети / адреса','custom')); modes.value=mode;
        modes.addEventListener('change',function () {
            var model=networkModels.get(row), next=modes.value;
            model.drafts[model.mode]=sources.value;
            if (next!=='custom' && model.drafts[next]!==sources.value && sources.value.trim() &&
                !root.confirm(next==='whole'?'Применить VPN ко всей этой сети?':'Перейти к отдельным устройствам? Текущие подсети останутся в черновике режима «Свои подсети».')) { modes.value=model.mode; return; }
            model.mode=next; sources.value=model.drafts[next]; sources.readOnly=next!=='custom';
            model.devicesSignature=null; renderNetworkDevices(row,latest.discovered_networks.find(function (n) { return n.lan_if===model.identity.lan_if; })||network,model.available);
            markDirty('policy');
        });
        box.insertBefore(modes,name); box.insertBefore(modeLabel,modes); sources.readOnly=mode!=='custom';
        var devicesBox=document.createElement('div'); devicesBox.className='ttm-ssid-rows'; row.appendChild(devicesBox);
        el('ttm-networks').appendChild(row); return row;
    }
    function addDevicePicker(box, row, clients, ssid) {
        var devices=document.createElement('select'); devices.className='ttm-device'; devices.setAttribute('aria-label',ssid?'Добавить устройство из '+ssid:'Добавить устройство по IPv4');
        devices.add(new Option(clients.length?'Добавить устройство…':'Нет подтверждённых устройств',''));
        clients.forEach(function (client) { devices.add(new Option(client.name+' · '+client.ip,client.ip+'/32')); });
        devices.disabled=!clients.length || networkModels.get(row).mode!=='devices';
        devices.addEventListener('change',function () { if (!devices.value || networkModels.get(row).mode!=='devices') return;
            var sources=row.querySelector('.ttm-cidrs'), checkbox=row.querySelector('.ttm-selected');
            var list=sources.value.trim().split(/[\s,;]+/).filter(Boolean);
            if (list.indexOf(devices.value)<0) list.push(devices.value);
            sources.value=list.join('\n'); checkbox.checked=true; devices.value=''; markDirty('policy'); updateCount();
        }); box.appendChild(devices);
    }
    function renderNetworkDevices(row, network, available) {
        var model=networkModels.get(row), names=available?(network.ssids||[]):[];
        var groups=names.length?names.map(function (ssid) { return {ssid:ssid,clients:clientsForSsid(latest.clients,network,ssid)}; }):[{ssid:null,clients:available?clientsForSsid(latest.clients,network,null):[]}];
        var signature=JSON.stringify(groups.map(function (group) { return [group.ssid,group.clients.map(function (client) { return [client.ip,client.name]; })]; }));
        if (model.devicesSignature===signature) return;
        model.devicesSignature=signature;
        row.querySelectorAll('.ttm-device').forEach(function (picker) { picker.remove(); });
        var box=row.querySelector('.ttm-ssid-rows'); box.textContent=''; box.hidden=names.length<2;
        groups.forEach(function (group) {
            if (names.length<2) { addDevicePicker(row.children[1],row,group.clients,group.ssid); return; }
            var card=document.createElement('div'); card.className='ttm-ssid-row';
            var title=document.createElement('div'), name=document.createElement('strong'), hint=document.createElement('small');
            name.textContent=group.ssid; hint.textContent=(network.sources||[]).join(', ')+' · общая адресация'; title.appendChild(name); title.appendChild(hint); card.appendChild(title);
            var value=document.createElement('div'); addDevicePicker(value,row,group.clients,group.ssid); card.appendChild(value); box.appendChild(card);
        });
    }
    function updateCount() { text('ttm-network-count',document.querySelectorAll('.ttm-selected:checked').length + ' сетей · '+document.querySelectorAll('#ttm-ports input:checked').length+' портов выбрано'); }
    function rows() { return Array.from(document.querySelectorAll('.ttm-network')).map(function (row) {
        var model = networkModels.get(row);
        return {selected:row.querySelector('.ttm-selected').checked,available:model.available,identity:model.identity.token,lan_if:model.identity.lan_if,sources:row.querySelector('.ttm-cidrs').value};
    }); }
    function policy() {
        if (rows().some(function (row) { return row.selected && !row.available; })) throw new Error('Выбранная сеть больше не обнаружена. Снимите её выбор и проверьте настройки Wi-Fi роутера.');
        var ports=Array.from(document.querySelectorAll('#ttm-ports input:checked')).map(function (input) {
            var port=(latest.ports||[]).find(function (p) { return p.interface===input.value && p.available; });
            if (!port || !/^[0-9a-f]{64}$/.test(port.identity||'')) throw new Error('Выбранный порт недоступен. Обновите список или снимите выбор.');
            return {interface:port.interface,lan_if:port.lan_if,identity:port.identity};
        });
        var p=policyFromNetworks(rows(),el('ttm-v6ack').checked,ports);
        if (ports.length) p.ports=ports;
        p.schema=4; p.local_access=[];
        p.networks.forEach(function (network) {
            network.identity=rows().find(function (row) { return row.lan_if===network.lan_if; }).identity;
            if (!/^[0-9a-f]{64}$/.test(network.identity||'')) throw new Error('Обновите список сетей: не получена привязка от роутера.');
        });
        document.querySelectorAll('#ttm-local-access input:checked').forEach(function (input) {
            var network=(latest.discovered_networks||[]).find(function (n) { return n.identity===input.value; });
            if (!network) throw new Error('Локальная сеть изменилась. Обновите список.');
            network.sources.forEach(function (source) { p.local_access.push({lan_if:network.lan_if,destination:source,identity:network.identity}); });
        }); return p;
    }
    root.ttmSelectNetworks = function (value) { document.querySelectorAll('.ttm-network').forEach(function (row) {
        var checkbox=row.querySelector('.ttm-selected'), available=networkModels.get(row).available;
        checkbox.checked = !!value && available; checkbox.disabled=!available;
    }); updateCount(); markDirty('policy'); };
    function reconcileNetworks(status) {
        var inventory = Array.isArray(status.discovered_networks) ? status.discovered_networks : [];
        var selected = status.policy ? (status.policy.schema === 1 ? [{lan_if:status.policy.lan_if,sources:status.policy.sources}] : status.policy.networks) : [];
        if (!initialized || (!dirty.policy && policyRevision!==(status.revision||'0'))) {
            el('ttm-ports').textContent='';
            var ports=(status.ports||[]).slice(), savedPorts=(status.policy||{}).ports||[];
            savedPorts.forEach(function (saved) { if (!ports.some(function (p) { return p.interface===saved.interface; })) ports.push(Object.assign({},saved,{label:saved.interface,available:false,reason:'Сохранённый порт недоступен'})); });
            ports.forEach(function (port) {
                var label=document.createElement('label'), checkbox=document.createElement('input'), hint=document.createElement('small');
                label.className='ttm-check ttm-port'; checkbox.type='checkbox'; checkbox.value=port.interface;
                checkbox.checked=savedPorts.some(function (p) { return p.interface===port.interface; });
                checkbox.disabled=!port.available && !checkbox.checked;
                checkbox.addEventListener('change',function () { if (!port.available && !checkbox.checked) checkbox.disabled=true; markDirty('policy'); updateCount(); });
                label.appendChild(checkbox); label.appendChild(document.createTextNode(' '+port.label));
                hint.textContent=port.available?(port.link_up?'Кабель подключён':'Нет соединения по кабелю'):port.reason;
                label.appendChild(hint); el('ttm-ports').appendChild(label);
            });
            el('ttm-ports-empty').hidden=!!ports.length;
            el('ttm-networks').textContent=''; rowIndex=0;
            inventory.forEach(function (network) {
                var saved=selected.find(function (n) { return n.lan_if===network.lan_if; });
                addNetwork(Object.assign({},network,{sources:saved?saved.sources:network.sources}),!!saved,true,network.sources);
            });
            selected.forEach(function (network) {
                if (!inventory.some(function (n) { return n.lan_if===network.lan_if; })) addNetwork(network,true,false);
            });
            if (status.policy) el('ttm-v6ack').checked=status.policy.block_ipv6_bridge;
            el('ttm-local-access').textContent='';
            inventory.forEach(function (network) {
                var label=document.createElement('label'), checkbox=document.createElement('input'); label.className='ttm-check';
                checkbox.type='checkbox'; checkbox.value=network.identity||'';
                checkbox.checked=!!(status.policy && (status.policy.local_access||[]).some(function (n) { return n.identity===network.identity; }));
                label.appendChild(checkbox); label.appendChild(document.createTextNode(networkTitle(network)+' · '+network.sources.join(', ')));
                el('ttm-local-access').appendChild(label);
            });
            initialized=true; policyRevision=status.revision||'0';
        } else {
            inventory.forEach(function (network) {
                if (!rows().some(function (r) { return r.lan_if===network.lan_if; })) addNetwork(network,false,true);
            });
        }
        document.querySelectorAll('#ttm-ports input').forEach(function (input) {
            var port=(status.ports||[]).find(function (p) { return p.interface===input.value; });
            input.disabled=(!port || !port.available) && !input.checked;
            input.parentNode.querySelector('small').textContent=!port?'Порт больше не обнаружен':!port.available?port.reason:port.link_up?'Кабель подключён':'Нет соединения по кабелю';
        });
        document.querySelectorAll('.ttm-network').forEach(function (row) {
            var model=networkModels.get(row), network=inventory.find(function (n) { return n.lan_if===model.identity.lan_if; });
            model.available=!!network && model.identity.token===network.identity;
            row.querySelector('.ttm-selected').disabled=!model.available && !row.querySelector('.ttm-selected').checked;
            row.querySelector('.ttm-cidrs').disabled=!model.available;
            row.querySelector('.ttm-caption').textContent=model.available?networkTitle(network):'Сохранённая сеть недоступна';
            row.querySelector('.ttm-network-hint').textContent=!model.available?'Сеть исчезла или её состав изменился. Обновите данные перед сохранением.':
                (Array.isArray(network.ssids)&&network.ssids.length>1?'Ниже указаны общие IPv4-источники. Целая подсеть затронет оба SSID и проводных клиентов; выбор устройства добавляет только его /32.':
                (network.ssids&&network.ssids.length?'Сетевое подключение определено роутером.':'Имя Wi-Fi получить не удалось. Сеть можно определить по её подсети.'));
            renderNetworkDevices(row,network||{},model.available);
        });
        el('ttm-networks-empty').hidden=inventory.length>0;
        updateCount();
    }
    function inventoryOrEmpty(status) { return Array.isArray(status.discovered_networks)?status.discovered_networks:[]; }
    function renderWifiInventory(inventory) {
        var box=el('ttm-wifi-inventory'); box.textContent='';
        inventory.forEach(function (network) {
            var wireless=Array.isArray(network.wireless)?network.wireless:[], names=network.ssids||[];
            names.forEach(function (name) {
                var row=document.createElement('div'); row.className='ttm-wifi-row';
                var title=document.createElement('strong'); title.textContent=name; row.appendChild(title);
                var detail=document.createElement('span'); detail.textContent=(network.sources||[]).join(', ')+(names.length>1?' · общая подсеть с другими SSID':' · отдельный сегмент'); row.appendChild(detail);
                var interfaces=document.createElement('small'); interfaces.textContent='Интерфейсы: '+(wireless.filter(function (w) {return w.ssid===name;}).map(function (w) {return w.nvif+' → '+w.ifname;}).join(', ')||'нет подробных данных')+' · '+network.lan_if; row.appendChild(interfaces);
                box.appendChild(row);
            });
        });
        if (!box.children.length) box.textContent='Имена Wi-Fi пока не определены.';
    }
    function render(status) {
        if (!status || typeof status.enabled !== 'boolean' || typeof status.timestamp !== 'number') throw new Error('Invalid status');
        latest = status; lastSeen = monotonicNow();
        if (!Object.keys(dirty).length && !pending) editRevision=status.revision||'0';
        if (!dirty.endpoint && !dirty.exclusions && !pending) fillExclusions((status.endpoint||{}).exclusions||[]);
        var endpoint=status.endpoint||{}, configured=!!endpoint.configured, settings=endpoint.settings||{};
        el('ttm-profile').hidden=!configured;
        if (profileConfigured!==configured) { el('ttm-replace-connection').open=!configured; profileConfigured=configured; }
        el('ttm-setup').hidden=configured && !!status.policy;
        text('ttm-setup-state',!configured?'Шаг 1 из 3: сохраните подключение.':!status.policy?'Шаг 2 из 3: выберите сети для VPN.':'Шаг 3 из 3: подключите VPN и проверьте сайты из выбранной сети.');
        text('ttm-profile-server',status.hostname||'Не указан');
        text('ttm-profile-summary',(settings.protocol==='http3'?'HTTP/3 · QUIC':'HTTP/2 · TCP')+' · MTU '+(settings.mtu||1350)+' · Anti-DPI '+(settings.anti_dpi?'включён':'выключен'));
        if (!dirty.endpoint_settings && !pending) {
            el('ttm-setting-protocol').value=settings.protocol||'http2';
            el('ttm-setting-mtu').value=settings.mtu||1350;
            el('ttm-setting-anti-dpi').checked=!!settings.anti_dpi;
        }
        text('ttm-protection-note',status.enabled && !status.process_running?'Интернет выбранных сетей заблокирован до запуска клиента или явного отключения VPN.':
            status.enabled?'Отключение вернёт трафик выбранных сетей провайдеру без VPN.':'Выбранные сети используют обычное подключение к Интернету.');
        text('ttm-saved-connection',status.endpoint && status.endpoint.configured ? 'Подключение сохранено на роутере. Исключения можно менять отдельно; пароль и ссылка повторно не нужны.' : 'Подключение ещё не сохранено. Заполните параметры или импортируйте ссылку.');
        var labels = {disabled:'Отключён',paused_protected:'Пауза; блокировка запрошена',blocked_or_start_failed:'Процесс остановлен / ошибка',tun_ready_unverified:'Клиент запущен'};
        text('ttm-state',labels[status.state] || 'Неизвестное состояние'); el('ttm-state').dataset.state=status.state; text('ttm-version',status.version);
        text('ttm-host',status.hostname || 'Подключение ещё не импортировано');
        text('ttm-process',status.process_running ? 'Запущен' : 'Не запущен'); text('ttm-tun',status.interface_up ? 'tt0' : 'Нет TUN');
        text('ttm-counter',(status.rx_bytes/1048576).toFixed(2) + ' / ' + (status.tx_bytes/1048576).toFixed(2) + ' MiB');
        text('ttm-age',dateLabel(status.timestamp,'Дата неизвестна')); text('ttm-last',(status.operations||[]).length?operationLabel(status.operations[0]):'Нет записей');
        var fresh = statusFresh(status);
        controls(fresh);
        if (!fresh) {
            message('Статус не обновляется. Последнее обновление: '+dateLabel(status.timestamp,'дата неизвестна')+'. Нажмите «Обновить данные», чтобы запросить новый статус контроллера.',true);
            statusNotice=true;
        } else if (status.health && !status.health.details_ready) {
            message(status.health.error==='nvram_unavailable'?'Не удалось получить сведения о Wi-Fi от роутера. Состояние клиента обновлено; редактирование маршрутизации временно недоступно.':'Сбор сведений о сетях не завершился вовремя. Состояние клиента обновлено; редактирование маршрутизации временно недоступно.',true);
            statusNotice=true;
        } else if (statusNotice && !pending) { message('Статус обновлён.',false); statusNotice=false; }
        reconcileNetworks(status);
        text('ttm-network-warnings',(status.network_warnings||[]).join('\n'));
        el('ttm-network-warnings').hidden=!(status.network_warnings||[]).length;
        renderWifiInventory(inventoryOrEmpty(status));
        text('ttm-tun-address',(status.tunnel_addresses||[]).join(', ')||'Не назначен');
        var elapsed=status.client_uptime_seconds;
        text('ttm-client-uptime',status.process_running && Number.isFinite(elapsed)?Math.floor(elapsed/86400)+' сут. '+Math.floor(elapsed%86400/3600)+' ч '+Math.floor(elapsed%3600/60)+' мин':'Клиент остановлен / нет данных');
        var observation=status.traffic_observation;
        var observationLabels={sampling:'Первый снимок получен; ожидание следующего',traffic_observed:'Пакеты прошли через TUN в обе стороны',idle:'Двусторонний трафик за интервал не наблюдался — возможен простой',counters_reset:'Счётчики сброшены; ожидание нового интервала',incomplete:'Часть правил или маршрутов отсутствует'};
        text('ttm-auto-traffic',observation?dateLabel(observation.checked_at,'Дата неизвестна')+' · '+(observationLabels[observation.state]||'Результат неизвестен')+(observation.interval_seconds?' · за '+observation.interval_seconds+' с: отправлено '+observation.sent_packets+', получено '+observation.received_packets:''):'Нет свежего наблюдения. При работающем клиенте снимки обновляются примерно раз в минуту.');
        var updates=status.client_updates||{}, check=updates.check;
        text('ttm-client-version',(updates.installed||{}).version||(check||{}).installed_version||'Нажмите «Проверить обновления»');
        text('ttm-client-installed-at',dateLabel((updates.installed||{}).installed_at,'Дата неизвестна'));
        var history=updates.last_check||check;
        text('ttm-client-checked-at',dateLabel((history||{}).checked_at,'Ещё не выполнялась')+(history&&history.channel!==updates.channel?' · '+history.channel:''));
        el('ttm-nightly').checked=updates.channel==='nightly';
        text('ttm-client-update',!check?(updates.installed?'После установки или смены канала повторите проверку':'Проверьте доступные сборки'):check.state==='not_published'?(updates.channel==='nightly'?'Официальная nightly для ARM64 не опубликована':'Подходящий официальный релиз не найден'):check.state==='current'?'Установлен актуальный релиз':check.candidate?check.candidate.tag+' · '+check.candidate.channel+(check.state==='older'?' · старее установленной':check.state==='incompatible'?' · версия не распознана, установка заблокирована':''):'Результат неизвестен');
        el('ttm-client-trial').hidden=!updates.trial;
        text('ttm-client-trial-state',updates.trial?'Новый CLI применён временно. Проверьте сайты из выбранной сети и подтвердите в течение '+updates.trial.remaining_seconds+' с. Без подтверждения контроллер вернёт предыдущую версию.':'');
        el('ttm-rollback-client').hidden=!(updates.rollback_available || updates.recovery_pending);
        var metrics=status.metrics;
        if (!metrics || !lastMetrics || metrics.process_start!==lastMetrics.process_start) lastCpu='—';
        if (metrics && lastMetrics && metrics.process_start===lastMetrics.process_start && metrics.system_ticks>lastMetrics.system_ticks && metrics.cpu_ticks>=lastMetrics.cpu_ticks)
            lastCpu=((metrics.cpu_ticks-lastMetrics.cpu_ticks)/(metrics.system_ticks-lastMetrics.system_ticks)*metrics.cpu_count*100).toFixed(1)+'% одного ядра';
        text('ttm-resources',metrics?'Память '+(metrics.rss_kib/1024).toFixed(1)+' MiB · CPU '+lastCpu:'Нет данных процесса');
        if (metrics && (!lastMetrics || metrics.system_ticks!==lastMetrics.system_ticks)) lastMetrics=metrics;
        if (!metrics) lastMetrics=null;
        text('ttm-update-requirements',updates.recovery_pending?'Незавершённое обновление: требуется восстановление предыдущего клиента.':updates.dependencies_ready?'':'Для установки нужны curl, GnuPG, tar, timeout и od из Entware. Поиск обновлений требует curl.');
        text('ttm-ipv6-help','На выбранных физических портах блокируется IPv6-трафик этих портов и IPv6 DNS к роутеру. Аддон направляет через VPN только IPv4. Блокировка IPv6 действует на весь выбранный bridge, даже при выборе устройств /32.'+((status.diagnostics||{}).ipv6_service==='disabled'?' Сейчас IPv6 отключён в Merlin; правило защищает и после его включения.':''));
        text('ttm-guard',({disabled:'Отключена',unverified:'Проверка недоступна',installed_unverified:'Блокировка настроена; тест обрыва ещё не выполнен',incomplete:'Часть защитных правил отсутствует'})[(status.diagnostics||{}).guard]||'Нет данных');
        if (observation && observation.rules_checked) text('ttm-guard','Правила и маршрут проверены; тест обрыва ещё не выполнен');
        var startup=(status.diagnostics||{}).startup;
        text('ttm-startup',startup ? (startup.blockers||[]).map(function (code) { return startErrors[code]||code; }).concat((startup.notes||[]).includes('tun_load_on_start')?['TUN будет загружен автоматически при запуске.']:[]).join(' ') : '');
        el('ttm-startup').hidden=!el('ttm-startup').textContent;
        text('ttm-diagnostics',JSON.stringify(status.diagnostics||{hardware_tested:false},null,2));
        el('ttm-transaction').hidden=!status.transaction;
        if (status.transaction) text('ttm-transaction-state',status.transaction.phase==='trial' ?
            'Проверьте Интернет и DNS на выбранных устройствах. Подтвердите в течение '+Math.max(0,typeof status.transaction.remaining_seconds==='number'?status.transaction.remaining_seconds:status.transaction.deadline-Math.floor(Date.now()/1000))+' с. Без подтверждения будет запрошен откат.' :
            'Восстановление настроек. Блокировки сохранены; при ошибке используйте «Откатить».');
        el('ttm-confirm').disabled=pending||!status.transaction||status.transaction.phase!=='trial';
        text('ttm-operation-list',(status.operations||[]).slice(0,8).map(operationLabel).join('\n')||'Операций пока нет');
    }

    function refresh() {
        if (root.TTM_PREVIEW) { render(root.TTM_PREVIEW); return; }
        var request = new XMLHttpRequest(); request.open('GET','/user/trusttunnel/status.json?t='+Date.now(),true); request.timeout=5000;
        request.onload = function () { try { if (request.status !== 200) throw new Error('Unavailable'); observeServerTime(request.getResponseHeader('Date')); render(JSON.parse(request.responseText)); }
            catch (_) { controls(false); message(request.status===401 || request.status===403 || /login|Main_Login/i.test(request.responseText)?
                'Сессия Merlin завершена. Войдите в панель роутера снова.':'Не удалось прочитать статус. Нажмите «Обновить данные»; при повторной ошибке откройте диагностику.',true); } };
        request.onerror = request.ontimeout = function () { controls(false); message('Нет актуального статуса роутера.',true); }; request.send();
    }
    async function wire(command) {
        if (!/^start_ttm_[a-z0-9_]+$/.test(command)||command.length>127) throw new Error('Некорректная команда.');
        var form = document.forms.ttm_form;
        form.elements.amng_custom.disabled=true; form.elements.amng_custom.value='';
        form.elements.action_script.value=command;
        form.elements.current_page.value = form.elements.next_page.value = location.pathname.substring(1);
        // start_apply.htm contains parent-navigation scripts. Consume its HTML
        // as inert data, never load it in an iframe during a multipart transfer.
        var controller=new AbortController(), timer=root.setTimeout(function () { controller.abort(); },15000);
        try {
            var response=await root.fetch(form.getAttribute('action'),{method:'POST',
                credentials:'same-origin',body:new URLSearchParams(new FormData(form)),signal:controller.signal});
            var body=await response.text();
            if (response.status===401 || response.status===403 || /Main_Login\.asp|login_authorization/i.test(body)) {
                var denied=new Error('Сессия Merlin завершена или доступ отклонён. Войдите в панель роутера снова.'); denied.rejected=true; throw denied;
            }
            if (!response.ok) throw new Error('Приём команды не подтверждён (HTTP '+response.status+'). Проверьте результат перед повтором.');
        } finally { root.clearTimeout(timer); }
    }
    function delay(ms) { return new Promise(function (resolve) { root.setTimeout(resolve,ms); }); }
    async function poll(file,check,timeout) {
        var deadline=monotonicNow()+timeout;
        while (monotonicNow()<deadline) {
            await delay(1000);
            var controller=new AbortController(), timer=root.setTimeout(function () { controller.abort(); },5000);
            try { var response=await root.fetch('/user/trusttunnel/'+file+'.json?t='+Date.now(),{cache:'no-store',credentials:'same-origin',signal:controller.signal});
                if (response.ok) { observeServerTime(response.headers.get('Date')); var value=await response.json(); if (file==='status') render(value); if (check(value)) return value; }
            } catch (_) { /* A timeout never means successful completion. */ }
            finally { root.clearTimeout(timer); }
        }
        throw new Error('Подтверждение не получено. Результат неизвестен: обновите статус перед повторной операцией.');
    }
    async function waitOperation(id) {
        unresolvedOperation=id;
        var status=await poll('status',function (s) { return (s.operations||[]).some(function (op) { return op.id===id && op.state!=='running'; }); },360000);
        var op=status.operations.find(function (item) { return item.id===id; });
        unresolvedOperation=null;
        if (op.state!=='succeeded') throw new Error(op.code==='revision_conflict'?'Настройки изменены в другой вкладке. Обновите данные перед сохранением.':startErrors[op.code]||'Операция завершилась ошибкой: '+op.code);
        message(op.code==='confirmation_required'?'Настройки применены временно. Проверьте доступ и подтвердите применение.':'Операция выполнена.',false); return op;
    }
    async function busy(task) {
        if (!latest||monotonicNow()-lastSeen>15000||pending||unresolvedOperation) throw new Error('Дождитесь актуального статуса и проверьте результат предыдущей операции.');
        pending=true; controls(false);
        try { return await task(); }
        catch(e) { if (e.rejected) unresolvedOperation=null; throw e; }
        finally { pending=false; controls(true); refresh(); }
    }
    async function save(kind,data) {
        if (root.TTM_PREVIEW) { message('Демонстрация: конфигурация проверена; сохранение на роутер не выполнялось.',false); return; }
        if (!root.isSecureContext||location.protocol!=='https:'||!root.crypto.subtle) throw new Error('Для приватного сохранения откройте WebUI роутера по HTTPS.');
        await busy(async function () {
            var id=root.TTMTransfer.id(root.crypto), envelope={version:1,revision:editRevision,kind:kind,data:data};
            try {
            var count=root.TTMTransfer.count(envelope); await wire('start_ttm_begin_'+id+'_'+count);
            var state=await poll('transfer',function (s) { return s.id===id&&s.state==='receiving'; },30000);
            var parts=await root.TTMTransfer.encrypt(envelope,id,state.public_key,root.crypto);
            for (var i=0;i<parts.length;i++) {
                message('Передача конфигурации: '+Math.round(i/parts.length*100)+'%.',false);
                await wire(root.TTMTransfer.event(id,i,parts[i]));
                await poll('transfer',function (s) { return s.id===id && s.next===i+1; },20000);
            }
            unresolvedOperation=id; await wire('start_ttm_commit_'+id); await waitOperation(id);
            delete dirty[kind]; editRevision=(latest.operations.find(function (op) { return op.id===id; })||{}).revision||latest.revision; updateDirty();
            if (kind==='endpoint') root.ttmClearConnection();
            } catch(e) { try { await wire('start_ttm_abort_'+id); } catch (_) { /* Preserve the original error. */ } throw e; }
        });
    }
    root.ttmSaveExclusions=async function () { try {
        if (dirty.endpoint) throw new Error('Сначала сохраните или очистите изменения подключения.');
        if (!(latest && latest.endpoint && latest.endpoint.configured)) throw new Error('Сначала сохраните подключение.');
        await save('exclusions',{exclusions:root.TTMConnection.exclusionsFromFields([el('ttm-exclusion-domains').value,el('ttm-exclusion-networks').value].join('\n'))});
    } catch(e) { message(e.message,true); } };
    root.ttmSetup=function () { root.ttmView(latest && latest.endpoint && latest.endpoint.configured?'networks':'connection'); };
    root.ttmSaveSettings=async function () { try {
        if (dirty.endpoint) throw new Error('Сначала сохраните или очистите новое подключение.');
        if (!(latest && latest.endpoint && latest.endpoint.configured)) throw new Error('Сначала сохраните подключение.');
        var mtu=Number(el('ttm-setting-mtu').value);
        if (!Number.isInteger(mtu) || mtu<1280 || mtu>1500) throw new Error('MTU должен быть целым числом от 1280 до 1500.');
        await save('endpoint_settings',{protocol:el('ttm-setting-protocol').value,anti_dpi:el('ttm-setting-anti-dpi').checked,mtu:mtu});
    } catch(e) { message(e.message,true); } };
    root.ttmSaveEndpoint=async function () { try { await save('endpoint',readEndpoint()); } catch(e) { message(e.message,true); } };
    root.ttmToggle = function () {
        if (!latest || el('ttm-toggle').disabled) return;
        return root.ttmAction(connectionAction(latest));
    };
    root.ttmAction = async function (action) { try {
        if (action==='disable' && !root.confirm('Отключить VPN? Трафик выбранных сетей пойдёт через провайдера без VPN.')) return;
        if (action==='rollback_client' && !root.confirm('Вернуть предыдущую проверенную версию CLI? VPN будет перезапущен; блокировка обхода сохранится.')) return;
        if (action==='confirm_client' && !root.confirm('Подтвердить новую версию CLI? Проверьте сайты и внешний IP с устройства выбранной сети.')) return;
        if (action==='policy') { await save('policy',policy()); return; }
        if (['start','pause','restart','disable','diagnostics','check_updates','channel_stable','channel_nightly','confirm_client','rollback_client'].indexOf(action)<0) throw new Error('Неизвестное действие');
        if (root.TTM_PREVIEW) { message('Демонстрация: команда не отправлена на роутер.',false); return; }
        activeAction=action;
        await busy(async function () { var id=root.TTMTransfer.id(root.crypto); unresolvedOperation=id; await wire('start_ttm_do_'+id+'_'+action); await waitOperation(id); });
    } catch(e) { message(e.message,true); } finally { activeAction=null; controls(true); } };
    root.ttmCheckOperation=async function () {
        if (!unresolvedOperation || pending) return;
        pending=true; controls(false);
        try { await waitOperation(unresolvedOperation); }
        catch(e) { message(e.message,true); }
        finally { pending=false; controls(true); }
    };
    root.ttmUpdateClient=async function () { try {
        var update=(latest.client_updates||{}).check;
        if (!update || ['available','older'].indexOf(update.state)<0 || !update.candidate) throw new Error('Сначала проверьте обновления.');
        if (!root.confirm((update.state==='older'?'Перейти с '+update.installed_version+' на более старую сборку ':'Установить ')+update.candidate.tag+'? Работающий VPN будет перезапущен. При ошибке запуска будет выполнен откат. Для работающего VPN подтвердите новую версию в течение 5 минут после проверки сайтов, иначе вернётся предыдущая.')) return;
        if (root.TTM_PREVIEW) { message('Демонстрация: обновление не устанавливается.',false); return; }
        await busy(async function () { var id=root.TTMTransfer.id(root.crypto); unresolvedOperation=id; await wire('start_ttm_do_'+id+'_'+(update.state==='older'?'downgrade_client_':'update_client_')+update.id); await waitOperation(id); });
    } catch(e) { message(e.message,true); } };
    root.ttmTransaction=async function (action) { try {
        if (['confirm','rollback'].indexOf(action)<0||!latest.transaction) return;
        if (root.TTM_PREVIEW) { message('Демонстрация: подтверждение не отправлено.',false); return; }
        await busy(async function () { await wire('start_ttm_'+action+'_'+latest.transaction.id);
            await poll('status',function (s) { return !s.transaction; },90000); message('Транзакция завершена.',false);
        });
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
        result.exclusions=[el('ttm-exclusion-domains').value,el('ttm-exclusion-networks').value].filter(Boolean).join('\n');
        return root.TTMConnection.endpointFromFields(result);
    }
    function fillExclusions(values) {
        var exclusions=root.TTMConnection.splitExclusions(values);
        el('ttm-exclusion-domains').value=exclusions.domains.join('\n'); el('ttm-exclusion-networks').value=exclusions.networks.join('\n'); renderExclusionList();
    }
    function exclusionValues() { return root.TTMConnection.exclusionsFromFields([el('ttm-exclusion-domains').value,el('ttm-exclusion-networks').value].join('\n')); }
    function renderExclusionList() {
        var box=el('ttm-exclusion-list'); box.textContent='';
        try { exclusionValues().forEach(function (rule) {
            var row=document.createElement('div'), label=document.createElement('span'), remove=document.createElement('button'); row.className='ttm-exclusion-item';
            label.textContent=rule; remove.type='button'; remove.textContent='Удалить'; remove.setAttribute('aria-label','Удалить исключение '+rule);
            remove.addEventListener('click',function () { try { fillExclusions(exclusionValues().filter(function (item) { return item!==rule; })); markDirty('exclusions'); } catch(e) { message(e.message,true); } });
            row.appendChild(label); row.appendChild(remove); box.appendChild(row);
        }); } catch (_) { box.textContent='Исправьте формат в списках ниже, чтобы управлять отдельными правилами.'; }
    }
    root.ttmAddExclusion=function () { try {
        var value=el('ttm-new-exclusion').value.trim();
        if (/^https?:\/\//i.test(value)) {
            var url=new URL(value);
            if (url.username || url.password) throw new Error('URL с учётными данными не принимается. Введите только домен.');
            value=url.hostname;
            if (!root.confirm('Добавить исключение для всего домена '+value+' и его поддоменов? Путь, порт и параметры ссылки не ограничивают это правило. Трафик пойдёт без VPN.')) return;
        }
        var next=exclusionValues().concat([value]);
        fillExclusions(root.TTMConnection.exclusionsFromFields(next)); markDirty('exclusions'); el('ttm-new-exclusion').value='';
    } catch(e) { message(e.message,true); } };
    function fillEndpoint(endpoint) { Object.keys(fields).forEach(function (key) { var field=el('ttm-'+fields[key]), value=endpoint[key];
        if (key==='anti_dpi') field.checked=value; else field.value=Array.isArray(value)?value.join('\n'):value;
    });
        importedDns=endpoint.dns_upstreams.slice();
        el('ttm-upstreams').value=importedDns.join('\n'); el('ttm-upstreams').readOnly=true;
        fillExclusions(endpoint.exclusions||[]);
        text('ttm-dns-hint',importedDns.length?'DNS из конфигурации tt://. Значение сохраняется без изменений.':'В конфигурации tt:// DNS не задан. Для запуска нужна конфигурация с DNS.');
    }
    root.ttmParseLink = function () { try {
        var result=root.TTMConnection.parseLink(el('ttm-link').value.trim()); fillEndpoint(result.endpoint); el('ttm-link').value='';
        markDirty('endpoint'); root.ttmConnectionMode('manual'); message('Ссылка разобрана.'+(result.name?' Профиль: '+result.name+'.':'')+' Проверьте параметры перед сохранением.'+(result.warnings.length?' '+result.warnings.join(' '):''),false,'ttm-connection-message');
    } catch(e) { message(e.message,true,'ttm-connection-message'); } };
    root.ttmExportEndpoint = function () { try { var endpoint=readEndpoint(); download(endpoint,'trusttunnel-endpoint.json');
        message('Конфигурация проверена и скачана. Примените её по SSH по инструкции ниже. На роутере пока ничего не изменено.',false,'ttm-connection-message');
    } catch(e) { message(e.message,true,'ttm-connection-message'); } };
    root.ttmShowPassword = function (show) { el('ttm-password').type=show?'text':'password'; };
    root.ttmClearConnection = function () { el('ttm-endpoint-form').reset(); importedDns=null; el('ttm-upstreams').readOnly=false; text('ttm-dns-hint','DNS задаётся только в конфигурации подключения. Для ручного подключения укажите его здесь.'); el('ttm-link').value=''; root.ttmShowPassword(false); delete dirty.endpoint; delete dirty.exclusions; fillExclusions((latest && latest.endpoint||{}).exclusions||[]); updateDirty(); controls(true); message('Данные подключения очищены из формы.',false,'ttm-connection-message'); };
    root.ttmImportFile=async function (input) { try {
        var file=input.files[0]; if (!file) return; if (file.size>65536) throw new Error('Файл превышает 64 КиБ.');
        var source=await file.text(), endpoint=source.trim().startsWith('tt://')?root.TTMConnection.parseLink(source.trim()).endpoint:root.TTMConnection.endpointFromFields(JSON.parse(source));
        fillEndpoint(endpoint); markDirty('endpoint'); root.ttmConnectionMode('manual'); message('Файл загружен в форму. Проверьте данные перед сохранением.',false,'ttm-connection-message');
    } catch(e) { message('Не удалось импортировать конфигурацию. '+(e instanceof SyntaxError?'Некорректный JSON.':e.message),true,'ttm-connection-message'); } finally { input.value=''; } };
    root.ttmDownloadDiagnostics=function () { download(publicDiagnostics(latest),'trusttunnel-diagnostics.json'); };
    root.done_validating = function () { refresh(); };
    root.ttmInitial = function () {
        if (typeof root.show_menu==='function') root.show_menu();
        var tabs=Array.from(document.querySelectorAll('[data-view-button]'));
        tabs.forEach(function (button,index) {
            var name=button.dataset.viewButton, panel=document.querySelector('[data-view="'+name+'"]');
            button.id='ttm-nav-'+name; panel.id='ttm-view-'+name; button.setAttribute('aria-controls',panel.id);
            panel.setAttribute('role','tabpanel'); panel.setAttribute('aria-labelledby',button.id);
            button.addEventListener('keydown',function (event) {
                var next=event.key==='ArrowRight'?(index+1)%tabs.length:event.key==='ArrowLeft'?(index+tabs.length-1)%tabs.length:event.key==='Home'?0:event.key==='End'?tabs.length-1:null;
                if (next!==null) { event.preventDefault(); root.ttmView(tabs[next].dataset.viewButton); tabs[next].focus(); }
            });
        });
        ['ttm-endpoint-form','ttm-link-panel','ttm-policy-fields','ttm-settings-form','ttm-exclusions'].forEach(function (id) {
            el(id).addEventListener('input',function (event) {
                if (event.target.id==='ttm-new-exclusion' || event.target.id==='ttm-show-password' || event.target.classList.contains('ttm-network-mode')) return;
                if (/^ttm-exclusion-/.test(event.target.id)) renderExclusionList();
                markDirty(id==='ttm-settings-form'?'endpoint_settings':id==='ttm-policy-fields'?'policy':/^ttm-exclusion-/.test(event.target.id)?'exclusions':'endpoint');
            });
        });
        root.addEventListener('beforeunload',function (event) { if (pending||unresolvedOperation||Object.keys(dirty).length) { event.preventDefault(); event.returnValue=''; } });
        root.ttmView('overview'); updateDirty();
        refresh(); if (!root.TTM_PREVIEW) root.setInterval(refresh,5000);
    };
    root.TTM=api;
}(typeof window!=='undefined'?window:globalThis));
