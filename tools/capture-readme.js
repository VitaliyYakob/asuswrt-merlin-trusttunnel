#!/usr/bin/env node
'use strict';
// Public screenshots rendered from the actual UI, with offline demonstration data.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {chromium} = require('playwright');
const root = path.resolve(__dirname, '..');
const target = path.join(root, 'docs', 'images');
(async () => {
    fs.mkdirSync(target, {recursive: true});
    const browser = await chromium.launch({headless: true});
    const context = await browser.newContext({viewport: {width: 1280, height: 960}, offline: true, locale: 'ru-RU'});
    await context.route('**/*', route => route.abort());
    const page = await context.newPage(), errors = [], requests = [];
    page.on('pageerror', error => errors.push(String(error)));
    page.on('request', request => { if (/^https?:/.test(request.url())) requests.push(request.url()); });
    try {
        const html = fs.readFileSync(path.join(root, 'preview/index.html'), 'utf8');
        // The preview generator uses only synthetic SSIDs, client names and addresses.
        assert.ok(!html.includes('Home_net') && !html.includes('Old-Mac-Net') && !html.includes('nordhaven.ru'));
        await page.setContent(html, {waitUntil: 'load'});
        await page.screenshot({path: path.join(target, 'overview.png'), fullPage: true});
        await page.getByRole('tab', {name: 'Подключение', exact: true}).click();
        await page.locator('#ttm-profile-editor > summary').click();
        await page.screenshot({path: path.join(target, 'connection.png'), fullPage: true});
        await page.getByRole('tab', {name: 'Сети', exact: true}).click();
        await page.screenshot({path: path.join(target, 'networks.png'), fullPage: true});
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
        assert.deepEqual(errors, []);
        assert.deepEqual(requests, []);
        console.log('Public UI screenshots: actual offline UI, synthetic data only, no HTTP requests/errors.');
    } finally {
        await context.close();
        await browser.close();
    }
})().catch(error => { console.error(error); process.exitCode = 1; });
