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
const manual = {hostname: 'vpn.example.com', addresses: '203.0.113.10:443', username: 'browser-test-user', password: 'browser-test-«пароль»-$()<>😀'};
const sources = {br0: '192.168.10.0/24', br1: '192.168.50.0/24', br2: '192.168.60.0/24', br3: '192.168.70.0/24'};

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
        for (let i = 0; i < await rows.count(); i++) {
            const item = rows.nth(i);
            result[await item.locator('.ttm-bridge').inputValue()] = item;
        }
        return result;
    }
    try {
        await page.setContent(fs.readFileSync(preview, 'utf8'), {waitUntil: 'load'});
        assert.equal(await page.locator('#ttm-state').innerText(), 'Отключён');
        assert.equal(await page.locator('.ttm-network').count(), 4);
        await page.getByRole('button', {name: 'Запустить', exact: true}).click();
        assert.match(await page.locator('#ttm-message').innerText(), /Демонстрация/);

        const exportEndpoint = page.getByRole('button', {name: 'Проверить и скачать конфигурацию', exact: true});
        await expectError(exportEndpoint, '#ttm-connection-message', /Некорректное поле/);
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
        assert.deepEqual(imported.dns_upstreams, ['tls://1.1.1.1']);
        await page.getByRole('button', {name: 'Очистить данные', exact: true}).click();
        assert.equal(await page.locator('#ttm-password').inputValue(), '');
        assert.equal(await page.locator('#ttm-username').inputValue(), '');
        assert.equal(await page.locator('#ttm-link').inputValue(), '');
        assert.equal(await page.locator('#ttm-password').getAttribute('type'), 'password');

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
        assert.equal(all.schema, 2);
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
        await page.locator('#ttm-dns').fill('127.0.0.1');
        await expectError(exportPolicy, '#ttm-message', /внешний DNS/);
        await page.locator('#ttm-dns').fill('1.1.1.1');
        await page.getByRole('button', {name: 'Добавить сеть', exact: true}).click();
        assert.equal(await page.locator('.ttm-network').count(), 5);
        await page.locator('.ttm-network').last().getByRole('button').click();
        assert.equal(await page.locator('.ttm-network').count(), 4);

        await page.evaluate(() => { Object.assign(window.TTM_PREVIEW, {enabled: true, process_running: true, interface_up: true, state: 'tun_ready_unverified'}); window.done_validating(); });
        assert.equal(await page.locator('#ttm-state').innerText(), 'TUN создан; связь не проверена', 'process/TUN presence must not be presented as a verified VPN');
        assert.equal(await savePolicy.isDisabled(), true, 'editing must remain disabled while the addon is enabled');
        assert.equal(await exportPolicy.isDisabled(), true);
        await page.evaluate(() => { Object.assign(window.TTM_PREVIEW, {enabled: false, process_running: false, interface_up: false, state: 'disabled'}); window.done_validating(); });
        assert.equal(await savePolicy.isEnabled(), true);
        for (const bridge of Object.keys(sources)) await rows[bridge].locator('.ttm-cidrs').fill(sources[bridge]);
        await page.getByRole('button', {name: 'Выбрать все', exact: true}).click();
        for (const [name, value] of Object.entries(manual)) await page.locator('#ttm-' + name).fill(value);
        await page.evaluate(() => { document.getElementById('ttm-message').textContent = 'OFFLINE PREVIEW — команды не отправляются на роутер.'; document.getElementById('ttm-message').className = 'ttm-note'; document.getElementById('ttm-connection-message').textContent = ''; });
        const overflow = await page.evaluate(() => ({width: document.documentElement.scrollWidth, viewport: window.innerWidth}));
        assert.ok(overflow.width <= overflow.viewport + 1, 'page must fit viewport without horizontal scrolling: ' + JSON.stringify(overflow));
        await page.evaluate(() => { if (document.activeElement) document.activeElement.blur(); });
        await page.screenshot({path: path.join(root, 'preview', screenshot), fullPage: true});
        assert.deepEqual(errors, [], 'no page or console errors');
        assert.deepEqual(httpRequests, [], 'offline preview must issue no HTTP requests');
        assert.deepEqual((await context.storageState()).origins, [], 'no persisted connection data');
        console.log('PASS: ' + viewport.width + 'px; manual/tt:// downloads, ' + validations + ' backend validations, 4-network/subset selection, IPv6 acknowledgement, invalid-input errors, enabled-state controls, no horizontal overflow; 0 page/console errors; 0 HTTP requests');
    } finally {
        await context.close();
        fs.rmSync(temporary, {recursive: true, force: true});
    }
}
(async () => {
    const options = {headless: true};
    if (process.env.TTM_CHROMIUM_PATH) options.executablePath = process.env.TTM_CHROMIUM_PATH;
    const browser = await chromium.launch(options);
    try {
        console.log('Browser: Chromium ' + browser.version() + '; Playwright ' + require('playwright/package.json').version);
        await exercise(browser, {width: 1280, height: 1000}, 'screenshot.png');
        await exercise(browser, {width: 390, height: 844}, 'screenshot-mobile.png');
    } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
