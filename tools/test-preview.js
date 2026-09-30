#!/usr/bin/env node
'use strict';
/* Offline browser integration tests. Host tools only; no router connection.
 * Requires Playwright JS + Chromium. Set NODE_PATH/PLAYWRIGHT_BROWSERS_PATH
 * when using an existing runtime bundle instead of local npm dependencies.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {createHash} = require('node:crypto');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '..');
const preview = path.join(root, 'preview', 'index.html');
// Independently assembled wire fixture from test_connection.js: h, 1.2.3.4:443, u, p.
// All credentials in this file are synthetic test data.
const linkFixture = 'tt://?' + Buffer.from('010168020b312e322e332e343a343433050175060170', 'hex').toString('base64url');
const importedDns = ['https://dns.example/dns-query', 'tls://9.9.9.9'];
const encodedDns = Buffer.concat(importedDns.map(value => Buffer.concat([Buffer.from([Buffer.byteLength(value)]), Buffer.from(value)])));
const dnsLinkFixture = 'tt://?' + Buffer.concat([Buffer.from(linkFixture.slice(6), 'base64url'), Buffer.from([13, encodedDns.length]), encodedDns]).toString('base64url');
const manual = {hostname: 'vpn.example.com', addresses: '203.0.113.10:443', username: 'browser-test-user', password: 'browser-test-«пароль»-$()<>😀'};
const sources = {br0: '192.168.10.0/24', br1: '192.168.50.0/24', br2: '192.168.60.0/24', br3: '192.168.70.0/24'};
const ssids = {br0: 'Home', br1: 'Guest 1', br2: 'Guest 2', br3: 'Guest 3'};
function previewWithStatus(change) {
    return fs.readFileSync(preview, 'utf8').replace(/window\.TTM_PREVIEW=(.*?);<\/script>/s, (_, data) => {
        const status = JSON.parse(data);
        change(status);
        status.discovered_networks.forEach(network => { network.identity ||= createHash('sha256').update(network.lan_if).digest('hex'); });
        return 'window.TTM_PREVIEW=' + JSON.stringify(status).replace(/</g, '\\u003c') + ';</script>';
    });
}

async function exercise(browser, viewport, screenshot) {
    const context = await browser.newContext({viewport, deviceScaleFactor: 1, locale: 'ru-RU', acceptDownloads: true, offline: true});
    const page = await context.newPage();
    const errors = [], httpRequests = [], downloads = [];
    let validations = 0;
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ttm-browser-'));
    page.on('pageerror', error => errors.push(String(error)));
    page.on('console', entry => { if (entry.type() === 'error') errors.push(entry.text()); });
    page.on('request', request => { if (/^https?:/i.test(request.url())) httpRequests.push(request.url()); });
    page.on('download', download => downloads.push(download));
    await context.route('**/*', route => route.abort());
    async function downloadJson(button, kind, expectedName) {
        const [download] = await Promise.all([page.waitForEvent('download'), button.click()]);
        assert.equal(download.suggestedFilename(), expectedName);
        const target = path.join(temporary, kind + '-' + validations + '.json');
        await download.saveAs(target);
        fs.chmodSync(target, 0o600);
        const json = JSON.parse(fs.readFileSync(target, 'utf8'));
        const result = spawnSync(path.join(root, 'addon', 'trusttunnel.sh'), ['validate', kind, target], {
            encoding: 'utf8', env: {...process.env, TT_ROOT: path.join(temporary, 'sandbox')}
        });
        assert.equal(result.error, undefined, 'backend validation process must start');
        assert.equal(result.status, 0, 'downloaded ' + kind + ' must pass offline backend validation: ' + result.stderr);
        validations++;
        return json;
    }
    async function expectError(button, id, pattern) {
        const count = downloads.length;
        await button.click();
        assert.match(await page.locator(id).innerText(), pattern);
        assert.equal(await page.locator(id).getAttribute('class'), 'ttm-error');
        assert.equal(downloads.length, count, 'invalid input must not download a file');
    }
    async function networkRows() {
        const result = {};
        const rows = page.locator('.ttm-network');
        for (const [bridge, ssid] of Object.entries(ssids)) {
            const item = rows.filter({has: page.getByRole('checkbox', {name: ssid, exact: true})});
            assert.equal(await item.count(), 1, 'one selectable network per SSID inventory entry');
            result[bridge] = item;
        }
        return result;
    }
    try {
        await page.setContent(previewWithStatus(status => {
            status.discovered_networks = Object.keys(ssids).map(lan_if => ({lan_if, sources: [sources[lan_if]], ssids: [ssids[lan_if]]}));
            status.clients.find(c=>c.ip==='192.168.50.20').wireless=[{lan_if:'br1',ssid:ssids.br1}];
        }), {waitUntil: 'load'});
        assert.equal(await page.locator('#ttm-state').innerText(), 'Отключён');
        assert.equal(await page.locator('.ttm-network').count(), 4);
        assert.equal(await page.locator('#ttm-dns').count(), 0, 'routing must not expose a separate DNS override');
        assert.equal(await page.locator('input.ttm-bridge, textarea.ttm-bridge, select.ttm-bridge').count(), 0, 'bridge must not be user-editable');
        assert.equal(await page.getByRole('button', {name: 'Добавить сеть', exact: true}).count(), 0);
        assert.equal(await page.locator('.ttm-remove').count(), 0);
        await page.getByRole('button', {name: 'Запустить', exact: true}).click();
        assert.match(await page.locator('#ttm-message').innerText(), /Демонстрация/);
        await page.getByRole('tab', {name:'Подключение',exact:true}).click();

        const exportEndpoint = page.getByRole('button', {name: 'Проверить и скачать конфигурацию', exact: true});
        await expectError(exportEndpoint, '#ttm-connection-message', /Некорректное поле/);
        assert.equal(await page.locator('#ttm-upstreams').inputValue(), '', 'manual connection must not inject a DNS provider');
        assert.equal(await page.locator('#ttm-upstreams').evaluate(field => field.readOnly), false);
        for (const [name, value] of Object.entries(manual)) await page.locator('#ttm-' + name).fill(value);
        await page.locator('#ttm-exclusion-domains').fill('https://example.com/private/path');
        await expectError(exportEndpoint, '#ttm-connection-message', /без протокола, пути|URL/);
        await page.locator('#ttm-exclusion-domains').fill('example.com\n*.example.net');
        await page.locator('#ttm-exclusion-networks').fill('203.0.113.0/24\n203.0.113.10:443\n*:80');
        assert.match(await page.locator('.ttm-exclusions-help').innerText(), /без протокола, пути|Полный URL/);
        assert.match(await page.locator('.ttm-exclusions-help').innerText(), /напрямую через WAN/);
        assert.equal(await page.locator('#ttm-password').getAttribute('type'), 'password');
        await page.locator('#ttm-show-password').check();
        assert.equal(await page.locator('#ttm-password').getAttribute('type'), 'text');
        await page.locator('#ttm-show-password').uncheck();
        const endpoint = await downloadJson(exportEndpoint, 'endpoint', 'trusttunnel-endpoint.json');
        assert.equal(endpoint.hostname, manual.hostname);
        assert.deepEqual(endpoint.addresses, [manual.addresses]);
        assert.equal(endpoint.username, manual.username);
        assert.equal(endpoint.password, manual.password);
        assert.deepEqual(endpoint.dns_upstreams, [], 'empty manual DNS remains empty in the exported connection');
        assert.deepEqual(endpoint.exclusions, ['example.com', '*.example.net', '203.0.113.0/24', '203.0.113.10:443', '*:80']);
        const nativeForm = await page.locator('form[name=ttm_form]').evaluate(form => Array.from(form.elements).map(field => field.value).join('\n'));
        assert.ok(!nativeForm.includes(manual.username) && !nativeForm.includes(manual.password), 'credentials must not enter the native control form');
        assert.equal(await page.locator('#ttm-password').getAttribute('name'), null);
        assert.equal(await page.locator('#ttm-username').getAttribute('name'), null);

        await page.getByRole('tab', {name: 'Ссылка tt://', exact: true}).click();
        assert.equal(await page.locator('#ttm-tab-link').getAttribute('aria-selected'), 'true');
        await page.locator('#ttm-link').fill('tt://?malformed!');
        await expectError(page.getByRole('button', {name: 'Разобрать ссылку', exact: true}), '#ttm-connection-message', /Base64/);
        assert.equal(await page.locator('#ttm-password').inputValue(), manual.password, 'invalid import must preserve an existing form');
        await page.locator('#ttm-link').fill(linkFixture);
        await page.getByRole('button', {name: 'Разобрать ссылку', exact: true}).click();
        assert.equal(await page.locator('#ttm-tab-manual').getAttribute('aria-selected'), 'true');
        assert.equal(await page.locator('#ttm-link').inputValue(), '');
        assert.equal(await page.locator('#ttm-hostname').inputValue(), 'h');
        assert.equal(await page.locator('#ttm-password').inputValue(), 'p');
        const imported = await downloadJson(exportEndpoint, 'endpoint', 'trusttunnel-endpoint.json');
        assert.equal(imported.hostname, 'h');
        assert.deepEqual(imported.addresses, ['1.2.3.4:443']);
        assert.equal(imported.username, 'u');
        assert.equal(imported.password, 'p');
        assert.equal(imported.protocol, 'http2');
        assert.deepEqual(imported.dns_upstreams, [], 'tt:// without DNS must not gain a fallback');
        assert.deepEqual(imported.exclusions, [], 'tt:// does not contain client exclusion rules');
        assert.equal(await page.locator('#ttm-exclusion-domains').inputValue(), '');
        assert.equal(await page.locator('#ttm-exclusion-networks').inputValue(), '');
        assert.equal(await page.locator('#ttm-upstreams').inputValue(), '');
        assert.equal(await page.locator('#ttm-upstreams').evaluate(field => field.readOnly), true);
        await page.getByRole('tab', {name: 'Ссылка tt://', exact: true}).click();
        await page.locator('#ttm-link').fill(dnsLinkFixture);
        await page.getByRole('button', {name: 'Разобрать ссылку', exact: true}).click();
        assert.equal(await page.locator('#ttm-upstreams').inputValue(), importedDns.join('\n'), 'DNS must display exactly the imported profile values');
        assert.equal(await page.locator('#ttm-upstreams').evaluate(field => field.readOnly), true);
        const withDns = await downloadJson(exportEndpoint, 'endpoint', 'trusttunnel-endpoint.json');
        assert.deepEqual(withDns.dns_upstreams, importedDns);
        await page.locator('#ttm-upstreams').evaluate(field => { field.value = 'tls://1.1.1.1'; });
        const immutableDns = await downloadJson(exportEndpoint, 'endpoint', 'trusttunnel-endpoint.json');
        assert.deepEqual(immutableDns.dns_upstreams, importedDns, 'imported DNS comes from the configuration even if its display is modified');
        await page.getByRole('button', {name: 'Очистить данные', exact: true}).click();
        assert.equal(await page.locator('#ttm-password').inputValue(), '');
        assert.equal(await page.locator('#ttm-username').inputValue(), '');
        assert.equal(await page.locator('#ttm-link').inputValue(), '');
        assert.equal(await page.locator('#ttm-password').getAttribute('type'), 'password');
        assert.equal(await page.locator('#ttm-upstreams').inputValue(), '');
        assert.equal(await page.locator('#ttm-upstreams').evaluate(field => field.readOnly), false);

        await page.getByRole('tab', {name:'Сети',exact:true}).click();
        await page.locator('#ttm-export-policy').evaluate(e=>e.closest('details').open=true);
        const rows = await networkRows();
        assert.deepEqual(Object.keys(rows).sort(), Object.keys(sources).sort());
        for (const bridge of Object.keys(sources)) await rows[bridge].locator('.ttm-cidrs').fill(sources[bridge]);
        await page.getByRole('button', {name: 'Выбрать все', exact: true}).click();
        assert.equal(await page.locator('.ttm-selected:checked').count(), 4);
        assert.match(await page.locator('#ttm-network-count').innerText(), /^4 /);
        const exportPolicy = page.getByRole('button', {name: 'Скачать политику для SSH', exact: true});
        await page.getByRole('tab', {name:'Сети',exact:true}).click();
        await page.locator('#ttm-export-policy').evaluate(e=>e.closest('details').open=true);
        const savePolicy = page.getByRole('button', {name: 'Сохранить маршрутизацию', exact: true});
        await page.locator('#ttm-v6ack').uncheck();
        await expectError(savePolicy, '#ttm-message', /Подтвердите/);
        await page.locator('#ttm-v6ack').check();
        const all = await downloadJson(exportPolicy, 'policy', 'trusttunnel-policy.json');
        assert.equal(all.schema, 4);
        assert.equal(Object.hasOwn(all, 'dns_ipv4'), false);
        assert.deepEqual(all.networks.map(network => network.lan_if).sort(), ['br0', 'br1', 'br2', 'br3']);
        await savePolicy.click();
        assert.match(await page.locator('#ttm-message').innerText(), /Демонстрация/);

        await rows.br1.locator('.ttm-device').selectOption('192.168.50.20/32');
        assert.equal(await rows.br1.locator('.ttm-cidrs').inputValue(),'192.168.50.20/32','device selection replaces the broad subnet');
        await page.getByText('Дополнительно: доступ к NAS и другим локальным сетям',{exact:true}).click();
        const localHome=page.locator('#ttm-local-access input').first();
        await localHome.check();
        const devices=await downloadJson(exportPolicy,'policy','trusttunnel-policy.json');
        assert.deepEqual(devices.networks.find(n=>n.lan_if==='br1').sources,['192.168.50.20/32']);
        assert.equal(devices.local_access[0].lan_if,'br0');
        assert.equal(devices.local_access[0].destination,sources.br0);
        assert.match(devices.local_access[0].identity,/^[0-9a-f]{64}$/);
        await localHome.uncheck();
        await page.getByText('Дополнительно: доступ к NAS и другим локальным сетям',{exact:true}).click();

        await page.getByRole('button', {name: 'Снять выбор', exact: true}).click();
        await expectError(exportPolicy, '#ttm-message', /Выберите/);
        await rows.br0.locator('.ttm-selected').check();
        await rows.br2.locator('.ttm-selected').check();
        await rows.br1.locator('.ttm-cidrs').fill('ignored while unchecked');
        await rows.br3.locator('.ttm-cidrs').fill('');
        const subset = await downloadJson(exportPolicy, 'policy', 'trusttunnel-policy.json');
        assert.deepEqual(subset.networks.map(network => network.lan_if).sort(), ['br0', 'br2']);
        await rows.br2.locator('.ttm-cidrs').fill('192.168.60.1/24');
        await expectError(exportPolicy, '#ttm-message', /корректные частные/);
        await rows.br2.locator('.ttm-cidrs').fill(sources.br2);

        await page.evaluate(() => { Object.assign(window.TTM_PREVIEW, {enabled: true, process_running: true, interface_up: true, state: 'tun_ready_unverified'}); window.done_validating(); });
        assert.equal(await page.locator('#ttm-state').innerText(), 'Клиент запущен', 'process presence must not be presented as a verified VPN');
        assert.equal(await savePolicy.isEnabled(), true, 'active edits use the transactional save path');
        await page.evaluate(() => { window.TTM_PREVIEW.transaction={id:'0123456789abcdef',phase:'trial',deadline:Math.floor(Date.now()/1000)+180}; window.done_validating(); });
        assert.equal(await savePolicy.isDisabled(), true, 'a pending transaction prevents another edit');
        assert.equal(await exportPolicy.isDisabled(), true);
        assert.match(await page.locator('#ttm-transaction-state').innerText(), /Подтвердите/);
        await page.evaluate(() => { window.TTM_PREVIEW.transaction=null; });
        await page.evaluate(() => { Object.assign(window.TTM_PREVIEW, {enabled: false, process_running: false, interface_up: false, state: 'disabled'}); window.done_validating(); });
        assert.equal(await savePolicy.isEnabled(), true);
        for (const bridge of Object.keys(sources)) await rows[bridge].locator('.ttm-cidrs').fill(sources[bridge]);
        await page.getByRole('button', {name: 'Выбрать все', exact: true}).click();
        await page.getByRole('tab', {name:'Подключение',exact:true}).click();
        await page.getByRole('tab', {name: 'Ссылка tt://', exact: true}).click();
        await page.locator('#ttm-link').fill(dnsLinkFixture);
        await page.getByRole('button', {name: 'Разобрать ссылку', exact: true}).click();
        for (const [name, value] of Object.entries(manual)) await page.locator('#ttm-' + name).fill(value);
        await page.locator('#ttm-upstreams').evaluate(field => { field.closest('details').open = true; });
        await page.evaluate(() => { document.getElementById('ttm-message').textContent = 'OFFLINE PREVIEW — команды не отправляются на роутер.'; document.getElementById('ttm-message').className = 'ttm-note'; document.getElementById('ttm-connection-message').textContent = ''; });
        const overflow = await page.evaluate(() => ({width: document.documentElement.scrollWidth, viewport: window.innerWidth}));
        assert.ok(overflow.width <= overflow.viewport + 1, 'page must fit viewport without horizontal scrolling: ' + JSON.stringify(overflow));
        await page.evaluate(() => { if (document.activeElement) document.activeElement.blur(); });
        await page.screenshot({path: path.join(root, 'preview', screenshot), fullPage: true});
        await page.getByRole('tab', {name:'Сети',exact:true}).click();
        await page.locator('#ttm-export-policy').evaluate(e=>e.closest('details').open=true);
        await page.screenshot({path:path.join(root,'preview',screenshot.replace('.png','-networks.png')),fullPage:true});
        assert.deepEqual(errors, [], 'no page or console errors');
        assert.deepEqual(httpRequests, [], 'offline preview must issue no HTTP requests');
        assert.deepEqual((await context.storageState()).origins, [], 'no persisted connection data');
        console.log('PASS: ' + viewport.width + 'px; manual/tt:// DNS-preserving downloads and validated domain/network exclusions, ' + validations + ' backend validations, SSID-labelled 4-network/subset selection, device /32 and local exceptions, immutable bridges, no routing DNS, IPv6 acknowledgement, invalid-input errors, pending-transaction controls, no horizontal overflow; 0 page/console errors; 0 HTTP requests');
    } finally {
        await context.close();
        fs.rmSync(temporary, {recursive: true, force: true});
    }
}
async function exerciseOverview(browser, width) {
    const context = await browser.newContext({viewport:{width,height:1000},locale:'ru-RU',offline:true});
    const page = await context.newPage(), errors=[], requests=[];
    page.on('pageerror', error=>errors.push(String(error)));
    page.on('request', request=>{if (/^https?:/i.test(request.url())) requests.push(request.url());});
    await context.route('**/*',route=>route.abort());
    try {
        await page.setContent(previewWithStatus(status=>{
            Object.assign(status,{enabled:true,process_running:true,interface_up:true,state:'tun_ready_unverified',tunnel_addresses:['172.16.219.2/32']});
            status.traffic_check={state:'traffic_observed',rules_checked:true,leak_test_verified:false};
            status.client_updates.check={id:'0123456789abcdef',channel:'stable',checked_at:Math.floor(Date.now()/1000),state:'available',candidate:{tag:'v1.1.7',channel:'stable'}};
            status.discovered_networks=[{lan_if:'br0',sources:['192.168.10.0/24'],ssids:['Home','Legacy'],wireless:[{ssid:'Home',nvif:'wl0',ifname:'eth6'},{ssid:'Legacy',nvif:'wl0.2',ifname:'wl0.2'}]}];
            status.clients=[{ip:'192.168.10.10',name:'Home fixture',wireless:[{lan_if:'br0',ssid:'Home'}]},{ip:'192.168.10.20',name:'Legacy fixture',wireless:[{lan_if:'br0',ssid:'Legacy'}]},{ip:'192.168.10.30',name:'Unknown fixture'}];
            status.policy=null;
        }),{waitUntil:'load'});
        assert.equal(await page.locator('#ttm-tun-address').innerText(),'172.16.219.2/32');
        assert.match(await page.locator('#ttm-traffic-check').innerText(),/в обе стороны/);
        assert.match(await page.locator('#ttm-guard').innerText(),/тест обрыва ещё не выполнен/);
        assert.equal(await page.getByText('Ревизия настроек',{exact:true}).count(),0);
        assert.match(await page.locator('#ttm-client-installed-at').innerText(),/2026/);
        assert.match(await page.locator('#ttm-client-checked-at').innerText(),/2026/);
        assert.equal(await page.locator('#ttm-update-client').isEnabled(),true);
        await page.getByRole('button',{name:'Проверить обновления',exact:true}).click();
        assert.match(await page.locator('#ttm-message').innerText(),/Демонстрация/);
        await page.evaluate(()=>{ window.TTM_PREVIEW.client_updates.dependencies_ready=false; window.done_validating(); });
        assert.equal(await page.locator('#ttm-update-client').isDisabled(),true);
        assert.match(await page.locator('#ttm-update-requirements').innerText(),/GnuPG/);
        await page.evaluate(()=>{ const u=window.TTM_PREVIEW.client_updates; u.dependencies_ready=true; u.channel='nightly'; u.check={channel:'nightly',state:'not_published'}; window.done_validating(); });
        assert.equal(await page.locator('#ttm-nightly').isChecked(),true);
        assert.match(await page.locator('#ttm-client-update').innerText(),/nightly.*не опубликована/);
        assert.equal(await page.locator('#ttm-update-client').isDisabled(),true);
        await page.evaluate(()=>{ const u=window.TTM_PREVIEW.client_updates; u.check={id:'0123456789abcdef',channel:'nightly',state:'available',candidate:{tag:'v1.1.8-nightly.1',channel:'nightly'}}; u.recovery_pending=true; window.done_validating(); });
        assert.equal(await page.locator('#ttm-update-client').isDisabled(),true);
        await page.evaluate(()=>{ window.TTM_PREVIEW.client_updates.recovery_pending=false; window.TTM_PREVIEW.transaction={id:'0123456789abcdef',phase:'trial',deadline:Math.floor(Date.now()/1000)+180}; window.done_validating(); });
        assert.equal(await page.locator('#ttm-update-client').isDisabled(),true);
        await page.evaluate(()=>{
            window.TTM_PREVIEW.transaction=null;
            const u=window.TTM_PREVIEW.client_updates; u.channel='stable';
            u.check={id:'0123456789abcdef',channel:'stable',checked_at:Math.floor(Date.now()/1000),state:'available',candidate:{tag:'v1.1.7',channel:'stable'}};
            window.done_validating();
        });
        await page.screenshot({path:path.join(root,'preview',width===390?'screenshot-mobile-overview.png':'screenshot-overview.png'),fullPage:true});
        await page.getByRole('tab',{name:'Сети',exact:true}).click();
        await page.getByText('Дополнительно: интерфейсы и подсети Wi-Fi',{exact:true}).click();
        assert.equal(await page.locator('#ttm-wifi-inventory .ttm-wifi-row').count(),2);
        assert.match(await page.locator('#ttm-wifi-inventory').innerText(),/Home.*eth6/s);
        assert.match(await page.locator('#ttm-wifi-inventory').innerText(),/Legacy.*wl0.2/s);
        assert.equal(await page.getByRole('checkbox',{name:'Общая подсеть · 192.168.10.0/24',exact:true}).count(),1);
        assert.equal(await page.getByRole('checkbox',{name:'Home',exact:true}).count(),0,'shared SSIDs cannot pretend to be independent subnets');
        assert.deepEqual(await page.locator('.ttm-ssid-row strong').allTextContents(),['Home','Legacy']);
        const home=page.getByRole('combobox',{name:'Добавить устройство из Home',exact:true});
        const legacy=page.getByRole('combobox',{name:'Добавить устройство из Legacy',exact:true});
        assert.deepEqual(await home.locator('option').allTextContents(),['Добавить устройство…','Home fixture · 192.168.10.10']);
        assert.deepEqual(await legacy.locator('option').allTextContents(),['Добавить устройство…','Legacy fixture · 192.168.10.20']);
        await home.selectOption('192.168.10.10/32');
        await legacy.selectOption('192.168.10.20/32');
        assert.equal(await page.locator('.ttm-cidrs').inputValue(),'192.168.10.10/32\n192.168.10.20/32');
        await page.evaluate(()=>{window.TTM_PREVIEW.clients[0].wireless=[{lan_if:'br0',ssid:'Legacy'}];window.done_validating();});
        assert.equal(await home.isDisabled(),true,'roamed clients disappear from the previous SSID');
        assert.equal(await page.locator('.ttm-cidrs').inputValue(),'192.168.10.10/32\n192.168.10.20/32','refresh keeps draft IP routing');
        assert.equal(await page.locator('#ttm-export-policy').isVisible(),false,'SSH fallback stays in advanced details');
        assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+1));
        await page.screenshot({path:path.join(root,'preview',width===390?'screenshot-mobile-topology.png':'screenshot-topology.png'),fullPage:true});
        assert.deepEqual(errors,[]); assert.deepEqual(requests,[]);
        console.log('PASS: '+width+'px overview/update dates, nightly absence, dependencies/recovery/transaction guards, TUN address, passive proof scope, distinct SSID device rows, association-scoped clients and roaming with draft preserved, shared routing scope, hidden SSH fallback; no HTTP');
    } finally { await context.close(); }
}
async function exerciseMissingInitialStatus(browser) {
    const context=await browser.newContext({offline:true});
    const page=await context.newPage(), errors=[];
    page.on('pageerror',error=>errors.push(String(error)));
    try {
        const html=previewWithStatus(()=>{}).replace(';</script>',';window.TTM_PREVIEW=null;window.XMLHttpRequest=function(){this.open=function(){};this.send=function(){this.onerror();};};</script>');
        await page.setContent(html,{waitUntil:'load'});
        assert.deepEqual(errors,[],'failure before the first status must not throw in controls');
        assert.match(await page.locator('#ttm-message').innerText(),/Нет актуального статуса/);
        assert.equal(await page.locator('#ttm-update-client').isDisabled(),true);
        assert.equal(await page.locator('#ttm-nightly').isDisabled(),true);
        console.log('PASS: missing initial status disables updater without a JavaScript exception');
    } finally { await context.close(); }
}
async function exerciseInventory(browser) {
    const context = await browser.newContext({viewport: {width: 1280, height: 1000}, locale: 'ru-RU', offline: true, acceptDownloads: true});
    const page = await context.newPage();
    const errors = [], httpRequests = [];
    page.on('pageerror', error => errors.push(String(error)));
    page.on('request', request => { if (/^https?:/i.test(request.url())) httpRequests.push(request.url()); });
    await context.route('**/*', route => route.abort());
    try {
        await page.setContent(previewWithStatus(status => { status.policy = null; status.discovered_networks = []; }), {waitUntil: 'load'});
        await page.getByRole('tab', {name:'Сети',exact:true}).click();
        await page.locator('#ttm-export-policy').evaluate(e=>e.closest('details').open=true);
        assert.equal(await page.locator('.ttm-network').count(), 0, 'an empty inventory must not invent br0–br3');
        assert.equal(await page.locator('.ttm-selected').count(), 0);
        await page.getByRole('button', {name: 'Скачать политику для SSH', exact: true}).click();
        assert.match(await page.locator('#ttm-message').innerText(), /Выберите/);

        const untrustedSsid = '<script>window.ssidExecuted=true</script><img src=x onerror="window.ssidExecuted=true">';
        await page.setContent(previewWithStatus(status => {
            status.policy = null;
            status.discovered_networks = [
                {lan_if: 'br0', sources: ['192.168.10.0/24'], display_name:'Home 2.4', ssids: ['Home 2.4', 'Home 5', '0123456789ABCDEF0123456789ABCDEF']},
                {lan_if: 'br1', sources: ['192.168.50.0/24'], ssids: [untrustedSsid]}
            ];
        }), {waitUntil: 'load'});
        await page.getByRole('tab', {name:'Сети',exact:true}).click();
        await page.locator('#ttm-export-policy').evaluate(e=>e.closest('details').open=true);
        assert.equal(await page.locator('.ttm-network').count(), 2, 'several SSIDs on one bridge must remain one routing choice');
        await page.getByRole('checkbox', {name: 'Общая подсеть · 192.168.10.0/24', exact: true}).check();
        assert.deepEqual(await page.locator('.ttm-ssid-row strong').allTextContents(), ['Home 2.4','Home 5','0123456789ABCDEF0123456789ABCDEF']);
        assert.equal(await page.locator('.ttm-ssid-row strong').first().isVisible(),true);
        assert.equal(await page.getByRole('checkbox', {name: untrustedSsid, exact: true}).count(), 1, 'SSID markup must be preserved as visible text');
        assert.equal(await page.locator('.ttm-network script, .ttm-network img').count(), 0);
        assert.equal(await page.evaluate(() => window.ssidExecuted), undefined);
        await page.locator('#ttm-v6ack').check();
        // The bridge mapping must come from the discovered model, even if a DOM field is injected.
        await page.locator('.ttm-network').first().evaluate(row => {
            const field = document.createElement('input'); field.className = 'ttm-bridge'; field.value = 'br99'; row.appendChild(field);
        });
        const [download] = await Promise.all([
            page.waitForEvent('download'), page.getByRole('button', {name: 'Скачать политику для SSH', exact: true}).click()
        ]);
        const chunks = [];
        for await (const chunk of await download.createReadStream()) chunks.push(chunk);
        const policy = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        assert.equal(policy.schema,4);
        assert.match(policy.networks[0].identity,/^[0-9a-f]{64}$/);
        assert.deepEqual(policy.networks.map(({lan_if,sources})=>({lan_if,sources})), [{lan_if: 'br0', sources: ['192.168.10.0/24']}], 'immutable inventory model determines the exported bridge');
        assert.equal(Object.hasOwn(policy, 'dns_ipv4'), false);

        await page.setContent(previewWithStatus(status => {
            status.policy = null;
            status.discovered_networks = [
                {lan_if: 'br0', sources: ['192.168.10.0/24'], ssids: ['Home']},
                {lan_if: 'br1', sources: ['192.168.50.0/24'], ssids: ['Guest 1']}
            ];
        }), {waitUntil: 'load'});
        await page.getByRole('tab', {name:'Сети',exact:true}).click();
        await page.locator('#ttm-export-policy').evaluate(e=>e.closest('details').open=true);
        await page.getByRole('checkbox', {name: 'Home', exact: true}).check();
        await page.getByRole('checkbox', {name: 'Guest 1', exact: true}).check();
        const homeRow = page.locator('.ttm-network').first();
        const homeSelection = homeRow.locator('.ttm-selected');
        const guestSelection = page.getByRole('checkbox', {name: 'Guest 1', exact: true});
        await page.locator('#ttm-v6ack').check();
        await page.evaluate(() => {
            window.TTM_PREVIEW.discovered_networks = window.TTM_PREVIEW.discovered_networks.filter(network => network.lan_if !== 'br0');
            window.done_validating();
        });
        assert.match(await homeRow.locator('.ttm-caption').innerText(), /недоступна/);
        assert.equal(await homeSelection.isChecked(), true, 'a disappeared selected network must remain visible until explicitly removed');
        assert.equal(await homeSelection.isEnabled(), true, 'the user must be able to deselect one unavailable network');
        assert.equal(await homeRow.locator('.ttm-cidrs').isDisabled(), true);
        await page.getByRole('button', {name: 'Скачать политику для SSH', exact: true}).click();
        assert.match(await page.locator('#ttm-message').innerText(), /больше не обнаружена/);
        await homeSelection.uncheck();
        assert.equal(await homeSelection.isDisabled(), true, 'an unavailable network cannot be selected again');
        assert.equal(await guestSelection.isChecked(), true, 'removing one unavailable network must preserve other choices');
        await page.getByRole('button', {name: 'Выбрать все', exact: true}).click();
        assert.equal(await homeSelection.isChecked(), false, 'select all must skip unavailable networks');
        assert.equal(await guestSelection.isChecked(), true);
        const [remainingDownload] = await Promise.all([
            page.waitForEvent('download'), page.getByRole('button', {name: 'Скачать политику для SSH', exact: true}).click()
        ]);
        const remainingChunks = [];
        for await (const chunk of await remainingDownload.createReadStream()) remainingChunks.push(chunk);
        const remainingPolicy = JSON.parse(Buffer.concat(remainingChunks).toString('utf8'));
        assert.deepEqual(remainingPolicy.networks.map(({lan_if,sources})=>({lan_if,sources})), [{lan_if: 'br1', sources: ['192.168.50.0/24']}]);
        assert.deepEqual(errors, []);
        assert.deepEqual(httpRequests, []);
        console.log('PASS: empty inventory has no guessed networks; multiple SSIDs share one immutable bridge choice; SSID HTML is text and executes no script; unavailable network can be removed individually without resetting other selections and cannot be reselected');
    } finally { await context.close(); }
}
(async () => {
    const options = {headless: true};
    if (process.env.TTM_CHROMIUM_PATH) options.executablePath = process.env.TTM_CHROMIUM_PATH;
    const browser = await chromium.launch(options);
    try {
        console.log('Browser: Chromium ' + browser.version() + '; Playwright ' + require('playwright/package.json').version);
        await exercise(browser, {width: 1280, height: 1000}, 'screenshot.png');
        await exercise(browser, {width: 390, height: 844}, 'screenshot-mobile.png');
        await exerciseInventory(browser);
        await exerciseOverview(browser,1280);
        await exerciseOverview(browser,390);
        await exerciseMissingInitialStatus(browser);
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
