/* TrustTunnel v1 deep links, checked against TrustTunnel v1.0.33/deeplink.
 * Client v1.1.5 pins that implementation in trusttunnel/Cargo.lock.
 * https://github.com/TrustTunnel/TrustTunnel/blob/v1.0.33/DEEP_LINK.md
 * parseLink(uri) -> {endpoint: schema-1 object, name: string, warnings: string[]}.
 * endpointFromFields(fields) -> schema-1 object. Lists accept arrays or lines.
 * splitExclusions(values) -> validated domain/network lists for the WebUI.
 * This module is pure: no network, persistence, logging or connection side effects.
 * Certificate validation checks DER/PEM framing; the client verifies X.509 trust.
 */
(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.TTMConnection = api;
}(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  var MAX_LINK = 32768;
  var MAX_PAYLOAD = 24576;
  var MAX_CERT = 16384;
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var KEYS = ['schema', 'hostname', 'addresses', 'username', 'password', 'protocol', 'certificate', 'dns_upstreams', 'exclusions', 'anti_dpi', 'mtu', 'wan_if'];
  var TAGS = ['version', 'hostname', 'addresses', 'custom_sni', 'has_ipv6', 'username', 'password', 'skip_verification', 'certificate', 'upstream_protocol', 'anti_dpi', 'client_random_prefix', 'name', 'dns_upstreams'];
  function fail(message) { throw new Error(message); }
  function own(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }
  function codepoints(value) { return Array.from(value).length; }
  function clean(value, limit, label, empty) {
    if (typeof value !== 'string' || (!empty && !value.length) || codepoints(value) > limit || /[\x00-\x1f\x7f]/.test(value)) fail('Некорректное поле: ' + label + '.');
    // Reject unpaired surrogates; JSON/TOML would otherwise change the credential.
    try { encodeURIComponent(value); } catch (_) { fail('Некорректный Unicode: ' + label + '.'); }
    return value;
  }
  function ipv4(value) {
    var parts = value.split('.');
    return parts.length === 4 && parts.every(function (part) { return /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255; });
  }
  function hostname(value, label) {
    clean(value, 253, label, false);
    if (/^[0-9.]+$/.test(value)) {
      if (!ipv4(value)) fail('Некорректный IPv4: ' + label + '.');
    } else if (!value.split('.').every(function (part) { return part.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i.test(part); })) fail('Некорректное имя хоста: ' + label + '.');
    return value;
  }
  function list(value, max, label, allowEmpty) {
    if (typeof value === 'string') value = value.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean);
    if (!Array.isArray(value) || (!allowEmpty && value.length < 1) || value.length > max) fail(label + ': требуется от ' + (allowEmpty ? 0 : 1) + ' до ' + max + ' значений, по одному в строке.');
    return value.map(function (s) { if (typeof s !== 'string') fail('Некорректное поле: ' + label + '.'); return s.trim(); });
  }
  function address(value) {
    if (value.indexOf('[') >= 0 || value.split(':').length > 2) fail('IPv6-адреса подключения пока не поддерживаются; нужен IPv4 или DNS-имя.');
    var match = /^([^:]+):([0-9]{1,5})$/.exec(value);
    if (!match || Number(match[2]) < 1 || Number(match[2]) > 65535) fail('Адрес сервера должен иметь вид host:port или IPv4:port; порт 1–65535.');
    hostname(match[1], 'адрес сервера');
    return match[1] + ':' + Number(match[2]);
  }
  function port(value) {
    if (!/^[0-9]{1,5}$/.test(value) || Number(value) < 1 || Number(value) > 65535) fail('Порт исключения должен быть числом от 1 до 65535.');
    return String(Number(value));
  }
  function cidr(value) {
    var match = /^([^/]+)\/(0|[1-9]|[12][0-9]|3[0-2])$/.exec(value);
    if (!match || !ipv4(match[1])) fail('IPv4-сеть исключения должна быть каноническим CIDR, например 203.0.113.0/24.');
    var octets = match[1].split('.').map(Number), prefix = Number(match[2]);
    var number = octets[0] * 16777216 + octets[1] * 65536 + octets[2] * 256 + octets[3];
    if (number % Math.pow(2, 32 - prefix) !== 0) fail('Укажите адрес сети, а не узла внутри CIDR исключения.');
    return match[1] + '/' + prefix;
  }
  function exclusion(value) {
    if (typeof value !== 'string') fail('Некорректное исключение.');
    value = value.trim().toLowerCase();
    clean(value, 255, 'исключение', false);
    if (/^https?:\/\//.test(value) || /[?#]/.test(value) || (value.indexOf('/') >= 0 && !/^[0-9.]+\/[0-9]{1,2}$/.test(value))) fail('Указывайте домен без протокола, пути и параметров URL.');
    if (value.indexOf(':') >= 0 && value.indexOf(']:') >= 0 || value.indexOf('[') >= 0 || (value.match(/:/g) || []).length > 1) fail('IPv6-исключения недоступны: выбранные сети работают только с IPv4.');
    if (value.indexOf('/') >= 0) return cidr(value);
    if (value.indexOf('*:') === 0) return '*:' + port(value.slice(2));
    var ipPort = /^([^:]+):(.+)$/.exec(value);
    if (ipPort) {
      if (!ipv4(ipPort[1])) fail('Порт можно указывать только для IPv4-адреса или как *:port.');
      return ipPort[1] + ':' + port(ipPort[2]);
    }
    if (ipv4(value)) return value;
    var wildcard = value.indexOf('*.') === 0, name = wildcard ? value.slice(2) : value;
    if (/^[0-9.]+$/.test(name)) fail('Некорректный IPv4-адрес исключения.');
    hostname(name, 'домен исключения');
    return (wildcard ? '*.' : '') + name;
  }
  function exclusions(value) {
    var output = list(value, 256, 'Исключения', true).map(exclusion), seen = Object.create(null);
    output.forEach(function (item) { if (seen[item]) fail('Исключения не должны повторяться.'); seen[item] = true; });
    return output;
  }
  function splitExclusions(value) {
    var result = {domains: [], networks: []};
    exclusions(value).forEach(function (item) { result[ipv4(item) || item.indexOf('/') >= 0 || item.indexOf(':') >= 0 ? 'networks' : 'domains'].push(item); });
    return result;
  }
  function encode64(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
      out += B64[a >> 2] + B64[((a & 3) << 4) | ((b || 0) >> 4)] + (i + 1 < bytes.length ? B64[((b & 15) << 2) | ((c || 0) >> 6)] : '=') + (i + 2 < bytes.length ? B64[c & 63] : '=');
    }
    return out;
  }
  function decode64(value, url) {
    if (url) {
      if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) fail('Некорректный Base64url в ссылке tt://.');
      value = value.replace(/-/g, '+').replace(/_/g, '/');
    } else if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value) || !value.length) fail('Некорректный Base64 сертификата.');
    var bare = value.replace(/=+$/, ''), out = [], accumulator = 0, bits = 0;
    for (var i = 0; i < bare.length; i++) {
      accumulator = (accumulator << 6) | B64.indexOf(bare[i]); bits += 6;
      if (bits >= 8) { bits -= 8; out.push((accumulator >> bits) & 255); accumulator &= (1 << bits) - 1; }
    }
    if (accumulator !== 0) fail('Неканоническая кодировка Base64.');
    return new Uint8Array(out);
  }
  function derBlocks(data) {
    var result = [], offset = 0;
    while (offset < data.length) {
      if (result.length >= 16) fail('Слишком длинная цепочка сертификатов.');
      var start = offset;
      if (data[offset++] !== 0x30 || offset >= data.length) fail('Некорректная DER-структура сертификата.');
      var length = data[offset++];
      if (length & 128) {
        var n = length & 127; length = 0;
        if (!n || n > 4 || offset + n > data.length || data[offset] === 0) fail('Некорректная DER-длина сертификата.');
        for (var i = 0; i < n; i++) length = length * 256 + data[offset++];
        if (length < 128) fail('Неканоническая DER-длина сертификата.');
      }
      if (!length || length > data.length - offset) fail('Обрезанный DER-сертификат.');
      offset += length;
      result.push(data.slice(start, offset));
    }
    if (!result.length) fail('Пустое поле сертификата в ссылке.');
    return result;
  }
  function derToPem(data) {
    var pem = derBlocks(data).map(function (block) { return '-----BEGIN CERTIFICATE-----\n' + encode64(block).match(/.{1,64}/g).join('\n') + '\n-----END CERTIFICATE-----\n'; }).join('');
    if (pem.length > MAX_CERT) fail('Сертификат превышает лимит 16 КиБ.');
    return pem;
  }
  function certificate(value) {
    if (typeof value !== 'string' || value.length > MAX_CERT || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) fail('Некорректный PEM-сертификат или превышен лимит 16 КиБ.');
    if (!value.trim()) return '';
    var expression = /\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n\t ]+)\s*-----END CERTIFICATE-----\s*/g;
    var offset = 0, match, output = '', count = 0;
    while ((match = expression.exec(value)) !== null) {
      if (match.index !== offset || ++count > 16) fail('Разрешены только PEM-блоки CERTIFICATE.');
      var der = decode64(match[1].replace(/\s/g, ''), false);
      if (derBlocks(der).length !== 1) fail('Один PEM-блок должен содержать один сертификат.');
      output += derToPem(der); offset = expression.lastIndex;
    }
    if (!count || offset !== value.length || output.length > MAX_CERT) fail('Некорректный PEM-сертификат.');
    return output;
  }
  function endpointFromFields(fields) {
    if (!fields || typeof fields !== 'object' || Array.isArray(fields)) fail('Параметры подключения должны быть объектом.');
    if (Object.keys(fields).some(function (key) { return KEYS.indexOf(key) < 0; })) fail('Неизвестное поле подключения; настройки не будут отброшены автоматически.');
    if (own(fields, 'schema') && fields.schema !== 1) fail('Неподдерживаемая версия схемы подключения.');
    if (typeof fields.hostname !== 'string') fail('Укажите TLS hostname.');
    var mtu = own(fields, 'mtu') ? fields.mtu : 1350;
    if (typeof mtu === 'string' && /^[0-9]+$/.test(mtu.trim())) mtu = Number(mtu.trim());
    if (typeof mtu !== 'number' || !Number.isInteger(mtu) || mtu < 1280 || mtu > 1500) fail('MTU должен быть целым числом от 1280 до 1500.');
    var protocol = own(fields, 'protocol') ? fields.protocol : 'http2';
    if (protocol !== 'http2' && protocol !== 'http3') fail('Допустимы только протоколы http2 и http3.');
    var anti = own(fields, 'anti_dpi') ? fields.anti_dpi : false;
    if (typeof anti !== 'boolean') fail('Anti-DPI должен быть логическим значением.');
    var wan = own(fields, 'wan_if') ? fields.wan_if : '';
    if (typeof wan !== 'string' || wan.length > 15 || !/^([A-Za-z][A-Za-z0-9_.-]*)?$/.test(wan)) fail('Некорректное имя WAN-интерфейса.');
    var dns = list(own(fields, 'dns_upstreams') ? fields.dns_upstreams : [], 4, 'DNS', true);
    dns.forEach(function (value) { clean(value, 512, 'DNS', false); if (/\s/.test(value)) fail('DNS-адрес не должен содержать пробелы.'); });
    var bypass = exclusions(own(fields, 'exclusions') ? fields.exclusions : []);
    return {
      schema: 1, hostname: hostname(fields.hostname.trim(), 'TLS hostname'),
      addresses: list(fields.addresses, 8, 'Адреса сервера').map(address),
      username: clean(fields.username, 256, 'имя пользователя', false),
      password: clean(fields.password, 1024, 'пароль', false),
      protocol: protocol, certificate: certificate(own(fields, 'certificate') ? fields.certificate : ''),
      dns_upstreams: dns, exclusions: bypass, anti_dpi: anti, mtu: mtu, wan_if: wan
    };
  }
  function varint(bytes, cursor) {
    if (cursor.offset >= bytes.length) fail('Обрезанное число VarInt в ссылке.');
    var first = bytes[cursor.offset++], count = 1 << (first >> 6), value = first & 63;
    if (count - 1 > bytes.length - cursor.offset) fail('Обрезанное число VarInt в ссылке.');
    for (var i = 1; i < count; i++) {
      value = value * 256 + bytes[cursor.offset++];
      if (value > Number.MAX_SAFE_INTEGER) fail('Число VarInt превышает безопасный лимит.');
    }
    return value;
  }
  function numberValue(bytes) {
    var cursor = {offset: 0}, value = varint(bytes, cursor);
    if (cursor.offset !== bytes.length) fail('Лишние байты после VarInt.');
    return value;
  }
  function utf8(bytes) {
    var encoded = '';
    for (var i = 0; i < bytes.length; i++) encoded += '%' + ('0' + bytes[i].toString(16)).slice(-2);
    try { return decodeURIComponent(encoded); } catch (_) { fail('Некорректный UTF-8 в ссылке.'); }
  }
  function booleanValue(bytes) {
    if (bytes.length !== 1 || (bytes[0] !== 0 && bytes[0] !== 1)) fail('Некорректное логическое значение в ссылке.');
    return bytes[0] === 1;
  }
  function strings(bytes) {
    var cursor = {offset: 0}, out = [];
    while (cursor.offset < bytes.length) {
      var length = varint(bytes, cursor);
      if (length > bytes.length - cursor.offset) fail('Обрезанный список DNS в ссылке.');
      if (out.length >= 4) fail('Поддерживается не более четырёх DNS-серверов.');
      out.push(utf8(bytes.slice(cursor.offset, cursor.offset + length))); cursor.offset += length;
    }
    return out;
  }
  function parseLink(link) {
    if (typeof link !== 'string' || link.length > MAX_LINK) fail('Ссылка должна быть строкой не длиннее 32 КиБ.');
    link = link.trim();
    var legacy = link.indexOf('tt://?') !== 0;
    if (link.indexOf('tt://') !== 0) fail('Ожидается ссылка tt://? из TrustTunnel.');
    var bytes = decode64(link.slice(legacy ? 5 : 6), true);
    if (bytes.length > MAX_PAYLOAD) fail('Данные ссылки превышают лимит 24 КиБ.');
    var cursor = {offset: 0}, values = Object.create(null), seen = Object.create(null), addresses = [], warnings = [], count = 0;
    if (legacy) warnings.push('Импортирован старый формат tt://; предпочтителен формат tt://?.');
    while (cursor.offset < bytes.length) {
      if (++count > 128) fail('Слишком много полей в ссылке.');
      var tag = varint(bytes, cursor), length = varint(bytes, cursor);
      if (length > bytes.length - cursor.offset) fail('Обрезанное TLV-поле в ссылке.');
      var value = bytes.slice(cursor.offset, cursor.offset + length); cursor.offset += length;
      if (tag >= TAGS.length) { warnings.push('Неизвестный тег ' + tag + ' пропущен по спецификации; проверьте совместимость конфигурации.'); continue; }
      if (seen[tag] && tag !== 2) warnings.push('Поле ' + TAGS[tag] + ' повторяется: использовано последнее значение по спецификации.');
      seen[tag] = true;
      if (tag === 0) {
        values[tag] = numberValue(value);
        if (values[tag] > 1) fail('Версия tt:// новее поддерживаемой версии 1.');
      } else if (tag === 2) {
        if (addresses.length >= 8) fail('Поддерживается не более восьми адресов сервера.');
        addresses.push(utf8(value));
      } else if (tag === 4 || tag === 7 || tag === 10) values[tag] = booleanValue(value);
      else if (tag === 8) values[tag] = derToPem(value);
      else if (tag === 9) {
        var protocol = numberValue(value);
        if (protocol !== 1 && protocol !== 2) fail('Неизвестный протокол в ссылке tt://.');
        values[tag] = protocol === 1 ? 'http2' : 'http3';
      } else if (tag === 13) values[tag] = strings(value);
      else values[tag] = utf8(value);
    }
    if (values[3]) fail('Ссылка содержит custom_sni: отдельный SNI пока не поддерживается. Настройка не будет потеряна автоматически.');
    if (values[11]) fail('Ссылка содержит client_random: TLS random prefix пока не поддерживается. Настройка не будет потеряна автоматически.');
    if (values[7] === true) fail('Ссылка отключает проверку TLS-сертификата (skip_verification); такое подключение не поддерживается.');
    if (!seen[1] || !addresses.length || !seen[5] || !seen[6]) fail('В ссылке отсутствуют обязательные параметры: hostname, адреса, имя пользователя или пароль.');
    if (!seen[4] || values[4]) warnings.push('Сервер поддерживает IPv6; этот аддон использует только IPv4 и блокирует IPv6 на выбранном мосту.');
    var dns = values[13] || [];
    if (!dns.length) warnings.push('В ссылке не указан DNS. Аддон не добавляет DNS автоматически; для запуска нужна конфигурация с DNS.');
    return {
      endpoint: endpointFromFields({hostname: values[1], addresses: addresses, username: values[5], password: values[6], protocol: values[9] || 'http2', certificate: values[8] || '', dns_upstreams: dns, anti_dpi: values[10] || false}),
      name: seen[12] ? clean(values[12], 256, 'имя сервера', true) : '',
      warnings: warnings
    };
  }
  return {parseLink: parseLink, endpointFromFields: endpointFromFields, splitExclusions: splitExclusions, exclusionsFromFields: exclusions};
}));
