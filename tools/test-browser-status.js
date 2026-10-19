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
        assert.ok(await page.locator('#ttm-toggle').isDisabled());
        assert.match(await page.locator('#ttm-age').innerText(), /\d{2}\.\d{2}\.\d{4}/);
        assert.ok(!(await page.locator('#ttm-message').innerText()).includes('обновления контроллера'));
        await page.getByRole('button',{name:'Обновить данные',exact:true}).click();
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent === 'Статус обновлён.');
        assert.equal(commands.length, 1);
        assert.equal(await page.locator('#ttm-toggle').isDisabled(), false);
        state.health = {details_ready:false,error:'nvram_unavailable'};
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent.includes('сведения о Wi-Fi'));
        assert.equal(await page.locator('#ttm-policy-fields').evaluate(fieldset => fieldset.disabled), true);
        assert.equal(await page.locator('#ttm-save').isDisabled(), true);
        assert.equal(await page.locator('#ttm-toggle').isDisabled(), false);
        state.health = {details_ready:true,error:''};
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-message').textContent === 'Статус обновлён.');
        assert.equal(await page.locator('#ttm-policy-fields').evaluate(fieldset => fieldset.disabled), false);
        assert.equal(await page.locator('#ttm-save').isDisabled(), false);
        // A successful observation must remain visible after its freshness
        // expires, without turning historical guards into current proof.
        state.diagnostics.guard='installed_unverified';
        state.traffic_check_history={checked_at:Math.floor(Date.now()/1000)-3600,state:'traffic_observed',
            sent_packets:9,received_packets:4,rules_checked:true,leak_test_verified:false,fresh:false,stale_reason:'expired'};
        state.traffic_check=null;
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-traffic-check').textContent.includes('в обе стороны'));
        assert.match(await page.locator('#ttm-traffic-checked-at').innerText(),/\d{2}\.\d{2}\.\d{4}/);
        assert.match(await page.locator('#ttm-traffic-checked-at').innerText(),/отправлено 9, получено 4/);
        assert.match(await page.locator('#ttm-traffic-freshness').innerText(),/больше 5 минут/);
        assert.ok(!(await page.locator('#ttm-guard').innerText()).includes('маршрут проверены'));
        assert.ok(!(await page.locator('#ttm-traffic-check').innerText()).includes('Ещё не выполнялась'));
        const screenshots=path.join(root,'build/browser-screenshots');fs.mkdirSync(screenshots,{recursive:true});
        await page.screenshot({path:path.join(screenshots,'traffic-history.png'),fullPage:true});
        await page.setViewportSize({width:390,height:844});
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth<=window.innerWidth+1));
        assert.equal(await page.locator('#ttm-traffic-checked-at').isVisible(),true);
        await page.screenshot({path:path.join(screenshots,'traffic-history-mobile.png'),fullPage:true});
        await page.setViewportSize({width:1280,height:720});
        for(const [reason,pattern] of [['client_restarted',/клиент был перезапущен/],['settings_changed',/настройки изменились/],['router_restarted',/роутер был перезагружен/],['client_stopped',/Клиент остановлен/]]) {
            state.traffic_check_history.stale_reason=reason;
            await page.evaluate(() => window.done_validating());
            await page.waitForFunction(expected => document.getElementById('ttm-traffic-freshness').textContent.includes(expected),pattern.source);
            assert.match(await page.locator('#ttm-traffic-freshness').innerText(),pattern);
            assert.match(await page.locator('#ttm-traffic-check').innerText(),/в обе стороны/);
        }
        state.traffic_check_history.fresh=true;state.traffic_check_history.stale_reason=null;
        state.traffic_check={...state.traffic_check_history};
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-traffic-freshness').textContent.includes('Актуально'));
        assert.match(await page.locator('#ttm-guard').innerText(),/Правила и маршрут проверены/);
        state.traffic_check=state.traffic_check_history=null;
        await page.evaluate(() => window.done_validating());
        await page.waitForFunction(() => document.getElementById('ttm-traffic-check').textContent==='Проверка ещё не выполнялась');
        assert.equal(await page.locator('#ttm-traffic-checked-at').isVisible(),false);
        assert.match(await page.locator('#ttm-traffic-freshness').innerText(),/Дополнительные действия/);
        assert.equal(commands.length,1,'refreshing history must not launch another traffic test');
        assert.deepEqual(errors, []);
        console.log('PASS: stale status/read-only refresh, NVRAM recovery, persistent dated traffic history, distinct stale reasons, fresh-only guard proof; no external network');
    } finally { await context.close(); await browser.close(); }
})().catch(error => {console.error(error); process.exitCode = 1;});
