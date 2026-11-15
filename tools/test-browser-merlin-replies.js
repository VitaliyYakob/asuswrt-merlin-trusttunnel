'use strict';
// Native reply shapes are simulated. Every request is intercepted.
const assert=require('node:assert/strict'), fs=require('node:fs'), path=require('node:path');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const html=fs.readFileSync(path.join(root,'preview/index.html'),'utf8');
const fixture=JSON.parse(html.match(/window\.TTM_PREVIEW=(.*?);<\/script>/s)[1]);
const document=html.replace(/window\.TTM_PREVIEW=.*?;<\/script>/s,'</script>');
const pageUrl='https://router.test/user1.asp';
// The conditional check from the normal 3004.388.12_2 start_apply.htm
// template contains a login marker but is not a denial.
const applyHtml='<html><head><script>function checkHttpd(xhr){if(xhr.responseText.search("Main_Login.asp") !== -1) top.location.href = "/";} top.location.href="/unexpected-navigation";</script></head></html>';
const loginHtml="<HTML><HEAD><script>window.top.location.href='/Main_Login.asp';</script>\n</HEAD></HTML>\n";

(async()=>{
    const browser=await chromium.launch({headless:true,...(process.env.TTM_CHROMIUM_PATH?{executablePath:process.env.TTM_CHROMIUM_PATH}:{})});
    const context=await browser.newContext(), page=await context.newPage(), posts=[], errors=[];
    const state={...fixture,transaction:null,operations:[],client_updates:{...fixture.client_updates,last_check:null}};
    const check=page.getByRole('button',{name:'Проверить обновления',exact:true});
    const reconcile=page.getByRole('button',{name:'Проверить результат',exact:true});
    const msg=page.locator('#ttm-message');
    const old={id:'ffffffffffffffff',action:'check_updates',state:'succeeded',code:'completed'};
    let reply='normal', current=null, polls=0, denyStatus=false;
    page.on('pageerror',error=>errors.push(String(error)));
    await page.addInitScript(()=>{
        const fetch=window.fetch.bind(window);
        window.fetch=async function (...args) {
            const response=await fetch(...args), finalUrl=response.headers.get('x-ttm-fixture-final-url');
            // Simulate the final URL after a followed redirect without
            // allowing any follow-up request outside the intercepted fixture.
            if(finalUrl) Object.defineProperty(response,'url',{value:new URL(finalUrl,location.href).href});
            return response;
        };
    });
    await context.route('**/*',async route=>{
        const request=route.request(), url=new URL(request.url());
        if(url.origin!=='https://router.test') return route.abort();
        if(url.pathname==='/user1.asp') return route.fulfill({contentType:'text/html',body:document});
        if(url.pathname.endsWith('/status.json')){
            state.timestamp=Math.floor(Date.now()/1000);
            if(denyStatus && request.resourceType()==='fetch') return route.fulfill({contentType:'text/html',body:loginHtml});
            let operations=state.operations;
            if(reply==='normal' && current && request.resourceType()==='fetch'){
                polls++;
                if(polls===1) operations=[old];
                if(polls===2) operations=[{...current,action:'diagnostics'}];
                if(polls===3) operations=[{...current,state:'running'}];
            }
            return route.fulfill({json:{...state,operations}});
        }
        if(url.pathname==='/start_apply.htm'){
            assert.equal(request.method(),'POST');
            const form=new URLSearchParams(request.postData());
            const match=form.get('action_script').match(/^start_ttm_do_([a-f0-9]{16})_(check_updates|update_client_[a-f0-9]{16})$/);
            assert.ok(match); assert.equal(form.has('amng_custom'),false);
            posts.push(match[0]);
            if(reply===401 || reply===403) return route.fulfill({status:reply,body:'access denied'});
            if(reply==='login') return route.fulfill({status:200,contentType:'text/html',body:loginHtml});
            if(reply==='redirect') return route.fulfill({contentType:'text/html',headers:{'x-ttm-fixture-final-url':'/Main_Login.asp'},
                body:'<html><title>ASUS Login</title></html>'});
            const action=match[2].startsWith('update_client_')?'update_client':match[2];
            current={id:match[1],action,state:'succeeded',code:'completed'};
            if(reply==='failed') current={...current,state:'failed',code:'update_check_failed'};
            if(action==='update_client') current.code='confirmation_required';
            state.operations=reply==='lost'?[old]:[current,old];
            if(reply==='lost') return route.abort('failed');
            if(action==='check_updates' && current.state==='succeeded'){
                const time=Math.floor(Date.now()/1000);
                state.client_updates.last_check={checked_at:time,channel:'stable'};
                state.client_updates.check={id:'abcdefabcdefabcd',checked_at:time,channel:'stable',state:'available',
                    installed_version:'1.1.5',candidate:{tag:'v1.1.12'}};
            }
            return route.fulfill({contentType:'text/html',body:applyHtml});
        }
        return route.abort();
    });
    async function expectMessage(pattern){
        await page.waitForFunction(({source})=>new RegExp(source).test(document.getElementById('ttm-message').textContent),
            {source:pattern.source},{timeout:12000});
    }
    try{
        await page.goto(pageUrl);
        await check.click();
        await expectMessage(/^Операция выполнена\.$/);
        assert.ok(polls>=4,'old ID, mismatched action and running operation cannot confirm completion');
        assert.equal(posts.length,1);
        assert.match(await page.locator('#ttm-client-update').innerText(),/v1\.1\.12/);
        assert.notEqual(await page.locator('#ttm-client-checked-at').innerText(),'Ещё не выполнялась');
        assert.equal(await msg.getAttribute('class'),'ttm-note');
        assert.equal(page.url(),pageUrl,'HTML response must never navigate the panel');

        for(const denial of [401,403,'login','redirect']){
            await page.reload();
            reply=denial;
            const sent=posts.length;
            await check.click();
            await expectMessage(/^Сессия Merlin завершена или доступ отклонён/);
            assert.equal(posts.length,sent+1);
            assert.equal(await reconcile.isVisible(),false,'explicit POST denial is not a pending command');
            assert.equal(await msg.getAttribute('class'),'ttm-error');
            assert.equal(page.url(),pageUrl);
        }

        reply='failed';
        await check.click();
        await expectMessage(/^Не удалось получить официальный список релизов/);
        assert.equal(await reconcile.isVisible(),false);

        reply='lost';
        await check.click();
        await expectMessage(/^Роутер не подтвердил приём команды/);
        const sent=posts.length;
        assert.equal(await check.isDisabled(),true);
        state.operations=[current,old];
        await reconcile.click();
        await expectMessage(/^Операция выполнена\.$/);
        assert.equal(posts.length,sent,'reconciliation must only read status, never repeat the command');

        reply='lost-session-after-post'; denyStatus=true;
        await check.click();
        await expectMessage(/^Сессия Merlin завершена или доступ отклонён/);
        assert.equal(await reconcile.isVisible(),true,'denial of a later GET cannot prove rejection of the sent POST');
        assert.equal(await check.isDisabled(),true);
        denyStatus=false;
        await reconcile.click();
        await expectMessage(/^Операция выполнена\.$/);
        assert.equal(posts.length,sent+1);

        reply='upgrade-fixture';
        page.once('dialog',dialog=>dialog.accept());
        await page.getByRole('button',{name:'Обновить CLI',exact:true}).click();
        await expectMessage(/^Настройки применены временно/);
        assert.match(posts.at(-1),/_update_client_abcdefabcdefabcd$/);
        assert.equal(page.url(),pageUrl);
        assert.deepEqual(errors,[]);
        console.log('PASS: native HTTP 200, exact ID/action, 401/403, native login script and redirect, backend failure, no replay after lost POST/status auth, CLI update transport fixture');
    }finally{await context.close();await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
