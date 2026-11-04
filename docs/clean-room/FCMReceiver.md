# FCMReceiver: functional specification

Written by the spec writer; contains no source code. Everything below is a description, in the spec writer's own
words, of the observable behaviour and wire formats of the projects listed under Provenance. Protobuf field tables are
the wire interface. Test vectors in section 10 were computed by the spec writer (the sources contain none).

## 1. Provenance

| Project | Package name | Version | Commit read | Licence | Copyright holder |
|---|---|---|---|---|---|
| https://github.com/Eneris/push-receiver | `@eneris/push-receiver` | 4.4.0 | `590d6d95f92193f7a320ba556208b3f948f52ddc` (2026-09-24) | MIT | "Copyright (c) 2017 Matthieu Lemoine" (LICENSE); package author field "Eneris & MatthieuLemoine" |
| https://github.com/MatthieuLemoine/push-receiver | `push-receiver` | 2.1.1 | `feb64e8342b28284a34075aa85826c8b37bac5d8` (2020-09-08) | MIT | "Copyright (c) 2017 Matthieu Lemoine" |

Both depend on the npm package `http_ece` for the decryption step (not read; the scheme is described from the public
IETF drafts it implements, see section 8). Both reference Chromium's GCM engine (`google_apis/gcm`) as the origin of
the MCS framing and protobuf schemas; the `.proto` schemas in both repositories are identical.

The Eneris fork is the primary reference (it is what Ring's `ring-client-api` uses). Where the original differs, it
is noted as "Original:".

**Important scope fact.** Both libraries register **as a Chrome browser** (a web-push subscriber), not as an Android
app. Check-in declares device type "Chrome browser"; GCM registration uses app `org.chromium.linux`; messages arrive
encrypted with web-push `aesgcm`. They take **no Android package name and no signing-certificate value**. See Gaps
(section 11) for the Android-app style that eufy Security may need.

## 2. Overview of the flow

1. If no valid persisted credentials: generate a P-256 key pair and a 16-byte auth secret; do an Android check-in
   (gets `androidId`, `securityToken`); do a GCM register (gets the GCM token); create a Firebase Installation (gets
   FID, refresh token, auth token); do an FCM registration with the web-push keys (gets the FCM token). Emit a
   credentials-changed event so the consumer persists them.
2. If valid persisted credentials: do a check-in again with the stored `androidId`/`securityToken` (response
   ignored), and refresh the Installation auth token if expired (best effort).
3. Open TLS to `mtalk.google.com:5228`, send the version byte and a LoginRequest, parse the framed stream, wait for
   LoginResponse (= ready), then receive DataMessageStanzas, decrypt them, deduplicate by persistent id, and deliver.
4. Keep the connection alive with heartbeat pings; on close, error, parse error or heartbeat timeout, tear down and
   reconnect with a linear backoff.

The consumer gives the **FCM token** (section 5.4) to the cloud service (Ring, eufy) so that service sends pushes to
this receiver.

## 3. API surface (functional)

### 3.1 Inputs

Required Firebase configuration (the client's "web app" config of the vendor's Firebase project):

| Field | Used for |
|---|---|
| `projectId` | URL path of Firebase Installations and FCM registration (`projects/<projectId>/…`); part of the credential fingerprint |
| `apiKey` | `x-goog-api-key` header on Installations and FCM registration |
| `appId` | Installations body (`appId`), Installations token refresh body |
| `messagingSenderId` | Declared required in the config type, but **not sent anywhere** by the Eneris fork (see `vapidKey`). Original: the sender id was the `authorized_entity` of the legacy subscribe call (section 5.5) |
| `authDomain`, `databaseURL`, `storageBucket`, `measurementId` | Optional, unused |

Optional settings and their defaults:

| Setting | Default | Effect |
|---|---|---|
| `credentials` | none | Persisted credentials (3.2); when absent or not matching, full registration happens |
| `persistentIds` | empty list | Persistent ids of messages already received (3.4) |
| `bundleId` | `receiver.push.com` | Part of the GCM `X-subtype` app id `wp:<bundleId>#<uuid>`; part of the fingerprint |
| `vapidKey` | empty string | When non-empty: sent as GCM register `sender` and as FCM registration `web.applicationPubKey`. When empty: GCM `sender` is the default key below and `applicationPubKey` is omitted. Part of the fingerprint |
| `chromeId` | `org.chromium.linux` | Declared, but the GCM `app` field is hard-coded to the same value |
| `chromeVersion` | `94.0.4606.51` | LoginRequest `id` = `chrome-<chromeVersion>`; check-in `chrome_version` (when set by the consumer; see 5.1) |
| `chromePlatform` | 2 (Mac) | Check-in ChromeBuildProto.platform (1 Win, 2 Mac, 3 Linux, 4 ChromeOS, 5 iOS, 6 Android) |
| `chromeChannel` | 1 (stable) | Check-in ChromeBuildProto.channel (1 stable, 2 beta, 3 dev, 4 canary, 5 unknown) |
| `timeZone` | `Europe/Prague` | Check-in `time_zone` |
| `heartbeatIntervalMs` | 300000 (5 min) | Client ping interval; 0 disables heartbeats and the LoginRequest `heartbeat_stat` |
| `debug` | false | Logging only |

Default GCM sender key (used when `vapidKey` is empty), base64url without padding:
`BDOU99-h67HcA6JeFXHbSNMu7e2yNNu3RzoMj8TM4W88jITfq7ZmPvIM1Iv-4_l2LxQcYwhqby2xGpWwzjfAnG4`
which decodes to the 65-byte uncompressed P-256 point
`043394f7dfa1ebb1dc03a25e1571db48d32eededb234dbb7473a0c8fc4cce16f3c8c84dfabb6663ef20cd48bfee3f9762f141c63086a6f2db11a95b0ce37c09c6e`
(this is the public "FCM web push server key" that the original library shipped as a byte list; both agree).

### 3.2 Credentials produced (must be persisted by the consumer)

A JSON-serialisable record with four parts:

| Path | Type | Meaning |
|---|---|---|
| `keys.privateKey` | string | P-256 private scalar, 32 bytes, base64url without padding |
| `keys.publicKey` | string | P-256 public key, uncompressed 65 bytes (`04‖X‖Y`), base64url without padding |
| `keys.authSecret` | string | 16 random bytes, base64url without padding |
| `gcm.androidId` | string | Decimal string of the unsigned 64-bit Android id from check-in |
| `gcm.securityToken` | string | Decimal string of the unsigned 64-bit security token from check-in |
| `gcm.appId` | string | The `X-subtype` used at GCM register: `wp:<bundleId>#<random UUID v4>` |
| `gcm.token` | string | GCM registration token (the text after `token=`) |
| `fcm.token` | string | **The FCM registration token** to hand to the vendor's cloud |
| `fcm.installation.fid` | string | Firebase Installation id as returned by the server |
| `fcm.installation.refreshToken` | string | Installation refresh token |
| `fcm.installation.token` | string | Installation auth token |
| `fcm.installation.createdAt` | number | Milliseconds since epoch when the auth token was obtained |
| `fcm.installation.expiresIn` | number | Lifetime in milliseconds (server sends seconds as `"604800s"`) |
| `config.bundleId`, `config.projectId`, `config.vapidKey` | strings | The fingerprint of the configuration the credentials were made for |

Validity check of persisted credentials: all of `keys`, `gcm`, `fcm`, `fcm.installation`, `config` present, and
`config` equal to the current (`bundleId`, `projectId`, `vapidKey`) — compared field for field (the source compares a
serialisation in that key order). Any mismatch triggers a full new registration (new keys, new androidId, new
tokens), and a credentials-changed event carrying old and new credentials.

Original: credentials were `{keys, fcm: <raw JSON of the subscribe response: token, pushSet>, gcm: {token, androidId,
securityToken, appId}}`, and the receiver only needed `gcm` and `keys`.

### 3.3 Events

| Event | When | Payload |
|---|---|---|
| message received | A data message was decrypted and is not a duplicate | `{ message: <JSON object parsed from the decrypted plaintext>, persistentId: <string> }` |
| credentials changed | After a new registration, or after an Installation token refresh | `{ oldCredentials?: <previous or absent>, newCredentials }` |
| connect | TLS socket connected | none |
| disconnect | Socket closed or server sent Close | none |
| ready | LoginResponse received | none; also resolves the "connect" call and a `whenReady` promise |
| heartbeat | A HeartbeatPing or HeartbeatAck was received from the server | none |

The consumer also reads the current FCM token (`credentials.fcm.token`).

Decrypted `message` shape (FCM's legacy HTTP message, as typed by the source; any field may be absent):
`data` (object of string values, the vendor's payload), `notification` (object: `title`, `body`,
`android_channel_id`, `icon`, `sound`, `tag`, `color`, `click_action`, `body_loc_key`, `body_loc_args`,
`title_loc_key`, `title_loc_args`), `from` (sender id string), `priority` (`normal`/`high`), `collapse_key`,
`fcmMessageId`, and others (`to`, `registration_ids`, `condition`, `content_available`, `mutable_content`,
`restricted_package_name`, `dry_run`). The receiver does not interpret it; it parses JSON and passes it through.
Original: the event was named for "notification" and the field was `notification` instead of `message`.

### 3.4 persistentIds handling

- The consumer supplies the persistent ids of messages it already received (from storage) and must persist each
  delivered `persistentId` itself.
- The ids given at start are sent in the first LoginRequest as `received_persistent_id` (repeated), telling the
  server those were received so it does not redeliver them.
- On LoginResponse, the list that is sent at login is cleared (it has been acknowledged by login).
- Each delivered message's persistent id is appended to an in-memory list used for de-duplication: a
  DataMessageStanza whose `persistent_id` is already in the list is dropped silently.
- Eneris quirk (observable): the dedup list and the "send at login" list are the same list only until the first
  LoginResponse; after it, the "send at login" list is a fresh empty list that nothing appends to, so reconnects send
  no `received_persistent_id`, while the dedup list keeps every id since start (it is never pruned).
- Original behaviour: one list; ids received since the last LoginResponse are appended and sent at the next login,
  then cleared on its LoginResponse (so dedup only covers ids since the last login). The original also appends the id
  of a message that failed to decrypt; Eneris does not.
- An implementer choosing semantics: sending at login every id received but not yet acknowledged by a login, and
  keeping a bounded dedup set, satisfies both observed behaviours.

## 4. HTTP conventions

Retry wrapper used for check-in, Installations and FCM registration (Eneris):
- A network error (no response): wait 10 s and retry, without counting (unbounded).
- A non-2xx response: retry with delay `min(attempt × 5 s, 15 s)` where attempt counts from 0 (so 0 s, 5 s, 10 s),
  at most 3 retries (4 attempts total), then fail with an error carrying the status.

GCM register has its own retry on top (5.2).

## 5. Registration

### 5.1 Android check-in

- `POST https://android.clients.google.com/checkin`
- Header `Content-Type: application/x-protobuf`
- Body: serialized `AndroidCheckinRequest` (no length prefix). Response body: serialized `AndroidCheckinResponse`.

Request field values (Eneris; all field numbers in 9.2):

| Field | Value |
|---|---|
| `id` (2) | Only when re-checking-in with stored credentials: the androidId as int64 |
| `security_token` (13, fixed64) | Only when re-checking-in: the securityToken as unsigned 64-bit |
| `checkin` (4) | `AndroidCheckinProto`: `type` (12) = 3 (Chrome browser); `chrome_build` (13) = { `platform` (1) = chromePlatform or 2, `chrome_version` (2) = consumer's chromeVersion or `63.0.3234.0`, `channel` (3) = chromeChannel or 1 }; Eneris also sends explicitly `last_checkin_msec` (2) = 0, `cell_operator` (6) = "", `sim_operator` (7) = "", `roaming` (8) = "", `user_number` (9) = 0 |
| `version` (14) | 3 |
| `user_serial_number` (22) | 0 |
| `time_zone` (12) | timeZone or `Europe/Prague` (Eneris only) |
| Eneris also sends explicitly | `digest` (3) = "", `desired_build` (5) = "", `locale` (6) = "", `logging_id` (7) = 0, `market_checkin` (8) = "", `fragment` (20) = 0, `user_name` (21) = "" |

Note on `chrome_version`: Eneris passes its merged configuration (default `chromeVersion` `94.0.4606.51`) to the
check-in, so in practice check-in and LoginRequest both carry `94.0.4606.51`; `63.0.3234.0` is only the fallback
when no version is configured at all. The original always sent `63.0.3234.0` and `chrome-63.0.3234.0`. The server
accepts either.

Original's request: only `checkin` {type 3, chrome_build {2, `63.0.3234.0`, 1}}, `version` 3, `user_serial_number` 0,
plus `id`/`security_token` when re-checking-in. The minimal form is sufficient.

Response: read `android_id` (7, fixed64) and `security_token` (8, fixed64), both as **unsigned** 64-bit integers,
rendered as decimal strings. Other fields (`stats_ok`, `time_msec`, settings, …) are ignored.

Encoding rules (both libraries' protobuf encoder): fields are written in ascending field-number order; an optional
field that is set is written even when it equals its default (so `""` and `0` above are on the wire); unset fields
and empty repeated fields are not written.

### 5.2 GCM register

- `POST https://android.clients.google.com/c2dm/register3`
- Headers: `Authorization: AidLogin <androidId>:<securityToken>` (decimal strings),
  `Content-Type: application/x-www-form-urlencoded`
- Form body (URL-encoded, this order): `app=org.chromium.linux`, `X-subtype=<appId>`, `device=<androidId>`,
  `sender=<vapidKey or the default key of 3.1>`
- `appId` = `wp:` + bundleId + `#` + a random UUID v4 (lowercase, hyphenated), generated once per registration
  and persisted as `gcm.appId`.
- Response: plain text. Success is `token=<TOKEN>`; the token is the part after the first `=` (the source takes the
  second `=`-separated piece, so a token itself containing `=` would be truncated; tokens do not contain `=`).
- Failure: a body containing `Error` (for example `Error=PHONE_REGISTRATION_ERROR`). Retry after 1 s, up to 5 retries
  (6 attempts), then fail ("GCM register has failed").
- Known error names: `PHONE_REGISTRATION_ERROR`, `AUTHENTICATION_FAILED`, `INVALID_SENDER`, `INVALID_PARAMETERS`,
  `InternalServerError`, `QUOTA_EXCEEDED`, `TOO_MANY_REGISTRATIONS`.

### 5.3 Firebase Installations (create)

- `POST https://firebaseinstallations.googleapis.com/v1/projects/<projectId>/installations`
- Headers: `x-goog-api-key: <apiKey>`; `x-firebase-client: <heartbeat>` where heartbeat is standard base64 (with
  padding) of the exact JSON text `{"heartbeats":[],"version":2}`, i.e.
  `eyJoZWFydGJlYXRzIjpbXSwidmVyc2lvbiI6Mn0=`. The body is JSON; the source sets no explicit `Content-Type` (the
  runtime sends `text/plain;charset=UTF-8`); sending `application/json` is the conventional choice.
- Body JSON: `{"appId": <appId>, "authVersion": "FIS_v2", "fid": <new FID>, "sdkVersion": "w:0.6.6"}`
- FID generation: 17 random bytes; replace the high 4 bits of byte 0 with `0111` (byte0 = `0x70 | (byte0 & 0x0F)`);
  base64url-encode without padding and keep the first 22 characters. The result matches `^[cdef][A-Za-z0-9_-]{21}$`.
- Response JSON: `name`, `fid` (the server's, may differ from the one sent — persist the returned one),
  `refreshToken`, `authToken: { token, expiresIn }` where `expiresIn` is a duration string like `"604800s"`.
  Persist `createdAt` = now (ms) and `expiresIn` = integer seconds × 1000.

### 5.4 Installations token refresh

- Considered expired when `createdAt` or `expiresIn` is missing/zero, or `createdAt + expiresIn − 1 h ≤ now`.
- Only checked on connect with valid persisted credentials. Failure is logged and the old credentials are kept
  (receiving does not depend on it).
- `POST https://firebaseinstallations.googleapis.com/v1/projects/<projectId>/installations/<percent-encoded FID>/authTokens:generate`
- Headers: `Authorization: FIS_v2 <refreshToken>`, `x-firebase-client` (as 5.3), `x-goog-api-key`
- Body JSON: `{"installation": {"sdkVersion": "w:0.6.6", "appId": <appId>}}`
- Response JSON: `{ token, expiresIn: "604800s" }`. Reject if `token` is missing or `expiresIn` is not a number.
  Replace token, `createdAt` = now, `expiresIn`; keep fid and refreshToken. Emit credentials changed.

### 5.5 FCM registration (web push)

- `POST https://fcmregistrations.googleapis.com/v1/projects/<projectId>/registrations`
- Headers: `x-goog-api-key: <apiKey>`, `x-goog-firebase-installations-auth: <installation auth token>`
  (body JSON; no explicit content type in the source, as in 5.3)
- Body JSON:
  `{"web": {"applicationPubKey": <vapidKey, omitted when empty>, "auth": <authSecret, base64url no padding>,
  "endpoint": "https://fcm.googleapis.com/fcm/send/<GCM token>", "p256dh": <publicKey, base64url no padding>}}`
- Response JSON: `{ name, token, web: { applicationPubKey, auth, endpoint, p256dh } }`. A response with an `error`
  object (`error.message`) is a failure. `token` is the FCM token.
- Original instead: `POST https://fcm.googleapis.com/fcm/connect/subscribe`, form-encoded `authorized_entity=<sender
  id>`, `endpoint=https://fcm.googleapis.com/fcm/send/<GCM token>`, `encryption_key=<publicKey b64url>`,
  `encryption_auth=<authSecret b64url>`; JSON response with `token` and `pushSet`. This legacy endpoint is the
  sender-id based path; it has been retired by Google (not stated in the sources; treat as historical).

### 5.6 Keys

- ECDH key pair on P-256 (prime256v1); private key 32 bytes big-endian (left-pad with zeros to 32 if a library
  returns fewer), public key uncompressed 65 bytes.
- Auth secret: 16 bytes from a CSPRNG.
- Stored and sent as base64url without `=` padding (standard base64 with `+`→`-`, `/`→`_`, `=` removed). Readers must
  accept both alphabets and missing padding (the source decodes the private key with a lenient base64 decoder).

## 6. MCS connection

### 6.1 Transport

- TLS to `mtalk.google.com`, port 5228 (server certificate validated normally, SNI = host). TCP keepalive on with a
  30 s idle delay (Eneris; original used the OS default).
- Immediately after connecting, the client writes one buffer: the version byte `0x29` (41), the LoginRequest tag
  `0x02`, then the LoginRequest length-delimited (varint length + bytes).

### 6.2 Framing

Every message in both directions after the first is `tag (1 byte) ‖ varint32 length ‖ protobuf bytes`. The first
message the server sends is preceded by its version byte.

Receiver state machine:
1. Initial state expects version + tag + size: needs at least 3 bytes buffered (1 + 1 + minimum 1-byte varint).
   Read version byte; accept 41 or more, or exactly 38; any other value is a fatal parse error.
2. Read 1 tag byte (signed byte read; all tags are < 128).
3. Read the size as a varint (up to 5 bytes, value of an int32). If the varint is incomplete in the buffer, keep
   the tag and wait for more data, retrying the size read.
4. If size > 0, wait until `size` bytes are buffered, decode by tag. If size = 0, the message is the empty/default
   message for the tag.
5. Go back to step 2 (no version byte again).
Buffer all incoming bytes without a maximum; process in a loop, not recursion (bursts and split varints must not
overflow anything). An unknown tag (no decoder; see 6.3) is a fatal parse error. A second LoginResponse is logged as
unexpected but delivered.

Fatal parse error → tear down and reconnect (6.7).

### 6.3 Tags

| Tag | Message | Decoded by receiver | Client action |
|---|---|---|---|
| 0 | HeartbeatPing | yes | Reply with HeartbeatAck (6.5); emit heartbeat |
| 1 | HeartbeatAck | yes | Emit heartbeat |
| 2 | LoginRequest | yes | Log only (client → server normally) |
| 3 | LoginResponse | yes | Clear login persistent-id list; ready |
| 4 | Close | yes | Treat as socket close: disconnect event, reconnect |
| 5 | MessageStanza | no (fatal "unknown tag") | — |
| 6 | PresenceStanza | no | — |
| 7 | IqStanza | yes | Log only; no reply (see Gaps) |
| 8 | DataMessageStanza | yes | Decrypt and deliver (7) |
| 9 | BatchPresenceStanza | no | — |
| 10 | StreamErrorStanza | yes | Not handled by client: logged as unknown and ignored (not counted in stream id) |
| 11 | HttpRequest | no | — |
| 12 | HttpResponse | no | — |
| 13 | BindAccountRequest | no | — |
| 14 | BindAccountResponse | no | — |
| 15 | TalkMetadata | no | — |

Any received message (of any handled tag) restarts the heartbeat timers (6.5).

### 6.4 LoginRequest values

| Field (number) | Value |
|---|---|
| `id` (1) | `chrome-<chromeVersion>` (default `chrome-94.0.4606.51`; original `chrome-63.0.3234.0`) |
| `domain` (2) | `mcs.android.com` |
| `user` (3) | androidId decimal string |
| `resource` (4) | androidId decimal string |
| `auth_token` (5) | securityToken decimal string |
| `device_id` (6) | `android-` + androidId in lowercase hexadecimal without leading zeros (the source parses the decimal as a *signed* 64-bit value first; ids ≥ 2^63 would produce a `-`-prefixed hex, an edge never seen in practice) |
| `setting` (8) | one entry: name `new_vc`, value `1` |
| `received_persistent_id` (10) | the persistent ids per 3.4, one field per id |
| `adaptive_heartbeat` (12) | false (written explicitly) |
| `heartbeat_stat` (13) | only when heartbeatIntervalMs > 0: `ip` = "", `timeout` = true, `interval_ms` = heartbeatIntervalMs. Original: not sent |
| `use_rmq2` (14) | true |
| `auth_service` (16) | 2 (ANDROID_ID) |
| `network_type` (17) | 1 |
| `client_event` (22) | empty (not on the wire) |
| `last_rmq_id` (7), `account_id` (15), `status` (18) | not sent |

### 6.5 Heartbeat

Eneris (the original had none):
- Timers: after the socket connects, after LoginResponse, and after **every** received message, cancel and restart
  two one-shot timers: a ping timer at `heartbeatIntervalMs` and a dead-connection timer at `2 × heartbeatIntervalMs`.
- Ping timer fires → send `0x00 ‖ varint len ‖ HeartbeatPing`. HeartbeatPing carries `last_stream_id_received` (2)
  only if a new stream id is available (see below); otherwise it is empty (`00 00`).
- Dead-connection timer fires → tear down and reconnect (6.7).
- Server HeartbeatPing → send `0x01 ‖ varint len ‖ HeartbeatAck` with `last_stream_id_received` (if new) and
  `status` (3) copied from the ping if present and non-zero.
- Stream id: the client keeps a counter of received messages, incremented once after each handled message of tag 0,
  1, 2, 3, 4, 7, 8 (including dropped duplicates and LoginResponse; not for unknown tags). "New available" means the
  counter differs from the value last reported; reporting stores it. The "last reported" value resets to −1 on each
  connection, but the counter itself is per client instance and is **not** reset on reconnect (Chromium resets it per
  connection; see Gaps).

### 6.6 DataMessageStanza handling

- Fields read: `persistent_id` (9), `app_data` (7) key/value pairs, `raw_data` (21) bytes. Others are ignored.
- Duplicate persistent id → drop silently.
- Decrypt (section 8) and parse the plaintext as UTF-8 JSON.
- These decryption failures drop the message silently (logged): missing `crypto-key` app data, missing `encryption`
  app data, or an AES-GCM authentication failure. Any other failure (for example a missing `dh`/`salt` parameter,
  invalid JSON) is raised as an error from the message handler (in Node it surfaces as an uncaught exception from the
  socket's data callback — an implementer should log and drop).
- A message without `raw_data` or without the two app data keys (an unencrypted data message) is therefore dropped.

### 6.7 Disconnect, teardown and reconnect

- Teardown: cancel the reconnect timer and heartbeat timers, detach and destroy the socket and parser, and reject the
  pending "ready" promise with "Client destroyed" (a new one is created).
- On socket close, server Close, parser error, or heartbeat timeout: teardown, then reconnect after
  `min(retryCount + 1, 15)` seconds (retryCount incremented first: 1 s, 2 s, … 15 s, 15 s …). retryCount resets to 0
  when a TLS connection succeeds. Socket errors are only logged; the close that follows drives the retry.
- Each reconnect re-runs the credential step (2.2: check-in with stored credentials, Installation refresh if expired),
  then connects and logs in again.
- A public "destroy" performs teardown without reconnecting.

## 7. Message delivery summary

Server → `08 ‖ len ‖ DataMessageStanza` → dedup on `persistent_id` → decrypt `raw_data` with keys and `app_data` →
JSON → event `{ message, persistentId }` → id appended to the dedup list.

## 8. Message decryption: web push "aesgcm" (draft-ietf-webpush-encryption-03 / draft-ietf-httpbis-encryption-encoding-03)

The scheme is **aesgcm** (the older draft scheme), not aes128gcm (RFC 8188/8291). There is no in-band header in
the payload: parameters come from app data.

### 8.1 Inputs

- `app_data` entry with key `crypto-key`, value like `dh=<b64url>` possibly with more `;`-separated parameters (for
  example `dh=…;p256ecdsa=…`). Parse by splitting on `;`, trimming, splitting each part at its first `=`, and take
  `dh`: the sender's ephemeral P-256 public key, 65 bytes uncompressed.
- `app_data` entry with key `encryption`, value like `salt=<b64url>` (possibly with `rs=<n>`). Take `salt`: 16 bytes.
  (Eneris ignores `rs` and always uses 4096; original sliced the fixed prefixes `dh=` and `salt=` instead of parsing.)
- `raw_data`: the ciphertext.
- Receiver's private key, public key (65 bytes) and auth secret (16 bytes) from credentials.

### 8.2 Key derivation

HMAC is HMAC-SHA-256. HKDF(salt, IKM, info, L) is RFC 5869 with SHA-256; for L ≤ 32 it is
`T = HMAC(HMAC(salt, IKM), info ‖ 0x01)` truncated to L.

1. `S` = ECDH(receiver private key, sender `dh` public key): the 32-byte X coordinate.
2. `IKM` = HKDF(salt = auth secret, IKM = S, info = ASCII `Content-Encoding: auth` ‖ `0x00`, L = 32).
3. `context` = ASCII `P-256` ‖ `0x00` ‖ uint16-BE(65) ‖ receiver public key (65) ‖ uint16-BE(65) ‖ sender public
   key (65). Total 5 + 1 + 2 + 65 + 2 + 65 = 140 bytes. Receiver (user agent) key first.
4. `CEK` = HKDF(salt = message salt, IKM, info = ASCII `Content-Encoding: aesgcm` ‖ `0x00` ‖ context, L = 16).
5. `NONCE` = HKDF(salt = message salt, IKM, info = ASCII `Content-Encoding: nonce` ‖ `0x00` ‖ context, L = 12).

### 8.3 Records

- Record size `rs` = 4096 (plaintext bytes per record including the padding header). Ciphertext is split into
  chunks of `rs + 16` bytes; the last chunk may be shorter. Each chunk is AES-128-GCM ciphertext followed by its
  16-byte tag, with no additional authenticated data.
- Nonce of record i (0-based): NONCE with its last 6 bytes, read as a 48-bit big-endian integer, XORed with i.
- Decrypted record: 2-byte big-endian padding length `p`, then `p` padding bytes (must be zero; nonzero padding is an
  error), then data. A record shorter than 2 bytes after decryption, or with `p` larger than the remainder, is an
  error. Concatenate the data of all records.
- In practice FCM payloads are under 4 KiB, so one record; implement the multi-record path for correctness.

## 9. Protobuf messages (proto2)

Types: `string`, `bytes`, `bool`, `int32`, `uint32`, `int64`, `uint64` are varint/length-delimited as usual
(negative int32/int64 encode as 10-byte varints); `fixed64` is 8 bytes little-endian (wire type 1). "req" =
required, "opt" = optional, "rep" = repeated.

### 9.1 MCS (package `mcs_proto`)

HeartbeatPing (tag 0) and HeartbeatAck (tag 1), same layout:

| Field | No. | Type | Label |
|---|---|---|---|
| stream_id | 1 | int32 | opt |
| last_stream_id_received | 2 | int32 | opt |
| status | 3 | int64 | opt |

ErrorInfo:

| Field | No. | Type | Label |
|---|---|---|---|
| code | 1 | int32 | req |
| message | 2 | string | opt |
| type | 3 | string | opt |
| extension | 4 | Extension | opt |

Setting:

| Field | No. | Type | Label |
|---|---|---|---|
| name | 1 | string | req |
| value | 2 | string | req |

HeartbeatStat:

| Field | No. | Type | Label |
|---|---|---|---|
| ip | 1 | string | req |
| timeout | 2 | bool | req |
| interval_ms | 3 | int32 | req |

HeartbeatConfig:

| Field | No. | Type | Label |
|---|---|---|---|
| upload_stat | 1 | bool | opt |
| ip | 2 | string | opt |
| interval_ms | 3 | int32 | opt |

ClientEvent (enum Type: UNKNOWN 0, DISCARDED_EVENTS 1, FAILED_CONNECTION 2, SUCCESSFUL_CONNECTION 3):

| Field | No. | Type | Label |
|---|---|---|---|
| type | 1 | enum Type | opt |
| number_discarded_events | 100 | uint32 | opt |
| network_type | 200 | int32 | opt |
| (reserved) | 201 | — | — |
| time_connection_started_ms | 202 | uint64 | opt |
| time_connection_ended_ms | 203 | uint64 | opt |
| error_code | 204 | int32 | opt |
| time_connection_established_ms | 300 | uint64 | opt |

LoginRequest (tag 2; enum AuthService: ANDROID_ID = 2):

| Field | No. | Type | Label |
|---|---|---|---|
| id | 1 | string | req (may be empty) |
| domain | 2 | string | req |
| user | 3 | string | req |
| resource | 4 | string | req |
| auth_token | 5 | string | req |
| device_id | 6 | string | opt |
| last_rmq_id | 7 | int64 | opt |
| setting | 8 | Setting | rep |
| received_persistent_id | 10 | string | rep |
| adaptive_heartbeat | 12 | bool | opt |
| heartbeat_stat | 13 | HeartbeatStat | opt |
| use_rmq2 | 14 | bool | opt |
| account_id | 15 | int64 | opt |
| auth_service | 16 | enum AuthService | opt |
| network_type | 17 | int32 | opt |
| status | 18 | int64 | opt |
| (reserved) | 19, 20, 21 | — | — |
| client_event | 22 | ClientEvent | rep |

LoginResponse (tag 3):

| Field | No. | Type | Label |
|---|---|---|---|
| id | 1 | string | req |
| jid | 2 | string | opt |
| error | 3 | ErrorInfo | opt |
| setting | 4 | Setting | rep |
| stream_id | 5 | int32 | opt |
| last_stream_id_received | 6 | int32 | opt |
| heartbeat_config | 7 | HeartbeatConfig | opt |
| server_timestamp | 8 | int64 | opt |

StreamErrorStanza (tag 10):

| Field | No. | Type | Label |
|---|---|---|---|
| type | 1 | string | req |
| text | 2 | string | opt |

Close (tag 4): no fields.

Extension:

| Field | No. | Type | Label |
|---|---|---|---|
| id | 1 | int32 | req |
| data | 2 | bytes | req |

IqStanza (tag 7; enum IqType: GET 0, SET 1, RESULT 2, IQ_ERROR 3):

| Field | No. | Type | Label |
|---|---|---|---|
| rmq_id | 1 | int64 | opt |
| type | 2 | enum IqType | req |
| id | 3 | string | req |
| from | 4 | string | opt |
| to | 5 | string | opt |
| error | 6 | ErrorInfo | opt |
| extension | 7 | Extension | opt |
| persistent_id | 8 | string | opt |
| stream_id | 9 | int32 | opt |
| last_stream_id_received | 10 | int32 | opt |
| account_id | 11 | int64 | opt |
| status | 12 | int64 | opt |

AppData:

| Field | No. | Type | Label |
|---|---|---|---|
| key | 1 | string | req |
| value | 2 | string | req |

DataMessageStanza (tag 8):

| Field | No. | Type | Label |
|---|---|---|---|
| id | 2 | string | opt |
| from | 3 | string | req |
| to | 4 | string | opt |
| category | 5 | string | req |
| token | 6 | string | opt |
| app_data | 7 | AppData | rep |
| from_trusted_server | 8 | bool | opt |
| persistent_id | 9 | string | opt |
| stream_id | 10 | int32 | opt |
| last_stream_id_received | 11 | int32 | opt |
| reg_id | 13 | string | opt |
| device_user_id | 16 | int64 | opt |
| ttl | 17 | int32 | opt |
| sent | 18 | int64 | opt |
| queued | 19 | int32 | opt |
| status | 20 | int64 | opt |
| raw_data | 21 | bytes | opt |
| immediate_ack | 24 | bool | opt |

StreamAck: no fields (schema says: carried in an IqStanza extension with id 13, sent after 10 unconfirmed messages).
SelectiveAck: `id` (1, string, rep) (schema says: carried in an IqStanza extension with id 12, sent after a
LoginResponse). Neither library sends them.

A decoder should tolerate missing "required" fields and skip unknown fields (forward compatibility); the reference
decoder rejects messages missing required fields, which in practice does not happen.

### 9.2 Check-in (package `checkin_proto`)

ChromeBuildProto (enum Platform: WIN 1, MAC 2, LINUX 3, CROS 4, IOS 5, ANDROID 6; enum Channel: STABLE 1, BETA 2,
DEV 3, CANARY 4, UNKNOWN 5):

| Field | No. | Type | Label |
|---|---|---|---|
| platform | 1 | enum Platform | opt |
| chrome_version | 2 | string | opt |
| channel | 3 | enum Channel | opt |

DeviceType enum: ANDROID_OS 1, IOS_OS 2, CHROME_BROWSER 3, CHROME_OS 4.

AndroidCheckinProto:

| Field | No. | Type | Label |
|---|---|---|---|
| last_checkin_msec | 2 | int64 | opt |
| cell_operator | 6 | string | opt |
| sim_operator | 7 | string | opt |
| roaming | 8 | string | opt |
| user_number | 9 | int32 | opt |
| type | 12 | enum DeviceType | opt (default ANDROID_OS) |
| chrome_build | 13 | ChromeBuildProto | opt |

GservicesSetting:

| Field | No. | Type | Label |
|---|---|---|---|
| name | 1 | bytes | req |
| value | 2 | bytes | req |

AndroidCheckinRequest:

| Field | No. | Type | Label |
|---|---|---|---|
| imei | 1 | string | opt |
| id | 2 | int64 | opt |
| digest | 3 | string | opt |
| checkin | 4 | AndroidCheckinProto | req |
| desired_build | 5 | string | opt |
| locale | 6 | string | opt |
| logging_id | 7 | int64 | opt |
| market_checkin | 8 | string | opt |
| mac_addr | 9 | string | rep |
| meid | 10 | string | opt |
| account_cookie | 11 | string | rep |
| time_zone | 12 | string | opt |
| security_token | 13 | fixed64 | opt |
| version | 14 | int32 | opt |
| ota_cert | 15 | string | rep |
| serial_number | 16 | string | opt |
| esn | 17 | string | opt |
| mac_addr_type | 19 | string | rep |
| fragment | 20 | int32 | opt |
| user_name | 21 | string | opt |
| user_serial_number | 22 | int32 | opt |

AndroidCheckinResponse:

| Field | No. | Type | Label |
|---|---|---|---|
| stats_ok | 1 | bool | req |
| time_msec | 3 | int64 | opt |
| digest | 4 | string | opt |
| setting | 5 | GservicesSetting | rep |
| market_ok | 6 | bool | opt |
| android_id | 7 | fixed64 | opt |
| security_token | 8 | fixed64 | opt |
| settings_diff | 9 | bool | opt |
| delete_setting | 10 | string | rep |
| version_info | 11 | string | opt |

## 10. Test vectors (computed by the spec writer)

The sources contain no captured traffic or crypto vectors. The following were produced by hand-encoding protobuf per
section 9 and by implementing section 8 independently with a standard crypto library (decryption round-trip
verified). Hex is lowercase; values are illustrative, not real credentials.

Common values: androidId = `4573291051937427291` (hex `3f7797fb3d33ef5b`), securityToken = `11930123874651234567`
(larger than 2^63: exercises unsigned handling).

### 10.1 Check-in request, minimal (original's form, first check-in)

`221560036a110802120b36332e302e333233342e3018017003b00100`
= checkin{type 3, chrome_build{platform 2, version "63.0.3234.0", channel 1}}, version 3, user_serial_number 0.

### 10.2 Check-in request, re-check-in with stored credentials (minimal form)

`10dbdecfe9b3ffe5bb3f221560036a110802120b36332e302e333233342e301801690761fe9a745090a57003b00100`
(field 2 varint androidId; field 13 fixed64 security token `0761fe9a745090a5` little-endian = 0xa59050749afe6107).

### 10.3 Check-in request, Eneris first check-in with its explicit defaults (time zone Europe/Prague, version 94.0.4606.51)

`1a002220100032003a004200480060036a120802120c39342e302e343630362e353118012a00320038004200620d4575726f70652f5072616775657003a00100aa0100b00100`

### 10.4 Check-in response (synthetic)

`08011880d095ffbc31395bef333dfb97773f410761fe9a745090a55a027631`
= stats_ok true, time_msec 1700000000000, android_id (fixed64) 4573291051937427291, security_token (fixed64)
11930123874651234567, version_info "v1". Expected parse: androidId `"4573291051937427291"`, securityToken
`"11930123874651234567"`.

### 10.5 GCM register request (for the values above)

Header `Authorization: AidLogin 4573291051937427291:11930123874651234567`; body (with an example UUID)
`app=org.chromium.linux&X-subtype=wp%3Areceiver.push.com%2300000000-0000-4000-8000-000000000000&device=4573291051937427291&sender=BDOU99-h67HcA6JeFXHbSNMu7e2yNNu3RzoMj8TM4W88jITfq7ZmPvIM1Iv-4_l2LxQcYwhqby2xGpWwzjfAnG4`.
Response `token=abc:XYZ` → token `abc:XYZ`.

### 10.6 Framed login (client's first write)

LoginRequest with id `chrome-94.0.4606.51`, the ids above, one received persistent id
`0:1700000000000001%7031b2e6f9fd7ecd`, heartbeat_stat interval 300000; body length 198 (varint `c601`):

```
2902c6010a136368726f6d652d39342e302e343630362e3531120f6d63732e616e64726f69642e636f6d1a1334353733323931303531393337
3432373239312213343537333239313035313933373432373239312a1431313933303132333837343635313233343536373218616e64726f69
642d33663737393766623364333365663562420b0a066e65775f76631201315223303a31373030303030303030303030303031253730333162
326536663966643765636460006a080a00100118e0a7127001800102880101
```
(one continuous hex string; line breaks for width only). Breakdown: `29` version 41, `02` tag, `c601` length, then
fields 1, 2, 3, 4, 5, 6 (`android-3f7797fb3d33ef5b`), 8 (`0a066e65775f7663120131`), 10, 12 (`6000`), 13
(`6a08 0a00 1001 18e0a712`), 14 (`7001`), 16 (`800102`), 17 (`880101`).

### 10.7 Server's first frame: LoginResponse (synthetic)

`2903220a136368726f6d652d39342e302e343630362e353112002801300140fbd095ffbc31` = version 41, tag 3, length 34,
id `chrome-94.0.4606.51`, jid "", stream_id 1, last_stream_id_received 1, server_timestamp 1700000000123.

### 10.8 Heartbeats and Close

- Empty HeartbeatPing: `0000`. HeartbeatPing with last_stream_id_received 5: `00021005`.
- HeartbeatAck with last_stream_id_received 5: `01021005`.
- Close from server: `0400` (size 0 → empty message).

### 10.9 Web push aesgcm decryption

Receiver credentials:
- privateKey hex `c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721`,
  stored `ya-p2EW6dRZrXCFXZ7HWk05Qw9s26JsSe4piKxIPZyE`
- publicKey hex `0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299`,
  stored `BGD-1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p-2eQP-EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk`
- authSecret hex `000102030405060708090a0b0c0d0e0f`, stored `AAECAwQFBgcICQoLDA0ODw`

Sender side (for reference; the receiver never sees the private key): sender private
`519b423d715f8b581f4fa8ee59f4771a5b44c8130b4e3eacca54a56dda72b464`.

App data:
- `crypto-key` = `dh=BBzL6RwHX8f08DO_okjbj8zTVl3pS7-xLzxZ_0bCcb-DzkAUxogR-aIaH9ssDmET4G23ypO3QE543HzNXKiaTKk`
  (sender public `041ccbe91c075fc7f4f033bfa248db8fccd3565de94bbfb12f3c59ff46c271bf83ce4014c68811f9a21a1fdb2c0e6113e06db7ca93b7404e78dc7ccd5ca89a4ca9`)
- `encryption` = `salt=EBESExQVFhcYGRobHB0eHw` (salt hex `101112131415161718191a1b1c1d1e1f`)

Intermediates:
- S = `874cc88baf56772eba61b4ccb240ed93d96f2345b346d0e7f9d58a3a555535d0`
- HKDF-extract(auth, S) = `64438cdaa7db21105b16ca50dfa709b6adf167240dc412ecea95dfea59c80624`
- IKM = `782ed948d714e51df9c724ef9ed0a98898ec8d40c4572a2d8006ce924fd48d78`
- context = `502d32353600 0041 <receiver public> 0041 <sender public>` (140 bytes)
- HKDF-extract(salt, IKM) = `4f087694ee388d44d5c0c51bd9dd19a784f0842343115e5fe984b5505d12d3fa`
- CEK = `c23b40dfaa417e0821c1dfa9d117dac4`
- NONCE = `c57bc42da5d2e8b43699d6a3` (record 1 would use `c57bc42da5d2e8b43699d6a2`)

Expected plaintext (120 bytes, UTF-8):
`{"data":{"event":"motion","id":"42"},"from":"123456789012","priority":"high","fcmMessageId":"0:1700000000000000%abcdef"}`

Case A, one record, no padding (raw_data, 138 bytes):
```
de0a2c8c99c9bb44f3cf176169ebb7e5520b1328236e2cb0abe06a0c4ea39b8a382b175836cae27a072c438800125a51a8dd5a260fb2915d00
a8bc06455345b48a7c4bb036c51c576268bed8c697c2236bf6e2b8aa22c7a6aa77f2868dbf5a24a44629342ce7bb68cfa9068d29f3fe716d90
f056f9cb67214ff16fb8f6231058721f41965e610a32747e
```

Case B, one record, 3 zero padding bytes (decrypted record `0003 000000 <plaintext>`), 141 bytes:
```
de0957aefdd3ed41b0810d6136e6f0ee504c477e6c3b7ab4abfa214f02e8d38a6b6d01503683fc7a1c720e8350471542a0cc5f210ab19c5207
a1b714584317eac1634bb02dce57193922ed9dc6dc89692fb9ad93ac3cf9a2be61da85cacc1c36a4552e3e2de0bb68cfa9068d29f3fe716d85
a104bfce602409e920af3e37ea3e755abcaaceb6d4fc6c31e9c673
```

Case C, multi-record with `rs` = 32 (only to test record splitting and nonce XOR; pass rs = 32 to the decryptor;
chunks of 48 bytes, 5 records: four carrying 30 data bytes each and a final record with only the 2-byte padding
header), 210 bytes:
```
de0a2c8c99c9bb44f3cf176169ebb7e5520b1328236e2cb0abe06a0c4ea39b8aafcfe0adbf572f9f8fc845cf9e48a4cfacb79407181b98bed8
bb0f7e4908e843db0e4a8951bec507fa192946dc92e36e64750867da1e1aa32ef52b81de6e42971d82d07eb9eee3eda6e2cf8c5ddb3ea730b6
5b5e9dad12084fd17457db42ceec0f36644375e7ecfaf60a51d9e1097ac3e30c102d5a362610a934ae957ea1b8accbdec4add44628d7e3e3db
520530a6bad98d6e4eceae9c4d1dcbe6e6b58c270aa174aa565bf378211bae6043328c474c1529
```

All three decrypt to the plaintext above. Flipping any ciphertext byte must produce an authentication failure
(dropped silently per 6.6).

### 10.10 A full inbound DataMessageStanza frame carrying case A

Tag 8, length 448 (varint `c003`); fields id "ID1", from "123456789012", category "org.chromium.linux", app_data
crypto-key / encryption / subtype (`wp:receiver.push.com#00000000-0000-4000-8000-000000000000`), persistent_id
`0:1700000000000002%7031b2e6f9fd7ecd`, ttl 0, sent 1700000000000, raw_data (case A):
```
08c00312034944311a0c3132333435363738393031322a126f72672e6368726f6d69756d2e6c696e75783a680a0a63727970746f2d6b657912
5a64683d42427a4c365277485838663038444f5f6f6b6a626a387a54566c337053372d784c7a785a5f30624363622d447a6b4155786f67522d
61496148397373446d45543447323379704f335145353433487a4e584b6961544b6b3a290a0a656e6372797074696f6e121b73616c743d4542
4553457851564668635947526f624842306548773a440a0773756274797065123977703a72656365697665722e707573682e636f6d23303030
30303030302d303030302d343030302d383030302d3030303030303030303030304a23303a3137303030303030303030303030303225373033
31623265366639666437656364880100900180d095ffbc31aa018a01de0a2c8c99c9bb44f3cf176169ebb7e5520b1328236e2cb0abe06a0c4e
a39b8a382b175836cae27a072c438800125a51a8dd5a260fb2915d00a8bc06455345b48a7c4bb036c51c576268bed8c697c2236bf6e2b8aa22
c7a6aa77f2868dbf5a24a44629342ce7bb68cfa9068d29f3fe716d90f056f9cb67214ff16fb8f6231058721f41965e610a32747e
```
Expected event: `{ message: <the JSON of 10.9 parsed>, persistentId: "0:1700000000000002%7031b2e6f9fd7ecd" }`.
Feeding it again → no event (duplicate). Feeding it split at every byte boundary (including inside the `c003`
varint) → same single event.

### 10.11 Other constants

- `x-firebase-client` value: `eyJoZWFydGJlYXRzIjpbXSwidmVyc2lvbiI6Mn0=`
- FID check: generated FIDs must match `^[cdef][A-Za-z0-9_-]{21}$` (22 characters).

## 11. Gaps

1. **Android-app style registration is not in these sources.** Neither library registers as an Android app: there is
   no Android package name, no signing-certificate SHA-1, no `X-Android-Package` / `X-Android-Cert` headers, no
   GCM register with an Android `app`/`cert`, no check-in as `DEVICE_ANDROID_OS`, and no handling of **unencrypted**
   data messages (plain `app_data` key/values, which an Android-registered receiver gets). eufy Security's client
   library (eufy-security-client) uses its own push module of that style, and its exact fields must come from a
   separate clean-room read of that source. As written here, a message without `crypto-key`/`encryption` is dropped.
2. **The consumers' actual values** (Ring's Firebase `apiKey`, `appId`, `projectId`, `messagingSenderId`, whether
   Ring passes `vapidKey`/`bundleId`/`chromeVersion`, and Ring's and eufy's notification payload contents inside
   `data`) are not in these sources; they live in ring-client-api / eufy-security-client.
3. **IqStanza, SelectiveAck and StreamAck** are decoded or declared but never answered or sent. The schema notes say
   the server expects a SelectiveAck in an IqStanza (extension id 12) and a StreamAck (extension id 13) after 10
   unacknowledged messages; neither library implements this, and they work without it (the server redelivers until
   persistent ids are reported at the next login, which is why dedup exists). Exact IqStanza reply contents are
   unknown from these sources.
4. **Stream id semantics**: Eneris keeps the received-message counter across reconnects; Chromium (cited as origin)
   resets per connection. Which the server expects is not established by the sources.
5. **LoginResponse errors** (`error` field) are not inspected; a failed login is detected only by the server closing.
   StreamErrorStanza (tag 10) is decoded but treated as unknown.
6. **Persistent-id lifecycle** differs between the two libraries (3.4); neither bounds the list.
7. **The `rs` parameter** of the `encryption` app data is ignored by Eneris (fixed 4096). Whether FCM ever sends a
   different `rs` is unknown; honouring it is harmless.
8. **aes128gcm** (RFC 8291) is not handled by either library; FCM's legacy web-push path for these registrations
   delivers `aesgcm`. Whether the newer FCM registration API can switch to aes128gcm is unknown.
9. **Installation token** is refreshed but never used by the receiver after registration; FCM token expiry/rotation
   (the TODO "FCM token expiration") is not handled: there is no re-registration when the vendor reports an invalid
   token.
10. The http_ece dependency was not read; section 8 follows the public IETF drafts. The vectors in 10.9 are
    self-consistent (encrypt and decrypt with an independent implementation) but have not been checked against a
    capture from Google's servers.
11. The legacy `fcm/connect/subscribe` path of the original (sender-id based) is believed retired; not verified.
