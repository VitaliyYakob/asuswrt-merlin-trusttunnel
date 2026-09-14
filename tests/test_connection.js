'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const api = require('../addon/web/connection.js');
let passed = 0;
function test(name, run) {
  try { run(); passed++; } catch (error) { error.message = name + ': ' + error.message; throw error; }
}
function vi(value, width) {
  width = width || (value < 64 ? 1 : value < 16384 ? 2 : 4);
  const result = Buffer.alloc(width);
  for (let i = width - 1; i >= 0; i--) { result[i] = value % 256; value = Math.floor(value / 256); }
  result[0] |= {1: 0, 2: 64, 4: 128, 8: 192}[width];
  return result;
}
function tlv(tag, value) {
  const data = typeof value === 'string' ? Buffer.from(value, 'utf8') : Buffer.from(value);
  return Buffer.concat([vi(tag), vi(data.length), data]);
}
function link(parts) { return 'tt://?' + Buffer.concat(parts).toString('base64url'); }
function base() { return [tlv(0, [1]), tlv(1, 'vpn.example.com'), tlv(2, '203.0.113.10:443'), tlv(5, 'test-user'), tlv(6, 'test-password')]; }
function minimal(extra) { return link(base().concat(extra || [])); }
function fields(extra) { return Object.assign({hostname: 'vpn.example.com', addresses: ['203.0.113.10:443'], username: 'test-user', password: 'test-password'}, extra); }
function reject(parts, match) { assert.throws(() => api.parseLink(minimal(parts)), match); }

test('minimal link, defaults and IPv4/DNS notices', () => {
  const result = api.parseLink(minimal());
  assert.deepEqual(result.endpoint, {schema: 1, hostname: 'vpn.example.com', addresses: ['203.0.113.10:443'], username: 'test-user', password: 'test-password', protocol: 'http2', certificate: '', dns_upstreams: ['tls://1.1.1.1'], anti_dpi: false, mtu: 1350, wan_if: ''});
  assert.equal(result.name, '');
  assert.equal(result.warnings.length, 2);
});
test('version zero is accepted when version tag is absent', () => {
  assert.equal(api.parseLink(link(base().slice(1))).endpoint.hostname, 'vpn.example.com');
});
test('static independently assembled wire fixture', () => {
  // Hex encodes hostname h, address 1.2.3.4:443, username u, password p.
  const wire = Buffer.from('010168020b312e322e332e343a343433050175060170', 'hex');
  const out = api.parseLink('tt://?' + wire.toString('base64url'));
  assert.equal(out.endpoint.hostname, 'h');
  assert.deepEqual(out.endpoint.addresses, ['1.2.3.4:443']);
  assert.equal(out.endpoint.password, 'p');
});
test('all supported optional tags retain values', () => {
  const dns = ['tls://9.9.9.9', 'https://dns.example.com/dns-query'];
  const result = api.parseLink(minimal([
    tlv(2, 'other.example.com:8443'), tlv(3, ''), tlv(4, [0]), tlv(7, [0]), tlv(9, [2]), tlv(10, [1]), tlv(11, ''),
    tlv(12, 'Тестовый сервер'), tlv(13, Buffer.concat(dns.map(value => Buffer.concat([vi(Buffer.byteLength(value)), Buffer.from(value)]))))
  ]));
  assert.equal(result.name, 'Тестовый сервер');
  assert.deepEqual(result.endpoint.dns_upstreams, dns);
  assert.equal(result.endpoint.protocol, 'http3');
  assert.equal(result.endpoint.anti_dpi, true);
  assert.equal(result.endpoint.addresses.length, 2);
  assert.deepEqual(result.warnings, []);
});
test('legacy format and surrounding paste whitespace', () => {
  const result = api.parseLink('\n ' + minimal().replace('tt://?', 'tt://') + ' \n');
  assert.equal(result.endpoint.password, 'test-password');
  assert.match(result.warnings[0], /старый формат/);
});
test('last duplicate singleton wins and is disclosed', () => {
  const result = api.parseLink(minimal([tlv(1, 'new.example.com'), tlv(6, 'new-test-password')]));
  assert.equal(result.endpoint.hostname, 'new.example.com');
  assert.equal(result.endpoint.password, 'new-test-password');
  assert.ok(result.warnings.some(value => value.includes('hostname')));
  assert.ok(result.warnings.every(value => !value.includes('new-test-password')));
});
test('unknown tags skip without truncation or aliasing', () => {
  const result = api.parseLink(minimal([tlv(257, 'bad-host'), tlv(5, 'final-user')]));
  assert.equal(result.endpoint.hostname, 'vpn.example.com');
  assert.equal(result.endpoint.username, 'final-user');
  assert.ok(result.warnings.some(value => value.includes('257')));
});
test('custom SNI is not silently discarded', () => reject([tlv(3, 'sni.example.com')], /custom_sni/));
test('client random is not silently discarded', () => reject([tlv(11, 'abcd')], /client_random/));
test('TLS verification cannot be disabled by import', () => reject([tlv(7, [1])], /skip_verification/));
test('literal IPv6 requires an unsupported profile', () => reject([tlv(2, '[2001:db8::1]:443')], /IPv6/));
test('future versions reject', () => reject([tlv(0, [2])], /Версия/));
test('missing required fields reject', () => {
  for (const index of [1, 2, 3, 4]) assert.throws(() => api.parseLink(link(base().filter((_, i) => i !== index))), /обязательные/);
});
test('empty credentials and malformed UTF-8 reject', () => {
  reject([tlv(6, '')], /пароль/);
  reject([tlv(5, [0xc0, 0xaf])], /UTF-8/);
  reject([tlv(6, [0xed, 0xa0, 0x80])], /UTF-8/);
  reject([tlv(6, 'bad\u0000value')], /пароль/);
});
test('bad booleans and protocol reject', () => {
  reject([tlv(4, [2])], /логическое/);
  reject([tlv(7, [0, 1])], /логическое/);
  reject([tlv(9, [3])], /протокол/);
});
test('valid nonminimal QUIC varints are accepted', () => {
  const result = api.parseLink(minimal([tlv(0, vi(1, 8)), tlv(9, vi(2, 2))]));
  assert.equal(result.endpoint.protocol, 'http3');
});
test('truncated, trailing and overlarge varints reject', () => {
  assert.throws(() => api.parseLink(link(base().concat([Buffer.from([64])]))), /VarInt/);
  reject([tlv(0, [1, 0])], /Лишние байты/);
  reject([tlv(0, [255, 255, 255, 255, 255, 255, 255, 255])], /лимит/);
  assert.throws(() => api.parseLink(link(base().concat([Buffer.from([1, 10, 1])]))), /Обрезанное TLV/);
});
test('malformed DNS string lists reject', () => {
  reject([tlv(13, [10, 65])], /Обрезанный список/);
  const five = Array(5).fill(Buffer.from([1, 65]));
  reject([tlv(13, Buffer.concat(five))], /четырёх/);
});
test('base64url accepts only unpadded canonical encoding', () => {
  for (const input of ['http://x', 'tt://?', 'tt://?A', 'tt://?AA==', 'tt://?AA+', 'tt://?AA/', 'tt://?AA%20', 'tt://?AB']) assert.throws(() => api.parseLink(input));
});
test('resource limits', () => {
  assert.throws(() => api.parseLink('tt://?' + 'A'.repeat(32768)), /32 КиБ/);
  reject(Array(8).fill(tlv(2, '203.0.113.11:443')), /восьми/);
  reject(Array(128).fill(tlv(30, [])), /Слишком много полей/);
  reject([tlv(6, 'x'.repeat(1025))], /пароль/);
});
test('DER chains are converted to individual PEM blocks', () => {
  // Synthetic DER framing, not a valid X.509 identity; trust is checked at connection time.
  const first = Buffer.from([0x30, 3, 1, 2, 3]);
  const second = Buffer.from([0x30, 0x81, 128, ...Array(128).fill(0)]);
  const result = api.parseLink(minimal([tlv(8, Buffer.concat([first, second]))]));
  const pem = result.endpoint.certificate;
  assert.equal((pem.match(/BEGIN CERTIFICATE/g) || []).length, 2);
  const blocks = [...pem.matchAll(/-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+)-----END CERTIFICATE-----/g)];
  assert.deepEqual(Buffer.from(blocks[0][1], 'base64'), first);
  assert.deepEqual(Buffer.from(blocks[1][1], 'base64'), second);
  assert.ok(pem.split('\n').every(value => value.length <= 64));
});
test('invalid DER framing rejects', () => {
  for (const data of [[], [0x31, 1, 0], [0x30, 0x80, 0, 0], [0x30, 0], [0x30, 20, 0], [0x30, 0x82, 0, 128], [0x30, 0x81, 1, 0], [0x30, 0xff]]) reject([tlv(8, data)], /сертификат|DER/i);
});
test('certificate field cannot contain arbitrary text or private keys', () => {
  assert.throws(() => api.endpointFromFields(fields({certificate: 'not a certificate'})), /PEM/);
  assert.throws(() => api.endpointFromFields(fields({certificate: '-----BEGIN PRIVATE KEY-----\nMAE=\n-----END PRIVATE KEY-----'})), /PEM|CERTIFICATE/);
});
test('PEM normalization preserves certificate data and rejects trailing junk', () => {
  const pem = '-----BEGIN CERTIFICATE-----\r\nMAMBAgM=\r\n-----END CERTIFICATE-----\r\n';
  assert.match(api.endpointFromFields(fields({certificate: pem})).certificate, /MAMBAgM=/);
  assert.throws(() => api.endpointFromFields(fields({certificate: pem + 'junk'})), /PEM/);
});
test('manual entry normalizes hosts lists and numeric MTU only', () => {
  const result = api.endpointFromFields(fields({hostname: ' vpn.example.com ', addresses: '203.0.113.10:00443\nvpn.example.com:8443\n', dns_upstreams: 'tls://1.1.1.1\n9.9.9.9:53', mtu: '1400', username: ' user ', password: ' пароль «test» '}));
  assert.deepEqual(result.addresses, ['203.0.113.10:443', 'vpn.example.com:8443']);
  assert.equal(result.mtu, 1400);
  assert.equal(result.username, ' user ');
  assert.equal(result.password, ' пароль «test» ');
});
test('manual credentials and unicode survive JSON encoding', () => {
  const original = fields({username: 'тест', password: 'test"\\$()<>😀'});
  const result = api.endpointFromFields(original);
  assert.equal(JSON.parse(JSON.stringify(result)).password, original.password);
  assert.equal(result.username, original.username);
});
test('manual bounds and hidden unsupported fields reject', () => {
  for (const mtu of [1279, 1501, 1350.5, '1350bad', '', NaN, null]) assert.throws(() => api.endpointFromFields(fields({mtu})), /MTU/);
  for (const change of [{anti_dpi: 'false'}, {protocol: 'auto'}, {tls_profile: 'chrome'}, {skip_verification: true}, {custom_sni: 'example.com'}, {has_ipv6: true}, {schema: 2}, {wan_if: 'a;reboot'}, {dns_upstreams: []}]) assert.throws(() => api.endpointFromFields(fields(change)));
});
test('manual invalid host port and control input reject', () => {
  for (const hostname of ['bad..host', '-bad.example', 'bad-.example', '256.1.1.1', '01.2.3.4', 'x;reboot', 'x'.repeat(64) + '.com']) assert.throws(() => api.endpointFromFields(fields({hostname})));
  for (const addr of ['host:0', 'host:65536', 'host', 'host:123456', '[::1]:443', 'example.com:443;reboot']) assert.throws(() => api.endpointFromFields(fields({addresses: [addr]})));
  assert.throws(() => api.endpointFromFields(fields({password: 'test\npassword'})), /пароль/);
  assert.throws(() => api.endpointFromFields(fields({password: '\ud800'})), /Unicode/);
});
test('input objects are not mutated or aliased', () => {
  const input = fields({dns_upstreams: ['tls://1.1.1.1']});
  const before = JSON.stringify(input);
  const result = api.endpointFromFields(input);
  result.addresses[0] = 'changed'; result.dns_upstreams[0] = 'changed';
  assert.equal(JSON.stringify(input), before);
});
test('browser UMD runs without Node Buffer atob or TextDecoder', () => {
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(require.resolve('../addon/web/connection.js'), 'utf8'), sandbox);
  const result = sandbox.TTMConnection.parseLink(minimal([tlv(12, 'Сервер')]));
  assert.equal(result.name, 'Сервер');
  assert.equal(result.endpoint.hostname, 'vpn.example.com');
});
test('errors and warnings never echo a credential or whole URI', () => {
  const secret = 'do-not-echo-this-test-secret';
  const input = link(base().concat([tlv(6, secret), tlv(7, [1])]));
  try { api.parseLink(input); assert.fail('must reject'); } catch (error) {
    assert.ok(!error.message.includes(secret)); assert.ok(!error.message.includes(input));
  }
});
console.log('Connection import: ' + passed + ' regression groups passed');
