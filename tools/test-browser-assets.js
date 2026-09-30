#!/usr/bin/env node
'use strict';
/* Offline resource-loading regression. Native httpd/auth are tested separately
 * on the router. The fixture reproduces its observed exact-path CSS lookup. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '..');

(async () => {
    const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ttm-assets-'));
    let browser;
    try {
        const publish = spawnSync('busybox', ['ash', '-c', 'TT_BASE="$TT_TEST_BASE"; . "$TT_BASE/lib/common.sh"; . "$TT_BASE/lib/webui.sh"; tt_publish_ui_assets'], {
            env: {...process.env, TT_ROOT: sandbox, TT_TEST_BASE: path.join(root, 'addon')}, encoding: 'utf8'
        });
        assert.equal(publish.error, undefined);
        assert.equal(publish.status, 0, publish.stderr);
        const template = fs.readFileSync(path.join(root, 'addon/trusttunnel_page.asp'), 'utf8');
        const href = template.match(/<link rel="stylesheet" href="(\/user\/trusttunnel\/[^\"]+)">/)[1];
        // Use the real stylesheet link and body; firmware scripts are outside
        // this test. All HTTP requests are intercepted, with no live connection.
        const html = template.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')
            .replace(/<%[\s\S]*?%>/g, '').replace(' onload="ttmInitial()"', '');
        browser = await chromium.launch({headless: true, ...(process.env.TTM_CHROMIUM_PATH ? {executablePath: process.env.TTM_CHROMIUM_PATH} : {})});
        const context = await browser.newContext({viewport: {width: 1280, height: 900}});
        const page = await context.newPage();
        const cssResponses = [], errors = [];
        page.on('pageerror', error => errors.push(String(error)));
        await context.route('**/*', async route => {
            const url = new URL(route.request().url());
            if (url.origin !== 'https://merlin.invalid') return route.abort();
            if (url.pathname === '/user2.asp') return route.fulfill({status: 200, contentType: 'text/html', body: html});
            if (url.pathname.startsWith('/user/trusttunnel/')) {
                // Deliberately do NOT remove ?query, matching AX86U httpd.
                const file = path.join(sandbox, 'www', url.pathname + url.search);
                const exists = fs.existsSync(file);
                cssResponses.push({url: url.pathname + url.search, status: exists ? 200 : 404});
                return route.fulfill({status: exists ? 200 : 404, contentType: exists ? 'text/css' : 'text/html', body: exists ? fs.readFileSync(file) : 'Not found'});
            }
            return route.fulfill({status: 200, contentType: 'text/css', body: ''});
        });
        await page.goto('https://merlin.invalid/user2.asp', {waitUntil: 'load'});
        assert.deepEqual(cssResponses, [{url: href, status: 200}], 'real template must request the published CSS without a query');
        assert.deepEqual(errors, []);
        assert.equal(await page.locator('.ttm-container').evaluate(el => getComputedStyle(el).backgroundColor), 'rgb(77, 89, 93)');
        assert.equal(await page.locator('.ttm-grid').first().evaluate(el => getComputedStyle(el).display), 'grid');
        assert.equal(await page.locator('#ttm-version').innerText(), fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim());
        await context.close();
        console.log('PASS: real ASP stylesheet link → published versioned file → CSS/grid applied; no external network; native httpd/auth NOT mocked as hardware proof');
    } finally {
        if (browser) await browser.close();
        fs.rmSync(sandbox, {recursive: true, force: true});
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
