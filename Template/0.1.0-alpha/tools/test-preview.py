#!/usr/bin/env python3
"""Optional browser smoke test. Requires Playwright and an installed Chromium browser."""
from pathlib import Path
import shutil
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parents[1]
with sync_playwright() as playwright:
    binary=shutil.which('chromium') or shutil.which('chromium-browser')
    opts={'headless':True}
    if binary: opts['executable_path']=binary
    browser=playwright.chromium.launch(**opts)
    page=browser.new_page(viewport={'width':1280,'height':1200},device_scale_factor=1,locale='ru-RU')
    errors=[]
    requests=[]
    page.on('pageerror',lambda error: errors.append(str(error)))
    page.on('request',lambda request: requests.append(request.url))
    # Render supplied HTML directly; this verifies DOM behavior, not file:// navigation policy.
    page.set_content((root/'preview/index.html').read_text(),wait_until='load')
    assert page.locator('#ttm-state').inner_text()=='Отключён'
    page.get_by_role('button',name='Запустить',exact=True).click()
    assert 'Демонстрация' in page.locator('#ttm-message').inner_text()
    page.locator('#ttm-v6ack').uncheck()
    page.get_by_role('button',name='Сохранить политику').click()
    assert 'Подтвердите' in page.locator('#ttm-message').inner_text()
    page.locator('#ttm-v6ack').check()
    page.get_by_role('button',name='Сохранить политику').click()
    assert 'Демонстрация' in page.locator('#ttm-message').inner_text()
    assert not errors,errors
    assert not requests,requests
    page.evaluate("document.getElementById('ttm-message').textContent='OFFLINE PREVIEW — команды не отправляются на роутер.'")
    page.screenshot(path=str(root/'preview/screenshot.png'),full_page=True)
    print(f'PASS: Chromium {browser.version}; DOM/actions/IPv6 acknowledgement; 0 page errors; 0 network requests')
    browser.close()
