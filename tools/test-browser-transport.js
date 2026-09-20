'use strict';
// Real browser + simulated native HTTP events. Does NOT verify Merlin httpd/CSRF.
const assert=require('node:assert/strict'), fs=require('node:fs'), path=require('node:path');
const {generateKeyPairSync,privateDecrypt,constants}=require('node:crypto');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const html=fs.readFileSync(path.join(root,'preview/index.html'),'utf8');
const fixture=JSON.parse(html.match(/window\.TTM_PREVIEW=(.*?);<\/script>/s)[1]);
const document=html.replace(/window\.TTM_PREVIEW=.*?;<\/script>/s,'</script>');
const endpoint=JSON.parse(fs.readFileSync(path.join(root,'examples/endpoint.example.json'),'utf8'));
endpoint.password='synthetic-browser-秘密-😀'; endpoint.username='synthetic-user';
(async()=>{
    const browser=await chromium.launch({headless:true,...(process.env.TTM_CHROMIUM_PATH?{executablePath:process.env.TTM_CHROMIUM_PATH}:{})});
    const context=await browser.newContext({ignoreHTTPSErrors:true});
    const page=await context.newPage(), errors=[], commands=[];
    const state={...fixture,timestamp:Math.floor(Date.now()/1000),revision:'0',endpoint:{configured:false,exclusions:[]},operations:[]};
    let transfer={state:'idle'}, keys, parts=[], plain=[], saved, stale=false;
    page.on('pageerror',e=>errors.push(String(e)));
    await context.route('**/*',async route=>{
        const req=route.request(), url=new URL(req.url());
        if(url.origin!=='https://router.test') { await route.abort(); return; }
        if(url.pathname==='/user1.asp') { await route.fulfill({contentType:'text/html',body:document}); return; }
        if(url.pathname.endsWith('/status.json')) { state.timestamp=Math.floor(Date.now()/1000); await route.fulfill({json:state}); return; }
        if(url.pathname.endsWith('/transfer.json')) { await route.fulfill({json:transfer}); return; }
        if(url.pathname==='/start_apply.htm') {
            const form=new URLSearchParams(req.postData()), command=form.get('action_script'); commands.push(command);
            assert.ok(command.length<=127); assert.equal(form.has('amng_custom'),false);
            assert.ok(!req.postData().includes(endpoint.password)&&!req.postData().includes(endpoint.username));
            let match;
            if((match=command.match(/^start_ttm_begin_([a-f0-9]{16})_(\d+)$/))) {
                keys=generateKeyPairSync('rsa',{modulusLength:2048}); parts=[]; plain=[];
                transfer={id:match[1],blocks:Number(match[2]),next:0,state:'receiving',public_key:keys.publicKey.export({type:'spki',format:'pem'})};
            } else if((match=command.match(/^start_ttm_part_([a-f0-9]{16})_(\d+)_([a-f0-9]+)$/))) {
                assert.equal(match[1],transfer.id); assert.equal(Number(match[2]),transfer.next);
                parts.push(match[3]); transfer.next++;
                if(parts.length===6) {
                    const block=privateDecrypt({key:keys.privateKey,oaepHash:'sha256',padding:constants.RSA_PKCS1_OAEP_PADDING},Buffer.from(parts.join(''),'hex'));
                    const split=block.indexOf(10); assert.equal(block.subarray(0,split).toString(),`TTM1 ${transfer.id} ${plain.length} ${transfer.blocks}`);
                    plain.push(block.subarray(split+1)); parts=[];
                }
            } else if((match=command.match(/^start_ttm_commit_([a-f0-9]{16})$/))) {
                assert.equal(transfer.next,transfer.blocks*6);
                const request=JSON.parse(Buffer.concat(plain).toString());
                if(stale) state.operations=[{id:match[1],state:'failed',code:'revision_conflict',action:request.kind,revision:'other'}];
                else { assert.equal(request.revision,state.revision);
                    if(request.kind==='exclusions') { assert.deepEqual(Object.keys(request.data),['exclusions']); saved={...saved,...request.data}; }
                    else saved=request.data;
                    state.endpoint={configured:true,exclusions:saved.exclusions||[]}; state.revision=state.revision==='0'?'abcdef0123456789':'fedcba9876543210'; state.operations=[{id:match[1],state:'succeeded',code:'saved',action:request.kind,revision:state.revision}]; }
                transfer={state:'idle'};
            } else if(!command.startsWith('start_ttm_abort_')) throw new Error('Unexpected event');
            // Real Merlin redirects the parent from this response. The addon
            // must consume HTML as inert fetch data, not execute an iframe.
            await route.fulfill({contentType:'text/html',body:'<html><body><script>parent.location.href="/unexpected-native-redirect";</script>queued</body></html>'}); return;
        }
        await route.abort();
    });
    try {
        await page.goto('https://router.test/user1.asp');
        await page.getByRole('tab',{name:'Подключение',exact:true}).click();
        await page.locator('#ttm-file').setInputFiles({name:'synthetic.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(endpoint))});
        await page.waitForFunction(()=>document.getElementById('ttm-password').value.length>0);
        await page.locator('#ttm-save-endpoint').click();
        await page.waitForFunction(()=>document.getElementById('ttm-message').textContent==='Операция выполнена.',{},{timeout:60000});
        assert.deepEqual(saved,endpoint); assert.equal(await page.locator('#ttm-password').inputValue(),'');
        assert.ok(commands.length>3); assert.deepEqual(errors,[]);
        await page.reload();
        await page.getByRole('tab',{name:'Подключение',exact:true}).click();
        assert.equal(await page.locator('#ttm-password').inputValue(),'');
        await page.locator('#ttm-exclusion-domains').fill('example.org');
        await page.locator('#ttm-exclusion-networks').fill('198.51.100.0/24');
        await page.waitForTimeout(5500); // polling must preserve the unsaved exclusion draft
        assert.equal(await page.locator('#ttm-exclusion-domains').inputValue(),'example.org');
        await page.locator('#ttm-save-exclusions').click();
        await page.waitForFunction(()=>document.getElementById('ttm-message').textContent==='Операция выполнена.',{},{timeout:60000});
        assert.deepEqual(saved,{...endpoint,exclusions:['example.org','198.51.100.0/24']});
        assert.equal(await page.locator('#ttm-password').inputValue(),'');
        await page.reload();
        await page.getByRole('tab',{name:'Подключение',exact:true}).click();
        await page.waitForFunction(()=>document.getElementById('ttm-exclusion-domains').value==='example.org');
        assert.equal(await page.locator('#ttm-exclusion-networks').inputValue(),'198.51.100.0/24');
        assert.equal(await page.locator('#ttm-username').inputValue(),'');
        // A second browser revision conflict leaves user input intact and reports failure.
        stale=true;
        await page.locator('#ttm-file').setInputFiles({name:'synthetic.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(endpoint))});
        await page.waitForFunction(()=>document.getElementById('ttm-password').value.length>0);
        assert.equal(await page.locator('#ttm-save-exclusions').isDisabled(),true);
        await page.locator('#ttm-save-endpoint').click();
        await page.waitForFunction(()=>document.getElementById('ttm-message').textContent.includes('другой вкладке'),{},{timeout:60000});
        assert.equal(await page.locator('#ttm-password').inputValue(),endpoint.password);
        assert.equal(await page.locator('#ttm-message').getAttribute('class'),'ttm-error');
        assert.deepEqual(errors,[]);
        assert.ok(!(JSON.stringify(state)+JSON.stringify(commands)).includes(endpoint.password));
        console.log('PASS: HTTPS browser file import → encrypted native events → acknowledged save; no plaintext credentials in form/status; successful save clears secrets; exclusions-only save and reload preserve credentials/DNS; stale revision preserves input and shows failure. Merlin HTTP/authentication NOT TESTED.');
    } finally { await context.close(); await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
