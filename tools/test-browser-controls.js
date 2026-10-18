'use strict';
// Native command flow in an offline browser. No real router or network changes.
const assert = require('node:assert/strict'), fs = require('node:fs'), path = require('node:path');
const {chromium} = require('playwright');
const html = fs.readFileSync(path.resolve(__dirname, '../preview/index.html'), 'utf8');
const fixture = JSON.parse(html.match(/window\.TTM_PREVIEW=(.*?);<\/script>/s)[1]);
const document = html.replace(/window\.TTM_PREVIEW=.*?;<\/script>/s, '</script>');
(async () => {
    const browser = await chromium.launch({headless:true, ...(process.env.TTM_CHROMIUM_PATH ? {executablePath:process.env.TTM_CHROMIUM_PATH} : {})});
    const context = await browser.newContext(), page = await context.newPage(), commands = [], errors = [];
    const state = {...fixture, timestamp:Math.floor(Date.now()/1000), enabled:false, process_running:false, interface_up:false, state:'disabled', transaction:null, operations:[]};
    let finish = null, outcome = 'success', accept = true, confirmations = 0;
    page.on('pageerror', error => errors.push(String(error)));
    page.on('dialog', async dialog => { confirmations++; await (accept ? dialog.accept() : dialog.dismiss()); });
    await context.route('**/*', async route => {
        const url = new URL(route.request().url());
        if (url.origin !== 'https://router.test') return route.abort();
        if (url.pathname === '/user1.asp') return route.fulfill({contentType:'text/html',body:document});
        if (url.pathname.endsWith('/status.json')) return route.fulfill({json:state});
        if (url.pathname === '/start_apply.htm') {
            const command = new URLSearchParams(route.request().postData()).get('action_script');
            const match = command.match(/^start_ttm_do_([a-f0-9]{16})_(start|disable|pause)$/);
            assert.ok(match, 'only the selected existing native command may be sent');
            commands.push(match[2]);
            const op = {id:match[1], action:match[2], state:'running', code:'', revision:state.revision};
            state.operations = [op];
            finish = () => {
                op.state = outcome==='failure' ? 'failed' : 'succeeded';
                op.code = outcome==='failure' ? 'action_failed' : 'completed';
                if (outcome!=='failure') {
                    state.enabled = match[2]!=='disable';
                    state.process_running = state.interface_up = match[2]==='start';
                    state.state = match[2]==='start' ? 'tun_ready_unverified' : match[2]==='pause' ? 'paused_protected' : 'disabled';
                }
            };
            if (outcome!=='pending') finish();
            return route.fulfill({body:'queued'});
        }
        return route.abort();
    });
    async function completed() {
        await page.waitForFunction(() => !document.getElementById('ttm-toggle').disabled);
    }
    async function render() {
        await page.evaluate(() => window.done_validating());
        await page.waitForTimeout(150);
    }
    try {
        await page.goto('https://router.test/user1.asp');
        await completed();
        const toggle = page.locator('#ttm-toggle'), release = page.locator('#ttm-release-guards');
        assert.equal(await toggle.innerText(), 'Подключить');
        assert.equal(await page.locator('#ttm-advanced-actions').getAttribute('open'), null);
        assert.equal(await page.getByRole('button',{name:'Пауза с блокировкой',exact:true}).count(), 0);
        assert.equal(await release.isVisible(), false);
        outcome = 'pending';
        const queued = page.waitForResponse(response => new URL(response.url()).pathname==='/start_apply.htm');
        await toggle.click();
        await queued;
        await page.waitForFunction(() => document.getElementById('ttm-toggle').disabled);
        await page.evaluate(() => { window.ttmToggle(); window.ttmToggle(); });
        assert.equal(commands.length, 1, 'duplicate clicks cannot queue a second start');
        outcome = 'success'; finish();
        await completed();
        assert.equal(await toggle.innerText(), 'Отключить');
        assert.deepEqual(commands, ['start']);
        accept = false;
        await toggle.click();
        assert.equal(confirmations, 1);
        assert.deepEqual(commands, ['start'], 'cancel must leave VPN running');
        assert.equal(await toggle.innerText(), 'Отключить');
        accept = true;
        await toggle.click();
        await completed();
        assert.deepEqual(commands, ['start', 'disable']);
        assert.equal(await toggle.innerText(), 'Подключить');
        await toggle.click(); await completed();
        await page.locator('#ttm-advanced-actions > summary').click();
        await page.getByRole('button',{name:'Пауза с блокировкой',exact:true}).click();
        await completed();
        assert.equal(await toggle.innerText(), 'Подключить', 'pause offers guarded resume');
        assert.equal(await release.isVisible(), true, 'explicit release remains possible while paused');
        assert.equal(state.enabled, true);
        outcome = 'failure';
        await toggle.click(); await completed();
        assert.match(await page.locator('#ttm-message').innerText(), /ошибкой/);
        assert.equal(await toggle.innerText(), 'Подключить', 'failed resume must not pretend to be connected');
        assert.equal(await release.isVisible(), true);
        outcome = 'success';
        await release.click(); await completed();
        assert.equal(state.enabled, false);
        assert.equal(await release.isVisible(), false);
        state.transaction = {id:'0123456789abcdef', deadline:Math.floor(Date.now()/1000)+180};
        await render();
        assert.equal(await toggle.isDisabled(), true, 'trial migration still gates runtime actions');
        state.transaction = null; state.timestamp -= 86400;
        await render();
        assert.equal(await toggle.isDisabled(), true, 'stale status must not choose a command');
        const count = commands.length;
        await page.evaluate(() => window.ttmToggle());
        assert.equal(commands.length, count);
        assert.deepEqual(errors, []);
        console.log('PASS: one stateful connect/disconnect button; advanced actions collapsed; pending double click blocked; disable confirmation/cancel; guarded pause/resume and failed start; explicit guard release; transaction/stale gating; no external network');
    } finally { await context.close(); await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
