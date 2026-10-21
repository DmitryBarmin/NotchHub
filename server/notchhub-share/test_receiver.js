'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {webcrypto} = require('node:crypto');
const receiver = require('./receiver.js');
const key = new Uint8Array(32).fill(7), token = 'a'.repeat(43);
const fragment = Buffer.from(key).toString('base64url');
const item = {id: '12345678-1234-1234-1234-123456789abc', kind: 'text', title: '<script>not executed</script>', text: 'Привет\n"data" 🐱'};
async function encode(items, version = 1) {
    const iv = new Uint8Array(12).fill(9);
    const aes = await webcrypto.subtle.importKey('raw', key, 'AES-GCM', false, ['encrypt']);
    const data = await webcrypto.subtle.encrypt({name: 'AES-GCM', iv, additionalData: new TextEncoder().encode('NotchHub.Transfer.v1'), tagLength: 128}, aes, new TextEncoder().encode(JSON.stringify({version, items})));
    return Buffer.concat([Buffer.from('NHTRANS1'), iv, Buffer.from(data)]);
}
test('same HTTPS invitation as native receiver; key never in download', () => {
    const result = receiver.invitation('https://example.com:9443/s/' + token + '#' + fragment);
    assert.deepEqual(result.key, key);
    assert.equal(result.download, 'https://example.com:9443/transfers/' + token);
    assert.ok(!result.download.includes(fragment));
    assert.doesNotThrow(() => receiver.invitation('http://127.0.0.1:9999/s/' + token + '#' + fragment));
});
test('rejects malformed and noncanonical invitations', () => {
    for (const url of ['http://example.com/s/' + token, 'https://example.com/s/' + token + '?x=1', 'https://user@example.com/s/' + token, 'https://example.com/s/%61' + token.slice(1), 'https://example.com/other/' + token]) {
        assert.throws(() => receiver.invitation(url + '#' + fragment));
    }
    assert.throws(() => receiver.invitation('https://example.com/s/' + token + '#' + 'B'.repeat(43)));
});
test('authenticated wire roundtrip preserves separate items and original bytes', async () => {
    const file = {id: '22345678-1234-1234-1234-123456789abc', kind: 'file', title: 'Binary', filename: 'example.bin', data: Buffer.from([0, 1, 255]).toString('base64')};
    const result = await receiver.decrypt(await encode([item, file]), key, webcrypto.subtle);
    assert.equal(result.length, 2);
    assert.equal(result[0].text, item.text);
    assert.equal(result[0].title, item.title);
    assert.deepEqual(result[1].data, new Uint8Array([0, 1, 255]));
    assert.equal(result[1].filename, 'example.bin');
});
test('tampered ciphertext and wrong key reveal no items', async () => {
    const data = await encode([item]);
    await assert.rejects(receiver.decrypt(data, new Uint8Array(32).fill(8), webcrypto.subtle), /расшифровать/);
    data[data.length - 1] ^= 1;
    await assert.rejects(receiver.decrypt(data, key, webcrypto.subtle), /расшифровать/);
    await assert.rejects(receiver.decrypt(new Uint8Array(10), key, webcrypto.subtle), /формат/);
});
test('rejects invalid schema, duplicates and wrong protocol version', () => {
    for (const envelope of [{version: 2, items: [item]}, {version: 1, items: []}, {version: 1, items: Array(21).fill(item)}, {version: 1, items: [item, {...item, id: item.id.toUpperCase()}]}, {version: 1, items: [{...item, kind: 'executable'}]}, {version: 1, items: [{...item, data: 'YQ=='}]}]) {
        assert.throws(() => receiver.validate(envelope));
    }
});
test('refuses traversal, control characters and bad base64 before download creation', () => {
    for (const filename of ['../x', 'x\\y', '.', '..', 'a\n.txt', 'a\u0085.txt', '']) {
        assert.throws(() => receiver.validate({version: 1, items: [{...item, kind: 'file', text: undefined, filename, data: 'YQ=='}]}));
    }
    for (const data of ['!?', 'YQ', 'YR==', '']) {
        assert.throws(() => receiver.validate({version: 1, items: [{...item, kind: 'file', text: undefined, filename: 'x.txt', data}]}));
    }
});
test('text size limit uses UTF8 bytes', () => {
    assert.throws(() => receiver.validate({version: 1, items: [{...item, text: 'я'.repeat(16 * 1024 * 1024)}]}), /лимит/);
});
test('bounded streamed response and expired transfer errors', async () => {
    const response = new Response(new Uint8Array([1, 2, 3]), {headers: {'Content-Length': '3'}});
    assert.deepEqual(await receiver.readResponse(response), new Uint8Array([1, 2, 3]));
    await assert.rejects(receiver.readResponse(new Response(null, {status: 404})), /истекла/);
    await assert.rejects(receiver.readResponse(new Response(null, {headers: {'Content-Length': String(90 * 1024 * 1024 + 1)}})), /лимит/);
});

test('large allowed binary file validates without regular-expression stack overflow', () => {
    const data = Buffer.alloc(2 * 1024 * 1024, 1).toString('base64');
    const result = receiver.validate({version: 1, items: [{...item, kind: 'file', text: undefined, filename: 'large.bin', data}]});
    assert.equal(result[0].data.length, 2 * 1024 * 1024);
});


test('timeout during WebCrypto decryption restores retry and never renders late plaintext', async () => {
    const vm = require('node:vm'), fs = require('node:fs');
    const encrypted = await encode([item]);
    let finishDecrypt, announceDecrypt, expire, cleared = false, renders = 0;
    const decryptStarted = new Promise(resolve => { announceDecrypt = resolve; });
    const elements = Object.fromEntries(['status', 'receive', 'items', 'open'].map(id => [id, {
        disabled: true, hidden: false, textContent: '', classList: {toggle() {}},
        addEventListener(type, callback) { this[type] = callback; },
        replaceChildren() { renders++; }
    }]));
    const context = {
        TextEncoder, TextDecoder, Uint8Array, URL, AbortController, DOMException, atob, btoa,
        location: {href: 'https://example.com/s/' + token + '#' + fragment},
        document: {
            getElementById(id) { return elements[id]; },
            createDocumentFragment() { renders++; throw Error('Late plaintext must not render'); }
        },
        crypto: {subtle: {
            async importKey() { return {}; },
            decrypt() { announceDecrypt(); return new Promise(resolve => { finishDecrypt = resolve; }); }
        }},
        async fetch() { return new Response(encrypted); },
        setTimeout(callback) { expire = callback; return 1; },
        clearTimeout() { cleared = true; },
        addEventListener() {}
    };
    vm.runInNewContext(fs.readFileSync(require.resolve('./receiver.js'), 'utf8'), context);
    assert.equal(elements.receive.disabled, false);
    const click = elements.receive.click();
    await decryptStarted;
    assert.equal(elements.receive.disabled, true);
    expire();
    finishDecrypt(new TextEncoder().encode(JSON.stringify({version: 1, items: [item]})));
    await click;
    assert.equal(elements.receive.disabled, false);
    assert.equal(elements.receive.hidden, false);
    assert.match(elements.status.textContent, /Получение прервано.*Попробуйте ещё раз/);
    assert.equal(renders, 0);
    assert.equal(cleared, true);
});
