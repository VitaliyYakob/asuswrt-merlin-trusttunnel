/* No external libraries, eval, dynamic HTML or credentials in custom_settings. */
(function (root) {
    'use strict';
    var api = {}, latest = null, initialized = false;
    function policyFromFields(lan, sources, dns, acknowledge) {
        var cidrs = sources.split(/[\s,;]+/).filter(Boolean);
        if (!/^br[0-9]+(?:\.[0-9]+)?$/.test(lan) || lan.length > 15) throw new Error('Укажите LAN bridge, например br1.');
        if (!cidrs.length || cidrs.length > 32) throw new Error('Требуется от 1 до 32 IPv4-подсетей или адресов /32.');
        if (new Set(cidrs).size !== cidrs.length) throw new Error('В списке есть повторяющиеся записи.');
        if (cidrs.some(function (s) { return !/^[0-9.]+\/[0-9]{1,2}$/.test(s); })) throw new Error('Используйте формат 192.168.50.0/24 или 192.168.50.10/32.');
        if (!acknowledge) throw new Error('Подтвердите блокировку IPv6 на всём выбранном bridge.');
        return {schema: 1, lan_if: lan, sources: cidrs, dns_ipv4: dns, block_ipv6_bridge: true, table: 871, priority: 17100};
    }
    function makeEnvelope(settings, policy) {
        var clone = Object.assign({}, settings || {});
        // This object contains only ASCII policy data, never endpoint credentials.
        var encoded = root.btoa(JSON.stringify(policy));
        if (encoded.length > 2999) throw new Error('Политика превышает лимит Addons API.');
        clone.ttm_policy = encoded;
        var serialized = JSON.stringify(clone);
        if (serialized.length > 7600) throw new Error('Недостаточно места в общем хранилище аддонов. Используйте импорт политики через SSH.');
        return serialized;
    }
    api.policyFromFields = policyFromFields;
    api.makeEnvelope = makeEnvelope;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    if (!root.document) return;
    function el(id) { return document.getElementById(id); }
    function text(id, value) { el(id).textContent = String(value); }
    function message(value, error) { text('ttm-message', value); el('ttm-message').className = error ? 'ttm-error' : 'ttm-note'; }
    function render(status) {
        latest = status;
        var labels = {disabled: 'Отключён', paused_protected: 'Пауза; блокировка запрошена',
            blocked_or_start_failed: 'Нет рабочего процесса / ошибка запуска', tun_ready_unverified: 'TUN создан; соединение не проверено'};
        text('ttm-state', labels[status.state] || status.state);
        text('ttm-version', status.version);
        text('ttm-host', status.hostname || 'Учётные данные не импортированы');
        text('ttm-process', status.process_running ? 'Запущен' : 'Не запущен');
        text('ttm-tun', status.interface_up ? 'tt0' : 'Нет');
        text('ttm-counter', (status.rx_bytes / 1048576).toFixed(2) + ' / ' + (status.tx_bytes / 1048576).toFixed(2) + ' MiB');
        text('ttm-age', new Date(status.timestamp * 1000).toLocaleTimeString());
        text('ttm-last', status.last_result || 'none');
        el('ttm-save').disabled = !!status.enabled;
        el('ttm-policy-fields').disabled = !!status.enabled;
        if (!initialized && status.policy) {
            el('ttm-lan').value = status.policy.lan_if;
            el('ttm-sources').value = status.policy.sources.join('\n');
            el('ttm-dns').value = status.policy.dns_ipv4;
            el('ttm-v6ack').checked = status.policy.block_ipv6_bridge;
            initialized = true;
        }
    }
    function refresh() {
        if (root.TTM_PREVIEW) { render(root.TTM_PREVIEW); return; }
        var request = new XMLHttpRequest();
        request.open('GET', '/user/trusttunnel/status.json?t=' + Date.now(), true);
        request.timeout = 5000;
        request.onload = function () {
            try {
                if (request.status !== 200) throw new Error('Статус пока недоступен.');
                render(JSON.parse(request.responseText));
            } catch (e) { message('Не удалось прочитать статус; проверьте SSH-журнал аддона.', true); }
        };
        request.onerror = request.ontimeout = function () { message('Не удалось обновить статус.', true); };
        request.send();
    }
    function send(action, policy) {
        var allowed = ['start', 'pause', 'restart', 'disable', 'policy'];
        if (allowed.indexOf(action) < 0) throw new Error('Unknown action');
        if (root.TTM_PREVIEW) { message('Демонстрация интерфейса: команда не отправлена.', false); return; }
        var form = document.forms.ttm_form;
        var settings = root.ttmCustomSettings || {};
        form.elements.amng_custom.disabled = !policy;
        form.elements.amng_custom.value = policy ? makeEnvelope(settings, policy) : '';
        form.elements.action_script.value = 'start_ttm_' + action;
        form.elements.current_page.value = location.pathname.substring(1);
        form.elements.next_page.value = location.pathname.substring(1);
        form.submit();
        message('Команда отправлена. Проверяйте результат операции и время обновления статуса.', false);
    }
    root.ttmAction = function (action) {
        try {
            if (action === 'disable' && !root.confirm('Отключить защитные правила? Выбранные устройства вернутся к обычной маршрутизации Merlin.')) return;
            if (action === 'policy') {
                if (latest && latest.enabled) throw new Error('Перед изменением политики отключите аддон.');
                send(action, policyFromFields(el('ttm-lan').value.trim(), el('ttm-sources').value,
                    el('ttm-dns').value.trim(), el('ttm-v6ack').checked));
            } else send(action);
        } catch (e) { message(e.message, true); }
    };
    root.done_validating = function () { refresh(); };
    root.ttmInitial = function () {
        if (typeof root.show_menu === 'function') root.show_menu();
        refresh();
        if (!root.TTM_PREVIEW) root.setInterval(refresh, 5000);
    };
    root.TTM = api;
}(typeof window !== 'undefined' ? window : globalThis));
