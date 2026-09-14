'use strict';
const assert = require('node:assert/strict');
const api = require('../addon/web/trusttunnel.js');
let passed = 0;
function test(name, run) {
    try { run(); passed++; } catch (error) { error.message = name + ': ' + error.message; throw error; }
}
const row = (lan_if = 'br1', sources = '192.168.50.0/24', selected = true) => ({lan_if, sources, selected});
const policy = (rows = [row()], dns = '1.1.1.1', acknowledge = true) => api.policyFromNetworks(rows, dns, acknowledge);
const legacy = () => api.policyFromFields('br1', '192.168.50.0/24\n10.0.0.1/32', '1.1.1.1', true);

test('legacy fields retain schema one and fixed routing ownership', () => {
    const p = legacy();
    assert.equal(p.schema, 1);
    assert.equal(p.sources.length, 2);
    assert.equal(p.table, 871);
    assert.equal(p.priority, 17100);
});
test('selected main and guest networks export schema two in row order', () => {
    const rows = [row('br0', '192.168.10.0/24'), row('br1', '192.168.50.0/24'), row('br2', '192.168.60.0/24'), row('br3', '192.168.70.0/24')];
    const p = policy(rows);
    assert.equal(p.schema, 2);
    assert.deepEqual(p.networks.map(value => value.lan_if), ['br0', 'br1', 'br2', 'br3']);
    assert.equal(p.block_ipv6_bridge, true);
    assert.equal(p.table, 871);
    assert.equal(p.priority, 17100);
});
test('unselected incomplete or invalid rows do not join the policy', () => {
    const p = policy([row('br0', '192.168.10.0/24'), row('bad bridge', 'invalid', false), row('', '', false), row('br3', '192.168.70.10/32')]);
    assert.deepEqual(p.networks.map(value => value.lan_if), ['br0', 'br3']);
});
test('all deselected and empty network list reject', () => {
    assert.throws(() => policy([]), /Выберите/);
    assert.throws(() => policy([row('br0', '', false)]), /Выберите/);
});
test('bridge names are bounded and cannot contain shell or whitespace input', () => {
    for (const bridge of ['eth0', 'br1;reboot', 'br1 x', 'br', 'br-1', 'br1.', 'br1.2.3', 'br12345678901234']) {
        assert.throws(() => policy([row(bridge)]), undefined, bridge);
    }
    assert.equal(policy([row(' br1.100 ')]).networks[0].lan_if, 'br1.100');
});
test('a bridge can appear once even with different selected sources', () => {
    assert.throws(() => policy([row('br1'), row('br1', '10.0.0.0/8')]), /несколько раз/);
    assert.equal(policy([row('br1'), row('br1', '10.0.0.0/8', false)]).networks.length, 1);
});
test('sources normalize whitespace comma and semicolon separators', () => {
    const sources = '  192.168.50.0/24,\n10.0.0.1/32; 172.16.0.0/12  ';
    assert.deepEqual(policy([row('br1', sources)]).networks[0].sources, ['192.168.50.0/24', '10.0.0.1/32', '172.16.0.0/12']);
});
test('canonical private ranges and individual devices are accepted', () => {
    for (const source of ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '192.168.50.255/32']) {
        assert.deepEqual(policy([row('br1', source)]).networks[0].sources, [source]);
    }
});
test('malformed noncanonical public and IPv6 sources reject', () => {
    for (const source of ['', '1.2.3.4;reboot', '0.0.0.0/0', '8.8.8.8/32', '10.0.0.0/7', '172.15.0.0/16',
        '192.168.1.1/24', '192.168.300.0/24', '192.168.050.0/24', '192.168.0.0/024', '192.168.0.0/33',
        '192.168.0.0/-1', '192.168.0.0/24/32', '192.168.0/24', '192.168.0.0', '::/0', 'fd00::/64']) {
        assert.throws(() => policy([row('br1', source)]), undefined, source);
    }
});
test('duplicate sources in a bridge reject', () => {
    assert.throws(() => policy([row('br1', '192.168.0.0/24,192.168.0.0/24')]), /повторяющиеся/);
});
test('same private address in different bridges remains scoped by bridge', () => {
    assert.equal(policy([row('br1', '10.0.0.1/32'), row('br2', '10.0.0.1/32')]).networks.length, 2);
});
test('16 selected bridges and 32 source rules are the supported maxima', () => {
    const rows = Array.from({length: 16}, (_, i) => row('br' + i, ['10.0.' + i + '.1/32', '10.0.' + i + '.2/32']));
    assert.equal(policy(rows).networks.length, 16);
    assert.throws(() => policy(rows.concat(row('br16', '10.0.16.1/32'))), /16 сетей/);
    rows[0].sources.push('10.0.0.3/32');
    assert.throws(() => policy(rows), /32 записей/);
});
test('unusable DNS IPv4 values reject while public resolvers are accepted', () => {
    for (const dns of ['', 'hostname', '01.1.1.1', '256.1.1.1', '1.1.1', '1.1.1.1;reboot', '::1', '0.1.1.1',
        '10.0.0.1', '127.0.0.1', '172.16.0.1', '192.168.50.1', '100.64.0.1', '169.254.0.1', '224.0.0.1', '255.255.255.255']) {
        assert.throws(() => policy([row()], dns), undefined, dns);
    }
    for (const dns of ['1.1.1.1', '9.9.9.9', '8.8.8.8']) assert.equal(policy([row()], dns).dns_ipv4, dns);
});
test('bridge-wide IPv6 acknowledgement is mandatory', () => {
    assert.throws(() => policy([row()], '1.1.1.1', false), /Подтвердите/);
    assert.throws(() => api.policyFromFields('br1', '192.168.0.0/24', '1.1.1.1', false), /Подтвердите/);
});
test('envelope preserves foreign addon settings and does not mutate inputs', () => {
    const old = {other_addon: 'preserve-me'};
    const p = legacy();
    const before = JSON.stringify(p);
    const result = JSON.parse(api.makeEnvelope(old, p));
    assert.equal(result.other_addon, 'preserve-me');
    assert.deepEqual(JSON.parse(atob(result.ttm_policy)), p);
    assert.deepEqual(old, {other_addon: 'preserve-me'});
    assert.equal(JSON.stringify(p), before);
});
test('envelope strips endpoint credentials and unrelated fields from policy input', () => {
    const secret = 'synthetic-never-send-credential';
    const p = policy();
    Object.assign(p, {password: secret, username: secret, certificate: secret, endpoint: {password: secret}, table: 999, priority: 5});
    Object.assign(p.networks[0], {password: secret, endpoint: {password: secret}, label: secret});
    const serialized = api.makeEnvelope({other_addon: 'preserved'}, p);
    const envelope = JSON.parse(serialized);
    const decoded = JSON.parse(atob(envelope.ttm_policy));
    assert.equal(serialized.includes(secret), false);
    assert.equal(JSON.stringify(decoded).includes(secret), false);
    assert.deepEqual(decoded, policy());
    assert.equal(envelope.other_addon, 'preserved');
});
test('legacy envelope also rebuilds the policy from the non-secret allowlist', () => {
    const p = Object.assign(legacy(), {password: 'synthetic-secret', endpoint: {username: 'test-user'}});
    assert.deepEqual(JSON.parse(atob(JSON.parse(api.makeEnvelope({}, p)).ttm_policy)), legacy());
});
test('envelope revalidates sources before serialization', () => {
    const p = policy(); p.networks[0].sources = ['192.168.0.0/24;reboot'];
    assert.throws(() => api.makeEnvelope({}, p));
});
test('shared settings capacity is counted in UTF-8 bytes', () => {
    assert.throws(() => api.makeEnvelope({other: 'x'.repeat(7600)}, legacy()), /Недостаточно места/);
    assert.throws(() => api.makeEnvelope({other: 'я'.repeat(3800)}, policy()), /Недостаточно места/);
});
console.log('WebUI policy: ' + passed + ' regression groups passed');
