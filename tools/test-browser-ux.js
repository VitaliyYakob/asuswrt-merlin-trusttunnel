'use strict';
// UI concurrency, user intent and uncertain HTTP outcomes; all HTTP is synthetic.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const html=fs.readFileSync(path.resolve(__dirname,'../preview/index.html'),'utf8');
const fixture=JSON.parse(html.match(/window\.TTM_PREVIEW=(.*?);<\/script>/s)[1]);
const document=html.replace(/window\.TTM_PREVIEW=.*?;<\/script>/s,'</script>');
(async()=>{
    const browser=await chromium.launch({headless:true,...(process.env.TTM_CHROMIUM_PATH?{executablePath:process.env.TTM_CHROMIUM_PATH}:{})});
    const context=await browser.newContext(),page=await context.newPage(),errors=[],commands=[];
    let accept=true,signedOut=false;
    const state={...fixture,timestamp:Math.floor(Date.now()/1000),revision:'revision-a',transaction:null,operations:[]};
    state.discovered_networks=state.discovered_networks.slice(0,2);
    const [first,second]=state.discovered_networks;
    state.policy={schema:4,networks:[{lan_if:first.lan_if,sources:first.sources,identity:first.identity}],local_access:[],block_ipv6_bridge:true,table:871,priority:17100};
    page.on('pageerror',error=>errors.push(String(error)));
    page.on('dialog',dialog=>accept?dialog.accept():dialog.dismiss());
    await page.addInitScript(()=>{Date.now=()=>new Date().getTime()+86400000;});
    await context.route('**/*',async route=>{
        const url=new URL(route.request().url());
        if(url.origin!=='https://router.test')return route.abort();
        if(url.pathname==='/user1.asp')return route.fulfill({contentType:'text/html',body:document});
        if(url.pathname.endsWith('/status.json'))return route.fulfill({headers:{Date:new Date().toUTCString()},json:state});
        if(url.pathname==='/start_apply.htm'){
            const command=new URLSearchParams(route.request().postData()).get('action_script');commands.push(command);
            if(signedOut)return route.fulfill({status:403,body:'Main_Login.asp'});
            const match=command.match(/^start_ttm_do_([a-f0-9]{16})_start$/);assert.ok(match);
            state.enabled=state.process_running=state.interface_up=true;state.state='tun_ready_unverified';
            state.operations=[{id:match[1],action:'start',state:'succeeded',code:'completed',revision:state.revision}];
            return route.abort('failed'); // command succeeded, its HTTP acknowledgement was lost
        }
        return route.abort();
    });
    async function repaint(){await page.evaluate(()=>window.done_validating());await page.waitForTimeout(180);}
    try{
        await page.goto('https://router.test/user1.asp');
        await page.waitForFunction(()=>!document.getElementById('ttm-toggle').disabled);
        await page.getByRole('tab',{name:'Сети',exact:true}).click();
        state.policy.networks=[{lan_if:second.lan_if,sources:['192.168.50.44/32'],identity:second.identity}];state.revision='revision-b';
        await repaint();
        let rows=page.locator('.ttm-network');
        assert.equal(await rows.nth(0).locator('.ttm-selected').isChecked(),false);
        assert.equal(await rows.nth(1).locator('.ttm-selected').isChecked(),true);
        assert.equal(await rows.nth(1).locator('.ttm-cidrs').inputValue(),'192.168.50.44/32','clean form follows another tab, including sources');
        await rows.nth(1).locator('.ttm-network-mode').selectOption('custom');
        await rows.nth(1).locator('.ttm-cidrs').fill('192.168.50.45/32');
        state.revision='revision-c';state.policy.networks[0].sources=['192.168.50.46/32'];
        await repaint();
        assert.equal(await rows.nth(1).locator('.ttm-cidrs').inputValue(),'192.168.50.45/32','dirty draft remains intact');
        assert.equal(await page.locator('#ttm-conflict').isVisible(),true);
        assert.equal(await page.locator('#ttm-save').isDisabled(),true);
        await page.reload();
        await page.getByRole('tab',{name:'Подключение',exact:true}).click();
        assert.equal(await page.locator('#ttm-profile').isVisible(),true);
        assert.equal(await page.locator('#ttm-replace-connection').evaluate(panel=>panel.open),false);
        await page.locator('#ttm-replace-connection > summary').click();
        await page.locator('#ttm-show-password').check();
        assert.equal(await page.locator('#ttm-dirty').innerText(),'Нет несохранённых изменений');
        assert.equal(await page.locator('#ttm-save-exclusions').isDisabled(),false);
        await page.locator('#ttm-new-exclusion').fill('https://site.example/private?token=not-saved');
        await page.getByRole('button',{name:'Добавить исключение',exact:true}).click();
        assert.equal(await page.locator('#ttm-exclusion-domains').inputValue(),'site.example');
        await page.getByRole('button',{name:'Удалить исключение site.example',exact:true}).click();
        assert.equal(await page.locator('#ttm-exclusion-domains').inputValue(),'');
        // Discard an edited draft explicitly before the next independent scenario.
        await page.evaluate(()=>window.ttmClearConnection());
        await page.getByRole('tab',{name:'Сети',exact:true}).click();
        rows=page.locator('.ttm-network');
        const mode=rows.nth(0).locator('.ttm-network-mode'),sources=rows.nth(0).locator('.ttm-cidrs');
        const previous=await sources.inputValue();
        accept=false;await mode.selectOption('devices');
        assert.equal(await mode.inputValue(),'whole');assert.equal(await sources.inputValue(),previous);
        accept=true;await mode.selectOption('devices');
        assert.equal(await sources.inputValue(),'');
        await mode.selectOption('custom');await sources.fill('192.168.10.64/26');
        await mode.selectOption('whole');assert.equal(await sources.inputValue(),previous);
        await mode.selectOption('custom');assert.equal(await sources.inputValue(),'192.168.10.64/26','mode drafts allow undo without silent data loss');
        await page.reload();await page.waitForFunction(()=>!document.getElementById('ttm-toggle').disabled);
        await page.locator('#ttm-toggle').click();
        await page.waitForFunction(()=>!document.getElementById('ttm-check-operation').hidden);
        assert.equal(commands.length,1);
        assert.equal(await page.locator('#ttm-toggle').isDisabled(),true);
        state.client_updates.check={id:'0123456789abcdef',state:'available',channel:state.client_updates.channel,checked_at:state.timestamp,candidate:{tag:'v1.2.0'}};
        state.client_updates.dependencies_ready=true;state.client_updates.recovery_pending=false;
        state.client_updates.rollback_available=true;
        await repaint();
        for (const selector of ['#ttm-nightly','#ttm-update-client','#ttm-rollback-client'])
            assert.equal(await page.locator(selector).isDisabled(),true,selector+' cannot start another command while its predecessor is unresolved');
        await page.locator('#ttm-check-operation').click();
        await page.waitForFunction(()=>!document.getElementById('ttm-toggle').disabled);
        assert.equal(commands.length,1,'checking an unknown result must never repeat the command');
        assert.equal(await page.locator('#ttm-toggle').innerText(),'Отключить');
        state.metrics={process_start:'p1',rss_kib:2048,cpu_ticks:10,system_ticks:100,cpu_count:4};
        await repaint();
        state.metrics={...state.metrics,cpu_ticks:15,system_ticks:120};await repaint();
        assert.match(await page.locator('#ttm-resources').textContent(),/2.0 MiB.*100.0%/);
        await repaint();
        assert.match(await page.locator('#ttm-resources').textContent(),/100.0%/,'CPU sample remains visible between status publications');
        state.metrics={...state.metrics,process_start:'p2'};await repaint();
        assert.match(await page.locator('#ttm-resources').textContent(),/CPU —/,'new process resets the CPU baseline');
        signedOut=true;
        await page.locator('#ttm-toggle').click();
        await page.waitForFunction(()=>document.getElementById('ttm-message').textContent.includes('Сессия Merlin'));
        assert.equal(await page.locator('#ttm-check-operation').isVisible(),false,'known authentication rejection cannot leave an unknown operation lock');
        assert.deepEqual(errors,[]);
        console.log('PASS: two-tab clean/draft revision handling; saved profile and display-only password; explicit routing modes and draft restoration; URL exclusion confirmation/removal; lost HTTP reply reconciles same operation; router Date independent of computer clock; persistent CPU sample/reset; authentication rejection clears uncertain-operation lock');
    }finally{await context.close();await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
