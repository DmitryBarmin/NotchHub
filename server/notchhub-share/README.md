# NotchHub temporary transfer service

Python 3.9+ standard library only. The service stores encrypted opaque blobs for one hour; it never receives the AES key, clipboard metadata or plaintext. Each invitation is `/s/<43-character-token>#<base64url-key>`. Browsers keep the fragment locally. The landing page's explicit button passes the complete invitation to `notchhub://receive?url=…`; the receiving app decrypts locally and requests confirmation before adding the separate items to history.

Run one service process under a dedicated user with a private storage directory:

```sh
export PORT=9443
export TLS_CERT_FILE=/private/service/fullchain.pem
export TLS_KEY_FILE=/private/service/privkey.pem
export NOTCHHUB_UPLOAD_KEY_FILE=/private/service/upload-key
python3 server.py --host 0.0.0.0 --storage /private/service/blobs
```

The key file contains a generated secret of at least 32 non-whitespace characters. `NOTCHHUB_UPLOAD_KEY` is an alternative to the file. Keep secrets outside the repository. Both TLS paths are required together; with neither set, the loopback HTTP default is suitable behind an HTTPS reverse proxy or for local tests. SIGHUP reloads the certificate chain while keeping the previous valid chain on reload failure. The deployed public origin is `https://augreality.online:9443`.

* `POST /transfers`: bearer upload key, exact Content-Length, binary encrypted body; returns `201 {"id":"…","expiresAt":…}`.
* `GET /transfers/<id>`: opaque encrypted body; repeat downloads allowed until expiry.
* `GET /s/<id>`: static app invitation; no key or item content is embedded in the server response.
* `GET /health`: `{"ok":true}`.

Limits: 90 MiB per upload, 200 MiB of stored/reserved blobs, 20 stored/reserved transfers and 32 concurrent connections. One deadline watchdog limits each accepted connection to 30 seconds total, including its TLS handshake, headers and body; sending occasional bytes does not extend that deadline. TLS handshakes run in workers so a stalled handshake cannot block acceptance of other clients. Space is reserved before reading uploads. Writes use private temporary files and atomic blob replacement; incomplete uploads are removed. Committed blobs survive restarts. Expiry runs on access and every five minutes; in-flight readers retain their quota until closed. Responses disable caching; the app's download also enforces a size limit. Access logging is disabled because tokens are capabilities. Disable URL/access logging in any external proxy too.

The client uses AES-256-GCM with a fresh random key per transfer and version-authenticated ciphertext. Upload credentials stay in the sender's macOS Keychain and are only sent to its configured origin. Receiving requires an invitation from the configured origin and never sends the upload credential. AirDrop shares the invitation URL, so three selected screenshots remain three separate items after explicit acceptance.

Tests (no external network):

```sh
python3 -m unittest discover -s . -p test_server.py -v
```

The optional TLS regression generates a temporary self-signed fixture using `openssl`; it never contacts an external host. Header/body deadline tests and all service functionality use the Python standard library.
