/* Native Merlin control. Secrets leave memory only on explicit encrypted save/export. */
(function (root) {
    'use strict';
    var api = {}, latest = null, initialized = false, lastSeen = 0, rowIndex = 0, pending = false;
    var networkModels = new WeakMap(), importedDns = null, dirty = {}, editRevision = null;
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
    api.policyFromNetworks = policyFromNetworks; api.makeEnvelope = makeEnvelope; api.contains=contains; api.clientsForSsid=clientsForSsid;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    if (!root.document) return;
    function el(id) { return document.getElementById(id); }
    function updateDirty() { text('ttm-dirty',Object.keys(dirty).length?'Есть несохранённые изменения':'Нет несохранённых изменений'); }
    function markDirty(kind) { if (!Object.keys(dirty).length) editRevision=latest ? latest.revision||'0' : '0'; dirty[kind]=true; updateDirty(); controls(true); }
    root.ttmView=function (name) {
        document.querySelectorAll('[data-view]').forEach(function (section) { section.hidden=section.dataset.view!==name; });
        document.querySelectorAll('[data-view-button]').forEach(function (button) { button.setAttribute('aria-selected',String(button.dataset.viewButton===name)); button.tabIndex=button.dataset.viewButton===name?0:-1; });
    };
    root.ttmReload=function () {
        if (Object.keys(dirty).length && !root.confirm('Сбросить несохранённые изменения?')) return;
        initialized=false; dirty={}; editRevision=null; root.ttmClearConnection(); updateDirty(); refresh();
    };
    function text(id, value) { el(id).textContent = String(value); }
    function dateLabel(value, fallback) {
        if (typeof value!=='number' || !Number.isFinite(value) || value<=0) return fallback;
        var date=new Date(value*1000);
        return Number.isNaN(date.getTime()) ? fallback : date.toLocaleString('ru-RU');
    }
    var startErrors={update_check_failed:'Не удалось получить официальный список релизов. Проверьте доступ к GitHub и повторите поиск.',update_failed:'Обновление не завершилось. Обновите статус; при незавершённом восстановлении потребуется recover-client по SSH.',check_not_running:'Для проверки трафика сначала запустите клиент.',endpoint_missing:'Сначала сохраните корректное подключение.',policy_missing:'Выберите сети во вкладке «Сети» и нажмите «Сохранить маршрутизацию».',client_missing:'Не установлен проверенный клиент TrustTunnel.',forwarding_disabled:'На роутере отключена пересылка IPv4.',dns_missing:'В подключении не задан DNS.',dns_conflict:'Не удалось проверить внутренний адрес DNS.',network_changed:'Состав выбранных сетей изменился. Проверьте вкладку «Сети».',offload_unavailable:'Прошивка не предоставляет SKIPLOG или выборочное управление кешем потоков. Запуск заблокирован для защиты выбранных сетей.',offload_flush_failed:'Не удалось очистить ускоренные потоки выбранной сети. Защитные правила сохранены.',tun_unavailable:'Не удалось загрузить штатный TUN-модуль роутера.',missing_dependency:'На роутере отсутствует необходимая утилита.'};
    function operationLabel(op) {
        var actions={start:'Запуск',pause:'Пауза',restart:'Перезапуск',disable:'Отключение',endpoint:'Подключение',exclusions:'Исключения',policy:'Маршрутизация',diagnostics:'Диагностика',verify_traffic:'Проверка трафика',check_updates:'Поиск обновлений',update_client:'Обновление CLI',channel_stable:'Стабильный канал',channel_nightly:'Ночной канал'};
        var states={running:'выполняется',succeeded:'выполнено',failed:'ошибка'};
        var codes={confirmation_required:'нужно подтверждение',revision_conflict:'настройки изменены в другой вкладке',transaction_pending:'сначала завершите пробное применение',invalid_configuration:'некорректная конфигурация',apply_failed:'не удалось применить',action_failed:'не удалось выполнить'};
        return (actions[op.action]||'Операция')+' · '+(startErrors[op.code]||codes[op.code]||states[op.state]||'результат неизвестен');
    }
    function message(value, error, target) { target = target || 'ttm-message'; text(target,value); el(target).className = error ? 'ttm-error' : 'ttm-note'; }
    function controls(ok) {
        ok=ok && !!latest && (!!root.TTM_PREVIEW || Math.abs(Date.now()/1000-latest.timestamp)<150);
        document.querySelectorAll('[data-runtime]').forEach(function (button) { button.disabled = !ok || pending || !!latest.transaction; });
        document.querySelectorAll('[data-view="connection"] input,[data-view="connection"] textarea,[data-view="connection"] select,[data-view="connection"] button').forEach(function (field) { field.disabled=pending; });
        el('ttm-policy-fields').disabled = !ok || pending || !!(latest && latest.transaction);
        el('ttm-save').disabled = el('ttm-export-policy').disabled = el('ttm-policy-fields').disabled;
        el('ttm-save-endpoint').disabled = !ok || pending || !!(latest && latest.transaction);
        el('ttm-nightly').disabled=!ok || pending || !!latest.transaction;
        var updates=(latest||{}).client_updates||{}, check=updates.check;
        el('ttm-update-client').disabled=!ok || pending || !!latest.transaction || !updates.dependencies_ready || updates.recovery_pending || !check || check.state!=='available' || !check.candidate || check.channel!==updates.channel || (!root.TTM_PREVIEW && (Date.now()/1000-check.checked_at>3600 || check.checked_at>Date.now()/1000));
        el('ttm-save-exclusions').disabled = el('ttm-save-endpoint').disabled || !(latest && latest.endpoint && latest.endpoint.configured) || !!dirty.endpoint;
    }
    function networkTitle(network) {
        if (Array.isArray(network.ssids) && network.ssids.length>1) return 'Общая подсеть · '+(network.sources||[]).join(', ');
        if (typeof network.display_name==='string' && network.display_name) return network.display_name;
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
        var hint = document.createElement('small'); hint.className = 'ttm-network-hint'; info.appendChild(hint);
        row.appendChild(info);
        var box = document.createElement('div'), name = document.createElement('label'), sources = document.createElement('textarea');
        sources.id = 'ttm-network-' + index + '-sources'; sources.className = 'ttm-cidrs'; sources.spellcheck = false;
        sources.value = (network.sources || []).join('\n'); sources.placeholder = '192.168.50.0/24';
        name.htmlFor = sources.id; name.textContent = 'Подсети / адреса IPv4'; box.appendChild(name); box.appendChild(sources); row.appendChild(box);
        // The firmware association is held in memory, never read from an editable DOM field.
        networkModels.set(row,{identity:Object.freeze({lan_if:network.lan_if,token:network.identity}),available:!!available});
        var devicesBox=document.createElement('div'); devicesBox.className='ttm-ssid-rows'; row.appendChild(devicesBox);
        el('ttm-networks').appendChild(row); return row;
    }
    function addDevicePicker(box, row, clients, ssid) {
        var devices=document.createElement('select'); devices.className='ttm-device'; devices.setAttribute('aria-label',ssid?'Добавить устройство из '+ssid:'Добавить устройство по IPv4');
        devices.add(new Option(clients.length?'Добавить устройство…':'Нет подтверждённых устройств',''));
        clients.forEach(function (client) { devices.add(new Option(client.name+' · '+client.ip,client.ip+'/32')); });
        devices.disabled=!clients.length;
        devices.addEventListener('change',function () { if (!devices.value) return;
            var sources=row.querySelector('.ttm-cidrs'), checkbox=row.querySelector('.ttm-selected');
            var list=sources.value.trim().split(/[\s,;]+/).filter(function (source) { return /\/32$/.test(source); });
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
    function updateCount() { text('ttm-network-count',document.querySelectorAll('.ttm-selected:checked').length + ' сетей выбрано'); }
    function rows() { return Array.from(document.querySelectorAll('.ttm-network')).map(function (row) {
        var model = networkModels.get(row);
        return {selected:row.querySelector('.ttm-selected').checked,available:model.available,identity:model.identity.token,lan_if:model.identity.lan_if,sources:row.querySelector('.ttm-cidrs').value};
    }); }
    function policy() {
        if (rows().some(function (row) { return row.selected && !row.available; })) throw new Error('Выбранная сеть больше не обнаружена. Снимите её выбор и проверьте настройки Wi-Fi роутера.');
        var p=policyFromNetworks(rows(),el('ttm-v6ack').checked);
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
            el('ttm-local-access').textContent='';
            inventory.forEach(function (network) {
                var label=document.createElement('label'), checkbox=document.createElement('input'); label.className='ttm-check';
                checkbox.type='checkbox'; checkbox.value=network.identity||'';
                checkbox.checked=!!(status.policy && (status.policy.local_access||[]).some(function (n) { return n.identity===network.identity; }));
                label.appendChild(checkbox); label.appendChild(document.createTextNode(networkTitle(network)+' · '+network.sources.join(', ')));
                el('ttm-local-access').appendChild(label);
            });
            initialized=true;
        } else {
            inventory.forEach(function (network) {
                if (!rows().some(function (r) { return r.lan_if===network.lan_if; })) addNetwork(network,false,true);
            });
        }
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
        latest = status; lastSeen = Date.now();
        if (!Object.keys(dirty).length && !pending) editRevision=status.revision||'0';
        if (!dirty.endpoint && !dirty.exclusions && !pending) fillExclusions((status.endpoint||{}).exclusions||[]);
        text('ttm-saved-connection',status.endpoint && status.endpoint.configured ? 'Подключение сохранено на роутере. Исключения можно менять отдельно; пароль и ссылка повторно не нужны.' : 'Подключение ещё не сохранено. Заполните параметры или импортируйте ссылку.');
        var labels = {disabled:'Отключён',paused_protected:'Пауза; блокировка запрошена',blocked_or_start_failed:'Процесс остановлен / ошибка',tun_ready_unverified:'Клиент запущен'};
        text('ttm-state',labels[status.state] || 'Неизвестное состояние'); text('ttm-version',status.version);
        text('ttm-host',status.hostname || 'Подключение ещё не импортировано');
        text('ttm-process',status.process_running ? 'Запущен' : 'Не запущен'); text('ttm-tun',status.interface_up ? 'tt0' : 'Нет TUN');
        text('ttm-counter',(status.rx_bytes/1048576).toFixed(2) + ' / ' + (status.tx_bytes/1048576).toFixed(2) + ' MiB');
        text('ttm-age',new Date(status.timestamp*1000).toLocaleTimeString()); text('ttm-last',(status.operations||[]).length?operationLabel(status.operations[0]):'Нет записей');
        var fresh = !!root.TTM_PREVIEW || Math.abs(Date.now()/1000-status.timestamp) < 150;
        controls(fresh);
        if (!fresh) message('Статус устарел. Управление заблокировано до обновления контроллера.',true);
        reconcileNetworks(status);
        text('ttm-network-warnings',(status.network_warnings||[]).join('\n'));
        el('ttm-network-warnings').hidden=!(status.network_warnings||[]).length;
        renderWifiInventory(inventoryOrEmpty(status));
        text('ttm-tun-address',(status.tunnel_addresses||[]).join(', ')||'Не назначен');
        var traffic=status.traffic_check;
        var trafficLabels={traffic_observed:'Пакеты прошли через TUN в обе стороны',idle:'За 10 секунд двусторонний трафик не появился — откройте сайт и повторите',incomplete:'Не все правила или маршруты присутствуют',counters_reset:'Счётчики сброшены; повторите проверку'};
        text('ttm-traffic-check',traffic ? (trafficLabels[traffic.state]||'Результат неизвестен') : 'Ещё не выполнялась / результат устарел');
        var updates=status.client_updates||{}, check=updates.check;
        text('ttm-client-version',(updates.installed||{}).version||(check||{}).installed_version||'Нажмите «Проверить обновления»');
        text('ttm-client-installed-at',dateLabel((updates.installed||{}).installed_at,'Дата неизвестна'));
        var history=updates.last_check||check;
        text('ttm-client-checked-at',dateLabel((history||{}).checked_at,'Ещё не выполнялась')+(history&&history.channel!==updates.channel?' · '+history.channel:''));
        el('ttm-nightly').checked=updates.channel==='nightly';
        text('ttm-client-update',!check?(updates.installed?'После установки или смены канала повторите проверку':'Проверьте доступные сборки'):check.state==='not_published'?(updates.channel==='nightly'?'Официальная nightly для ARM64 не опубликована':'Подходящий официальный релиз не найден'):check.state==='current'?'Установлен актуальный релиз':check.candidate?check.candidate.tag+' · '+check.candidate.channel:'Результат неизвестен');
        text('ttm-update-requirements',updates.recovery_pending?'Незавершённое обновление: требуется восстановление предыдущего клиента.':updates.dependencies_ready?'':'Для установки нужны curl, GnuPG, tar, timeout и od из Entware. Поиск обновлений требует curl.');
        text('ttm-ipv6-help','Аддон направляет через VPN только IPv4. Блокировка IPv6 действует на весь выбранный bridge, даже при выборе устройств /32.'+((status.diagnostics||{}).ipv6_service==='disabled'?' Сейчас IPv6 отключён в Merlin; правило защищает и после его включения.':''));
        text('ttm-guard',({disabled:'Отключена',unverified:'Проверка недоступна',installed_unverified:'Блокировка настроена; тест обрыва ещё не выполнен',incomplete:'Часть защитных правил отсутствует'})[(status.diagnostics||{}).guard]||'Нет данных');
        if (traffic && traffic.rules_checked) text('ttm-guard','Правила и маршрут проверены; тест обрыва ещё не выполнен');
        var startup=(status.diagnostics||{}).startup;
        text('ttm-startup',startup ? (startup.blockers||[]).map(function (code) { return startErrors[code]||code; }).concat((startup.notes||[]).includes('tun_load_on_start')?['TUN будет загружен автоматически при запуске.']:[]).join(' ') : '');
        el('ttm-startup').hidden=!el('ttm-startup').textContent;
        text('ttm-diagnostics',JSON.stringify(status.diagnostics||{hardware_tested:false},null,2));
        el('ttm-transaction').hidden=!status.transaction;
        if (status.transaction) text('ttm-transaction-state',status.transaction.phase==='trial' ?
            'Проверьте Интернет и DNS на выбранных устройствах. Подтвердите в течение '+Math.max(0,status.transaction.deadline-Math.floor(Date.now()/1000))+' с. Без подтверждения будет запрошен откат.' :
            'Восстановление настроек. Блокировки сохранены; при ошибке используйте «Откатить».');
        el('ttm-confirm').disabled=pending||!status.transaction||status.transaction.phase!=='trial';
        text('ttm-operation-list',(status.operations||[]).slice(0,8).map(operationLabel).join('\n')||'Операций пока нет');
    }

    function refresh() {
        if (root.TTM_PREVIEW) { render(root.TTM_PREVIEW); return; }
        var request = new XMLHttpRequest(); request.open('GET','/user/trusttunnel/status.json?t='+Date.now(),true); request.timeout=5000;
        request.onload = function () { try { if (request.status !== 200) throw new Error('Unavailable'); render(JSON.parse(request.responseText)); }
            catch (_) { controls(false); message('Не удалось прочитать статус. Проверьте контроллер по SSH.',true); } };
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
            if (!response.ok) throw new Error('Merlin отклонил запрос. Проверьте сессию WebUI.');
            await response.text();
        } finally { root.clearTimeout(timer); }
    }
    function delay(ms) { return new Promise(function (resolve) { root.setTimeout(resolve,ms); }); }
    async function poll(file,check,timeout) {
        var deadline=Date.now()+timeout;
        while (Date.now()<deadline) {
            await delay(1000);
            var controller=new AbortController(), timer=root.setTimeout(function () { controller.abort(); },5000);
            try { var response=await root.fetch('/user/trusttunnel/'+file+'.json?t='+Date.now(),{cache:'no-store',credentials:'same-origin',signal:controller.signal});
                if (response.ok) { var value=await response.json(); if (file==='status') render(value); if (check(value)) return value; }
            } catch (_) { /* A timeout never means successful completion. */ }
            finally { root.clearTimeout(timer); }
        }
        throw new Error('Подтверждение не получено. Результат неизвестен: обновите статус перед повторной операцией.');
    }
    async function waitOperation(id) {
        var status=await poll('status',function (s) { return (s.operations||[]).some(function (op) { return op.id===id && op.state!=='running'; }); },360000);
        var op=status.operations.find(function (item) { return item.id===id; });
        if (op.state!=='succeeded') throw new Error(op.code==='revision_conflict'?'Настройки изменены в другой вкладке. Обновите данные перед сохранением.':startErrors[op.code]||'Операция завершилась ошибкой: '+op.code);
        message(op.code==='confirmation_required'?'Настройки применены временно. Проверьте доступ и подтвердите применение.':'Операция выполнена.',false); return op;
    }
    async function busy(task) {
        if (!latest||Date.now()-lastSeen>15000||pending) throw new Error('Дождитесь актуального статуса и завершения предыдущей операции.');
        pending=true; controls(false);
        try { return await task(); } finally { pending=false; controls(true); refresh(); }
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
            await wire('start_ttm_commit_'+id); await waitOperation(id);
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
    root.ttmSaveEndpoint=async function () { try { await save('endpoint',readEndpoint()); } catch(e) { message(e.message,true); } };
    root.ttmAction = async function (action) { try {
        if (action==='disable' && !root.confirm('Вернуть выбранные сети к обычной маршрутизации Merlin?')) return;
        if (action==='policy') { await save('policy',policy()); return; }
        if (['start','pause','restart','disable','diagnostics','check_updates','channel_stable','channel_nightly','verify_traffic'].indexOf(action)<0) throw new Error('Неизвестное действие');
        if (root.TTM_PREVIEW) { message('Демонстрация: команда не отправлена на роутер.',false); return; }
        await busy(async function () { var id=root.TTMTransfer.id(root.crypto); await wire('start_ttm_do_'+id+'_'+action); await waitOperation(id); });
    } catch(e) { message(e.message,true); } };
    root.ttmUpdateClient=async function () { try {
        var update=(latest.client_updates||{}).check;
        if (!update || update.state!=='available' || !update.candidate) throw new Error('Сначала проверьте обновления.');
        if (!root.confirm('Установить '+update.candidate.tag+'? Работающий VPN будет перезапущен. При ошибке запуска аддон попытается вернуть предыдущий клиент; результат восстановления будет виден в статусе.')) return;
        if (root.TTM_PREVIEW) { message('Демонстрация: обновление не устанавливается.',false); return; }
        await busy(async function () { var id=root.TTMTransfer.id(root.crypto); await wire('start_ttm_do_'+id+'_update_client_'+update.id); await waitOperation(id); });
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
        el('ttm-exclusion-domains').value=exclusions.domains.join('\n'); el('ttm-exclusion-networks').value=exclusions.networks.join('\n');
    }
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
    root.ttmDownloadDiagnostics=function () { download({diagnostics:latest.diagnostics||{},operations:latest.operations||[],transaction:latest.transaction||null},'trusttunnel-diagnostics.json'); };
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
        ['ttm-endpoint-form','ttm-link-panel','ttm-policy-fields'].forEach(function (id) {
            el(id).addEventListener('input',function (event) { markDirty(id==='ttm-policy-fields'?'policy':/^ttm-exclusion-/.test(event.target.id)?'exclusions':'endpoint'); });
        });
        root.addEventListener('beforeunload',function (event) { if (pending||Object.keys(dirty).length) { event.preventDefault(); event.returnValue=''; } });
        root.ttmView('overview'); updateDirty();
        refresh(); if (!root.TTM_PREVIEW) root.setInterval(refresh,5000);
    };
    root.TTM=api;
}(typeof window!=='undefined'?window:globalThis));
