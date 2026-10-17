'use strict';
// Offline UI recovery regression; all requests stay inside the synthetic router.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'preview/index.html'), 'utf8');
const fixture = JSON.parse(html.match(/window\.TTM_PREVIEW=(.*?);<\/script>/s)[1]);
const document = html.replace(/window\.TTM_PREVIEW=.*?;<\/script>/s, '</script>');

(async () => {
    const browser = await chromium.launch({headless:true, ...(process.env.TTM_CHROMIUM_PATH ? {executablePath:process.env.TTM_CHROMIUM_PATH} : {})});
    const context = await browser.newContext();
    const page = await context.newPage(), commands = [], errors = [];
    const state = {...fixture, timestamp:Math.floor(Date.now()/1000)-3*86400, transaction:null, operations:[], health:{details_ready:true,error:''}};
    page.on('pageerror', error => errors.push(String(error)));
    await context.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.origin !== 'https://router.test') return route.abort();
        if (url.pathname === '/user1.asp') return route.fulfill({contentType:'text/html',body:document});
        if (url.pathname.endsWith('/status.json')) return route.fulfill({json:state});
        if (url.pathname === '/start_apply.htm') {
            const command = new URLSearchParams(route.request().postData()).get('action_script');
            commands.push(command);
            const match = command.match(/^start_ttm_do_([a-f0-9]{16})_status$/);
            assert.ok(match, 'manual refresh must only request read-only status');
            state.timestamp = Math.floor(Date.now()/1000);
            state.operations = [{id:match[1],action:'status',state:'succeeded',code:'completed',revision:state.revision}];
            return route.fulfill({body:'queued'});
        }
        return route.abort();
    });
    try {
        await page.goto('https://router.test/user1.asp');
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent.includes('Статус не обновляется'));
        assert.ok(await page.getByRole('button',{name:'Пауза с блокировкой',exact:true}).isDisabled());
        assert.match(await page.locator('#ttm-age').innerText(), /\d{2}\.\d{2}\.\d{4}/);
        assert.ok(!(await page.locator('#ttm-message').innerText()).includes('обновления контроллера'));
        await page.getByRole('button',{name:'Обновить данные',exact:true}).click();
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent === 'Статус обновлён.');
        assert.equal(commands.length, 1);
        assert.equal(await page.getByRole('button',{name:'Пауза с блокировкой',exact:true}).isDisabled(), false);
        state.health = {details_ready:false,error:'nvram_unavailable'};
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent.includes('сведения о Wi-Fi'));
        assert.equal(await page.locator('#ttm-policy-fields').evaluate(fieldset => fieldset.disabled), true);
        assert.equal(await page.locator('#ttm-save').isDisabled(), true);
        assert.equal(await page.getByRole('button',{name:'Пауза с блокировкой',exact:true}).isDisabled(), false);
        state.health = {details_ready:true,error:''};
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent === 'Статус обновлён.');
        assert.equal(await page.locator('#ttm-policy-fields').evaluate(fieldset => fieldset.disabled), false);
        assert.equal(await page.locator('#ttm-save').isDisabled(), false);
        assert.deepEqual(errors, []);
        console.log('PASS: stale status blocks writes; manual refresh requests acknowledged read-only publication; full date shown; NVRAM failure isolates routing edits; healthy recovery clears warning; no external network');
    } finally { await context.close(); await browser.close(); }
})().catch(error => {console.error(error); process.exitCode = 1;});
