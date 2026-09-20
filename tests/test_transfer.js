'use strict';
// Real WebCrypto -> OpenSSL interoperability in an offline filesystem sandbox.
const assert=require('node:assert/strict'), fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const {spawnSync}=require('node:child_process'), {webcrypto}=require('node:crypto');
const transfer=require('../addon/web/transfer.js');
const root=path.resolve(__dirname,'..'), tmp=fs.mkdtempSync(path.join(os.tmpdir(),'ttm-transfer-'));
let passed=0;
function shell(body,expected=0) {
    const result=spawnSync('busybox',['ash','-c',`TT_BASE="$TT_PROJECT/addon"
. "$TT_BASE/lib/common.sh"
. "$TT_BASE/lib/config.sh"
. "$TT_BASE/lib/transfer.sh"
tt_dirs || exit 90
${body}`],{env:{...process.env,TT_PROJECT:root,TT_ROOT:tmp},encoding:'utf8'});
    assert.equal(result.status,expected,result.stderr); return result;
}
const run=path.join(tmp,'tmp/trusttunnel'), config=path.join(tmp,'jffs/addons/trusttunnel/config');
const id='0123456789abcdef', second='fedcba9876543210';
async function begin(value,session=id) {
    shell(`tt_transfer_begin ${session} ${transfer.count(value)}`);
    return transfer.encrypt(value,session,fs.readFileSync(path.join(run,'transfer/public.pem'),'utf8'),webcrypto);
}
function part(session,index,value) { return `tt_transfer_part ${session} ${index} ${value}`; }
(async()=>{ try {
    const policy={schema:3,networks:[{lan_if:'br1',sources:['192.168.51.0/24']}],block_ipv6_bridge:true,table:871,priority:17100};
    const request={version:1,revision:'0',kind:'policy',data:policy};
    let parts=await begin(request);
    assert.equal(fs.statSync(path.join(run,'transfer/private.pem')).mode & 0o777,0o600);
    shell(part(id,1,parts[1]),1); // out-of-order does not consume any bytes
    shell(part(second,0,parts[0]),1);
    shell(`tt_transfer_finish ${id}`,1);
    shell(part(id,0,parts[0])); shell(part(id,0,parts[0])); // exact retry idempotent
    for(let i=1;i<parts.length;i++) { assert.ok(transfer.event(id,i,parts[i]).length<=255); shell(part(id,i,parts[i])); }
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(run,'transfer/payload.json'),'utf8')),request);
    shell(`tt_transfer_finish ${id}`);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(config,'policy.json'),'utf8')),policy);
    assert.ok(!fs.existsSync(path.join(run,'transfer/private.pem')));
    const revision=fs.readFileSync(path.join(config,'revision'),'utf8');
    shell(`tt_transfer_finish ${id}`);
    assert.equal(fs.readFileSync(path.join(config,'revision'),'utf8'),revision);
    passed++;
    // Stale revision cannot replace configuration; operation failure is observable.
    parts=await begin(request,second);
    for(let i=0;i<parts.length;i++) shell(part(second,i,parts[i]));
    shell(`tt_transfer_finish ${second}`,1);
    assert.equal(JSON.parse(fs.readFileSync(path.join(run,'operations',second+'.json'))).code,'revision_conflict');
    assert.equal(fs.readFileSync(path.join(config,'revision'),'utf8'),revision); passed++;
    // OAEP corruption is rejected without writing the destination or printing data.
    const bad='1111111111111111'; parts=await begin(request,bad);
    const broken=(parts[0][0]==='0'?'1':'0')+parts[0].slice(1);
    shell(part(bad,0,broken)); shell(part(bad,1,parts[1])); shell(part(bad,2,parts[2]),1);
    assert.ok(!fs.existsSync(path.join(run,'transfer/private.pem'))); passed++;
    // Receiver/header session binding rejects otherwise valid encrypted blocks.
    const bound='2222222222222222'; await begin(request,bound);
    const wrong=await transfer.encrypt(request,id,fs.readFileSync(path.join(run,'transfer/public.pem'),'utf8'),webcrypto);
    shell(part(bound,0,wrong[0])); shell(part(bound,1,wrong[1])); shell(part(bound,2,wrong[2]),1); passed++;
    // Ciphertext decoder round-trips every possible byte, including NUL/non-ASCII.
    fs.writeFileSync(path.join(tmp,'bytes.hex'),Buffer.from(Array.from({length:256},(_,i)=>i)).toString('hex'));
    shell('LC_ALL=C awk -f "$TT_BASE/share/decode-hex.awk" "$TT_ROOT/bytes.hex" >"$TT_ROOT/bytes.bin"');
    assert.deepEqual(fs.readFileSync(path.join(tmp,'bytes.bin')),Buffer.from(Array.from({length:256},(_,i)=>i))); passed++;
    // Unicode that spans block boundaries is reconstructed byte-for-byte.
    const unicode={...request,data:{...policy,note:'я😀'.repeat(80)}};
    const uni='3333333333333333'; parts=await begin(unicode,uni);
    for(let i=0;i<parts.length;i++) shell(part(uni,i,parts[i]));
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(run,'transfer/payload.json'),'utf8')),unicode);
    shell('jq ".expires_at=0" "$TT_RUN/transfer/meta.json" >"$TT_RUN/transfer/meta.next" && mv "$TT_RUN/transfer/meta.next" "$TT_RUN/transfer/meta.json"; tt_transfer_expire');
    assert.ok(!fs.existsSync(path.join(run,'transfer/payload.json'))); passed++;
    assert.throws(()=>transfer.event('../bad',0,'a'.repeat(192)));
    assert.throws(()=>transfer.event(id,1536,'a'.repeat(192)));
    assert.throws(()=>transfer.event(id,0,'; reboot'));
    console.log('Private transfer: '+passed+' interoperability/regression groups passed');
} finally {fs.rmSync(tmp,{recursive:true,force:true});} })().catch(e=>{console.error(e); process.exitCode=1;});
