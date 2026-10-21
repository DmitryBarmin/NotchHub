'use strict';
// Wire format shared with TransferCodec. No key or plaintext leaves this module.
const NotchHubReceiver = (() => {
    const itemBytes = 30 * 1024 * 1024, totalBytes = 60 * 1024 * 1024, wireBytes = 90 * 1024 * 1024;
    const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', {fatal: true});
    function decodeBase64(value, url = false) {
        if (typeof value !== 'string') throw Error('Повреждённые данные передачи.');
        let encoded = value;
        if (url) {
            if (!/^[A-Za-z0-9_-]{43}$/.test(value)) throw Error('В ссылке нет корректного ключа расшифровки.');
            encoded = value.replace(/-/g, '+').replace(/_/g, '/') + '=';
        } else if (value.length % 4 !== 0 || value.length > Math.ceil(itemBytes / 3) * 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
            throw Error('Повреждённый или слишком большой файл.');
        }
        const raw = atob(encoded);
        if (btoa(raw) !== encoded) throw Error('Некорректная кодировка передачи.');
        return Uint8Array.from(raw, ch => ch.charCodeAt(0));
    }
    function invitation(href) {
        const url = new URL(href);
        const match = /^\/s\/([A-Za-z0-9_-]{43})$/.exec(url.pathname);
        const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
        if (!match || url.search || url.username || url.password || !(url.protocol === 'https:' || (url.protocol === 'http:' && local))) throw Error('Некорректная ссылка передачи.');
        const key = decodeBase64(url.hash.slice(1), true);
        return {key, download: url.origin + '/transfers/' + match[1]};
    }
    function validFilename(value) {
        return typeof value === 'string' && value.length > 0 && encoder.encode(value).length <= 240 && value !== '.' && value !== '..' && !/[\/\\\p{Cc}]/u.test(value);
    }
    function validate(envelope) {
        if (!envelope || envelope.version !== 1 || !Array.isArray(envelope.items) || envelope.items.length < 1 || envelope.items.length > 20) throw Error('Неподдерживаемая или повреждённая передача.');
        const ids = new Set();
        let bytes = 0;
        return envelope.items.map((item, index) => {
            if (!item || typeof item.id !== 'string' || !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(item.id) || ids.has(item.id.toLowerCase()) || typeof item.title !== 'string' || encoder.encode(item.title).length > 4096) throw Error('Повреждённое описание элемента.');
            ids.add(item.id.toLowerCase());
            let data, filename, text;
            if (item.kind === 'text') {
                if (typeof item.text !== 'string' || !item.text.length || item.data != null || item.filename != null) throw Error('Повреждённый текст передачи.');
                text = item.text; data = encoder.encode(text); filename = 'NotchHub-text-' + (index + 1) + '.txt';
            } else if (item.kind === 'file' || item.kind === 'image') {
                if (item.text != null || !validFilename(item.filename)) throw Error('Некорректное имя файла.');
                data = decodeBase64(item.data); filename = item.filename;
            } else { throw Error('Неизвестный вид элемента.'); }
            if (!data.length || data.length > itemBytes || (bytes += data.length) > totalBytes) throw Error('Передача превышает лимит: 30 МБ на элемент, 60 МБ всего.');
            return {title: item.title, filename, text, data};
        });
    }
    async function decrypt(encrypted, key, subtle = globalThis.crypto.subtle) {
        const bytes = new Uint8Array(encrypted);
        if (bytes.length < 36 || bytes.length > wireBytes || decoder.decode(bytes.subarray(0, 8)) !== 'NHTRANS1' || key.length !== 32) throw Error('Неверный формат передачи.');
        const aes = await subtle.importKey('raw', key, 'AES-GCM', false, ['decrypt']);
        let plaintext;
        try {
            plaintext = await subtle.decrypt({name: 'AES-GCM', iv: bytes.subarray(8, 20), additionalData: encoder.encode('NotchHub.Transfer.v1'), tagLength: 128}, aes, bytes.subarray(20));
        } catch (_) { throw Error('Не удалось расшифровать: ссылка повреждена или ключ неверен.'); }
        return validate(JSON.parse(decoder.decode(plaintext)));
    }
    async function readResponse(response) {
        if (!response.ok) throw Error(response.status === 404 || response.status === 410 ? 'Ссылка истекла или передача удалена.' : 'Сервер временно недоступен. Попробуйте ещё раз.');
        const length = response.headers.get('Content-Length');
        if (length !== null && (!/^\d+$/.test(length) || Number(length) > wireBytes)) throw Error('Передача превышает лимит размера.');
        if (!response.body) throw Error('Браузер не поддерживает безопасное получение передачи.');
        const reader = response.body.getReader(), chunks = [];
        let count = 0;
        try {
            while (true) {
                const {done, value} = await reader.read();
                if (done) break;
                count += value.length;
                if (count > wireBytes) throw Error('Передача превышает лимит размера.');
                chunks.push(value);
            }
        } catch (error) { await reader.cancel().catch(() => {}); throw error; }
        const data = new Uint8Array(count);
        let offset = 0;
        for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
        return data;
    }
    return {invitation, validate, decrypt, readResponse};
})();

if (typeof module !== 'undefined' && module.exports) module.exports = NotchHubReceiver;
if (typeof document !== 'undefined') {
    const status = document.getElementById('status'), receive = document.getElementById('receive'), items = document.getElementById('items');
    const urls = [];
    let invite, operation;
    function message(text, error = false) { status.textContent = text; status.classList.toggle('error', error); }
    try {
        invite = NotchHubReceiver.invitation(location.href);
        document.getElementById('open').href = 'notchhub://receive?url=' + encodeURIComponent(location.href);
        if (!globalThis.crypto || !globalThis.crypto.subtle) throw Error('Для расшифровки нужен современный браузер и защищённое HTTPS-соединение.');
        message('Готово к получению. Нажмите кнопку, чтобы расшифровать содержимое.');
        receive.disabled = false;
    } catch (error) { message(error.message, true); }
    receive.addEventListener('click', async () => {
        receive.disabled = true; operation = new AbortController();
        const timeout = setTimeout(() => operation.abort(), 60000);
        message('Загружаем и расшифровываем в браузере…');
        try {
            const response = await fetch(invite.download, {credentials: 'omit', cache: 'no-store', redirect: 'error', referrerPolicy: 'no-referrer', signal: operation.signal});
            const decoded = await NotchHubReceiver.decrypt(await NotchHubReceiver.readResponse(response), invite.key);
            if (operation.signal.aborted) throw new DOMException('Получение прервано', 'AbortError');
            const fragment = document.createDocumentFragment();
            for (const item of decoded) {
                const card = document.createElement('article'), title = document.createElement('h2'), detail = document.createElement('p'), download = document.createElement('a');
                title.textContent = item.title || item.filename;
                detail.textContent = item.filename + ' · ' + new Intl.NumberFormat('ru-RU', {maximumFractionDigits: 1}).format(item.data.length / 1024) + ' КБ';
                card.append(title, detail);
                if (item.text !== undefined) {
                    const preview = document.createElement('textarea'); preview.readOnly = true;
                    preview.setAttribute('aria-label', 'Предпросмотр текста'); preview.value = item.text.slice(0, 4096);
                    card.append(preview);
                    if (item.text.length > 4096) { const hint = document.createElement('p'); hint.textContent = 'Показаны первые 4096 символов. Файл содержит полный текст.'; card.append(hint); }
                }
                const url = URL.createObjectURL(new Blob([item.data], {type: 'application/octet-stream'})); urls.push(url);
                download.href = url; download.download = item.filename; download.className = 'download'; download.textContent = 'Скачать';
                card.append(download); fragment.append(card);
            }
            items.replaceChildren(fragment);
            receive.hidden = true;
            message('Расшифровано элементов: ' + decoded.length + '. Выберите, что скачать.');
        } catch (error) {
            message(error.name === 'AbortError' ? 'Получение прервано. Попробуйте ещё раз.' : (error instanceof SyntaxError ? 'Повреждённое содержимое передачи.' : error.message), true);
            receive.disabled = false;
        } finally { clearTimeout(timeout); }
    });
    addEventListener('pagehide', () => { if (operation) operation.abort(); urls.forEach(url => URL.revokeObjectURL(url)); urls.length = 0; });
    addEventListener('pageshow', event => {
        if (event.persisted && invite) {
            items.replaceChildren(); receive.hidden = false; receive.disabled = false;
            message('Нажмите кнопку, чтобы получить передачу снова.');
        }
    });
}
