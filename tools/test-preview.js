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
        }), {waitUntil: 'load'});
        assert.equal(await page.locator('#ttm-state').innerText(), 'Отключён');
        assert.equal(await page.locator('.ttm-network').count(), 4);
        assert.equal(await page.locator('#ttm-dns').count(), 0, 'routing must not expose a separate DNS override');
        assert.equal(await page.locator('input.ttm-bridge, textarea.ttm-bridge, select.ttm-bridge').count(), 0, 'bridge must not be user-editable');
        assert.equal(await page.getByRole('button', {name: 'Добавить сеть', exact: true}).count(), 0);
        assert.equal(await page.locator('.ttm-remove').count(), 0);
        await page.getByRole('button', {name: 'Запустить', exact: true}).click();
        assert.match(await page.locator('#ttm-message').innerText(), /Демонстрация/);

        const exportEndpoint = page.getByRole('button', {name: 'Проверить и скачать конфигурацию', exact: true});
        await expectError(exportEndpoint, '#ttm-connection-message', /Некорректное поле/);
        assert.equal(await page.locator('#ttm-upstreams').inputValue(), '', 'manual connection must not inject a DNS provider');
        assert.equal(await page.locator('#ttm-upstreams').evaluate(field => field.readOnly), false);
        for (const [name, value] of Object.entries(manual)) await page.locator('#ttm-' + name).fill(value);
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

        const rows = await networkRows();
        assert.deepEqual(Object.keys(rows).sort(), Object.keys(sources).sort());
        for (const bridge of Object.keys(sources)) await rows[bridge].locator('.ttm-cidrs').fill(sources[bridge]);
        await page.getByRole('button', {name: 'Выбрать все', exact: true}).click();
        assert.equal(await page.locator('.ttm-selected:checked').count(), 4);
        assert.match(await page.locator('#ttm-network-count').innerText(), /^4 /);
        const exportPolicy = page.getByRole('button', {name: 'Скачать политику для SSH', exact: true});
        const savePolicy = page.getByRole('button', {name: 'Сохранить маршрутизацию', exact: true});
        await page.locator('#ttm-v6ack').uncheck();
        await expectError(savePolicy, '#ttm-message', /Подтвердите/);
        await page.locator('#ttm-v6ack').check();
        const all = await downloadJson(exportPolicy, 'policy', 'trusttunnel-policy.json');
        assert.equal(all.schema, 3);
        assert.equal(Object.hasOwn(all, 'dns_ipv4'), false);
        assert.deepEqual(all.networks.map(network => network.lan_if).sort(), ['br0', 'br1', 'br2', 'br3']);
        await savePolicy.click();
        assert.match(await page.locator('#ttm-message').innerText(), /Демонстрация/);

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
        assert.equal(await page.locator('#ttm-state').innerText(), 'TUN создан; связь не проверена', 'process/TUN presence must not be presented as a verified VPN');
        assert.equal(await savePolicy.isDisabled(), true, 'editing must remain disabled while the addon is enabled');
        assert.equal(await exportPolicy.isDisabled(), true);
        await page.evaluate(() => { Object.assign(window.TTM_PREVIEW, {enabled: false, process_running: false, interface_up: false, state: 'disabled'}); window.done_validating(); });
        assert.equal(await savePolicy.isEnabled(), true);
        for (const bridge of Object.keys(sources)) await rows[bridge].locator('.ttm-cidrs').fill(sources[bridge]);
        await page.getByRole('button', {name: 'Выбрать все', exact: true}).click();
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
        assert.deepEqual(errors, [], 'no page or console errors');
        assert.deepEqual(httpRequests, [], 'offline preview must issue no HTTP requests');
        assert.deepEqual((await context.storageState()).origins, [], 'no persisted connection data');
        console.log('PASS: ' + viewport.width + 'px; manual/tt:// DNS-preserving downloads, ' + validations + ' backend validations, SSID-labelled 4-network/subset selection, immutable bridges, no routing DNS, IPv6 acknowledgement, invalid-input errors, enabled-state controls, no horizontal overflow; 0 page/console errors; 0 HTTP requests');
    } finally {
        await context.close();
        fs.rmSync(temporary, {recursive: true, force: true});
    }
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
        assert.equal(await page.locator('.ttm-network').count(), 0, 'an empty inventory must not invent br0–br3');
        assert.equal(await page.locator('.ttm-selected').count(), 0);
        await page.getByRole('button', {name: 'Скачать политику для SSH', exact: true}).click();
        assert.match(await page.locator('#ttm-message').innerText(), /Выберите/);

        const untrustedSsid = '<script>window.ssidExecuted=true</script><img src=x onerror="window.ssidExecuted=true">';
        await page.setContent(previewWithStatus(status => {
            status.policy = null;
            status.discovered_networks = [
                {lan_if: 'br0', sources: ['192.168.10.0/24'], ssids: ['Home 2.4', 'Home 5']},
                {lan_if: 'br1', sources: ['192.168.50.0/24'], ssids: [untrustedSsid]}
            ];
        }), {waitUntil: 'load'});
        assert.equal(await page.locator('.ttm-network').count(), 2, 'several SSIDs on one bridge must remain one routing choice');
        await page.getByRole('checkbox', {name: 'Home 2.4 / Home 5', exact: true}).check();
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
        assert.deepEqual(policy.networks, [{lan_if: 'br0', sources: ['192.168.10.0/24']}], 'immutable inventory model determines the exported bridge');
        assert.equal(Object.hasOwn(policy, 'dns_ipv4'), false);

        await page.setContent(previewWithStatus(status => {
            status.policy = null;
            status.discovered_networks = [
                {lan_if: 'br0', sources: ['192.168.10.0/24'], ssids: ['Home']},
                {lan_if: 'br1', sources: ['192.168.50.0/24'], ssids: ['Guest 1']}
            ];
        }), {waitUntil: 'load'});
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
        assert.deepEqual(remainingPolicy.networks, [{lan_if: 'br1', sources: ['192.168.50.0/24']}]);
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
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
