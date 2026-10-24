'use strict';
// Synthetic offline UI only. No router or Internet requests are permitted.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..'),html=fs.readFileSync(path.join(root,'preview/index.html'),'utf8');
(async()=>{
 const browser=await chromium.launch({headless:true}),context=await browser.newContext({offline:true}),page=await context.newPage(),errors=[];
 await context.route('**/*',r=>r.abort());page.on('pageerror',e=>errors.push(String(e)));
 try {
  await page.setContent(html); await page.getByRole('tab',{name:'Сети',exact:true}).click();
  assert.equal(await page.locator('#ttm-ports input').count(),5);
  assert.equal(await page.locator('#ttm-ports input:checked').count(),0);
  await page.locator('#ttm-ports input[value="eth4"]').check();
  await page.locator('#ttm-ports input[value="eth3"]').check();
  assert.equal(await page.locator('#ttm-ports input:checked').count(),2);
  // Exercise actual policy export, including an exclusive port-only selection.
  await page.getByRole('button',{name:'Снять выбор',exact:true}).click();
  await page.getByText('Дополнительно: экспорт для применения по SSH',{exact:true}).click();
  const downloadPromise=page.waitForEvent('download');
  await page.getByRole('button',{name:'Скачать политику для SSH',exact:true}).click();
  const download=await downloadPromise,policy=JSON.parse(fs.readFileSync(await download.path(),'utf8'));
  assert.deepEqual(policy.networks,[]);assert.deepEqual(policy.ports.map(p=>p.interface),['eth4','eth3']);
  assert.equal(policy.schema,4);assert.ok(policy.ports.every(p=>p.lan_if==='br0' && p.identity.length===64));
  for (const input of await page.locator('#ttm-ports input').all()) await input.check();assert.equal(await page.locator('#ttm-ports input:checked').count(),5);
  await page.evaluate(()=>{
   const s=window.TTM_PREVIEW;s.client_uptime_seconds=185061;s.process_running=true;s.enabled=true;s.interface_up=true;s.state='tun_ready_unverified';
   s.timestamp=1792830000;s.traffic_observation={checked_at:1792829998,state:'traffic_observed',interval_seconds:60,sent_packets:10,received_packets:20};
   window.done_validating();
  });
  await page.getByRole('tab',{name:'Обзор',exact:true}).click();
  assert.match(await page.locator('#ttm-client-uptime').innerText(),/2 сут. 3 ч 24 мин/);
  assert.match(await page.locator('#ttm-auto-traffic').innerText(),/за 60 с: отправлено 10, получено 20/);
  const folder=path.join(root,'build/browser-screenshots');fs.mkdirSync(folder,{recursive:true});
  await page.screenshot({path:path.join(folder,'automatic-traffic.png'),fullPage:true});
  await page.getByRole('tab',{name:'Сети',exact:true}).click();await page.screenshot({path:path.join(folder,'ports.png'),fullPage:true});
  await page.setViewportSize({width:390,height:844});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  assert.deepEqual(errors,[]);console.log('PASS: independent LAN checkboxes, port-only export, all ports, uptime and dated automatic observation; offline');
 }finally{await context.close();await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
