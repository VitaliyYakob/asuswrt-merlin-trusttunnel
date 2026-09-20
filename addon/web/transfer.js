/* Standard RSA-OAEP/SHA-256, ephemeral receiver key. No plaintext in native forms. */
(function (root) {
    'use strict';
    function id(crypto) {
        return Array.from(crypto.getRandomValues(new Uint8Array(8)), n => n.toString(16).padStart(2, '0')).join('');
    }
    function bytes(value) { return new TextEncoder().encode(value); }
    function count(value) { return Math.ceil(bytes(JSON.stringify(value)).length / 128); }
    async function encrypt(value, session, pem, crypto) {
        if (!/^[0-9a-f]{16}$/.test(session)) throw new Error('Некорректная сессия передачи.');
        const data = bytes(JSON.stringify(value));
        if (!data.length || data.length > 65536) throw new Error('Конфигурация превышает 64 КиБ.');
        const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, '')), c => c.charCodeAt(0));
        const key = await crypto.subtle.importKey('spki', der, {name: 'RSA-OAEP', hash: 'SHA-256'}, false, ['encrypt']);
        if (key.algorithm.modulusLength !== 2048) throw new Error('Неподдерживаемый ключ передачи.');
        const total = Math.ceil(data.length / 128), parts = [];
        for (let i = 0; i < total; i++) {
            const header = bytes('TTM1 ' + session + ' ' + i + ' ' + total + '\n');
            const body = data.subarray(i * 128, (i + 1) * 128), block = new Uint8Array(header.length + body.length);
            block.set(header); block.set(body, header.length);
            const cipher = new Uint8Array(await crypto.subtle.encrypt({name: 'RSA-OAEP'}, key, block));
            const hex = Array.from(cipher, n => n.toString(16).padStart(2, '0')).join('');
            parts.push(hex.slice(0, 192), hex.slice(192, 384), hex.slice(384));
        }
        return parts;
    }
    function event(session, index, part) {
        if (!/^[0-9a-f]{16}$/.test(session) || !Number.isInteger(index) || index < 0 || index > 1535 || !/^[0-9a-f]{128}$|^[0-9a-f]{192}$/.test(part)) throw new Error('Некорректная часть передачи.');
        const command = 'start_ttm_part_' + session + '_' + index + '_' + part;
        if (command.length > 255) throw new Error('Превышен предел команды Merlin.');
        return command;
    }
    const api = {id, count, encrypt, event};
    root.TTMTransfer = api;
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
