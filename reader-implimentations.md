# Wall-mounted reader — implementation notes

Two candidate architectures for a wall-mounted clock-in / clock-out device for
`redmine_human_resources`. Both work on **iPhone *and* Android** without
requiring a physical card, sticker, key fob, or back-of-phone NFC tag.

The constraint that drives both designs:

- **iOS does not allow third-party apps or Apple Wallet passes to act as NFC
  tags for non-Apple-certified readers.** PassKit NFC ("VAS") certificates are
  gated to payment/transit/access partners. Android can emulate an NFC card
  trivially via HCE, but the symmetric "tap iPhone to reader" path is not
  available to a small custom deployment. Both options below avoid NFC
  emulation on the phone for this reason.

---

## Shared backend additions

Both options reuse the existing `HrTimeclockController` but add a new public
endpoint that performs a **state toggle** based on a signed token instead of
relying on the session cookie.

### New columns

`hr_user_settings`:

| column                | type     | notes                                          |
|-----------------------|----------|------------------------------------------------|
| `reader_token`        | string   | random 32-byte base32, indexed, nullable       |
| `reader_token_at`     | datetime | issued-at; used to revoke older tokens         |
| `reader_enabled`      | boolean  | user opt-in / admin override                   |

The user can rotate or revoke this in their HR settings page. Admins can
rotate it on behalf of a user from the admin area.

### New route

```
POST /hr_timeclock/reader_toggle
     params: token (HMAC), nonce, action ("auto" | "in" | "out")
     returns: 200 JSON { user, state, worked_today_seconds, message }
```

### Toggle semantics

`action=auto` (default) flips the state machine:

| Current state    | Action taken          | Resulting state |
|------------------|-----------------------|-----------------|
| idle             | start                 | working         |
| working          | stop                  | idle            |
| on_break         | resume, then stop     | idle            |
| needs_correction | reject, return error  | needs_correction|

Explicit `action=in` / `action=out` are kept for unambiguous taps when the
reader hardware has a physical switch.

### Token format

The token bound to the user is **not** sent over the air directly. Instead the
phone displays / advertises a short-lived signed payload:

```
v1.<user_id>.<unix_ts>.<nonce>.<hmac_sha256_truncated_16>
```

The HMAC is computed server-side over `user_id|unix_ts|nonce` using the user's
`reader_token` as the key. The reader endpoint:

1. Parses the payload.
2. Looks up `reader_token` for `user_id`.
3. Verifies the HMAC.
4. Rejects if `now - unix_ts > 30s` (replay window).
5. Rejects if `nonce` has been used in the last 5 minutes (cached set).
6. Calls the toggle action under `User.find(user_id)` impersonation.

The 30 s window keeps even a screenshotted QR effectively useless once a user
has walked past the camera.

### Auditability

Every reader-driven state transition writes a row to `hr_work_entries` with
`created_ip = wall device IP` and `notes = "via reader:<device_id>"` so the
audit trail in the existing calendar / CSV export distinguishes wall-device
taps from manual web-UI clicks.

---

## Option A — QR on phone screen, camera in the wall device

### How it works

1. The user opens their HR badge — either an Apple Wallet pass, a Google
   Wallet pass, or a bookmarked `https://redmine.example.com/hm/badge` page.
2. The phone screen shows a rotating QR code (refreshed every 10 s) containing
   the signed payload described above.
3. The wall device's camera reads the QR, POSTs the payload to
   `/hr_timeclock/reader_toggle`, then displays the response on its screen
   (name, new state, hours worked today, expected end of work).

### Hardware

| Part                          | Approx. price | Notes                                  |
|-------------------------------|---------------|----------------------------------------|
| Raspberry Pi Zero 2 W         | ~25 €         | also: ESP32-CAM (~10 €) for cheaper    |
| Camera module v2 / OV5640     | ~25 €         | wide-angle, fixed focus ~10–25 cm      |
| 3.5"–5" HDMI / SPI TFT screen | ~25–40 €      | shows greeting + worked time           |
| PIR or ultrasonic sensor      | ~3 €          | wakes the camera when a phone arrives  |
| Buzzer / RGB LED              | ~2 €          | success / failure feedback             |
| 3D-printed wall enclosure     | —             | camera at ~145 cm, screen at eye level |

A two-device split is also viable: ESP32-CAM as the scanner, separate ESP32 +
TFT as the display, joined by MQTT to the Redmine server. Cheaper and easier
to mount.

### Reader firmware outline (Raspberry Pi, Python)

```python
import cv2, time, requests
from pyzbar.pyzbar import decode

SERVER = "https://redmine.example.com/hr_timeclock/reader_toggle"
DEVICE = "wall-eingang-1"
DEVICE_SECRET = "..."  # mTLS or shared HMAC header for the device itself

cap = cv2.VideoCapture(0)
last_seen = {}  # nonce -> ts

while True:
    ok, frame = cap.read()
    if not ok:
        continue
    for code in decode(frame):
        payload = code.data.decode()
        nonce = payload.split(".")[3]
        if last_seen.get(nonce, 0) > time.time() - 300:
            continue  # local dedupe
        last_seen[nonce] = time.time()
        r = requests.post(SERVER, json={"token": payload, "action": "auto"},
                          headers={"X-HM-Device": DEVICE,
                                   "X-HM-Device-Sig": sign(DEVICE_SECRET, payload)},
                          timeout=4)
        show_response(r.json())  # render greeting + worked time on TFT
    time.sleep(0.05)
```

### Phone-side credential delivery

- **Apple Wallet pass**: a `.pkpass` file generated server-side per user. The
  pass contains a `barcodes[0]` entry of `format=PKBarcodeFormatQR` with
  `message` set to a deep-link that the Redmine server resolves to the live
  badge URL — Wallet does not auto-rotate the barcode content, so the QR
  encodes a *redirect* URL, not the signed token itself. The user double-taps
  the side button, Wallet shows the pass, the pass shows the QR which the
  reader resolves to the live badge page through a small phone-side fetch.
  *Simpler alternative:* skip Wallet and just give iOS users an "Add to Home
  Screen" PWA that opens directly to the live, rotating QR page.
- **Google Wallet pass**: equivalent via the Generic Pass / Loyalty Pass API.
  Same redirect trick applies.
- **No-Wallet fallback**: a bookmarked PWA page on the home screen works on
  100 % of devices, no certificates, no developer accounts. Recommended as the
  baseline; Wallet support is a polish step.

The badge page must:

- Require an active Redmine session (so an attacker with the URL alone cannot
  produce valid tokens).
- Refresh the QR every 10 s with a fresh server-signed payload.
- Increase screen brightness via `screen.wakeLock` so the camera can read it.

### UX flow

```
[ phone shows QR ] ──> [ wall camera reads ] ──> POST toggle
                                                      │
                                                      ▼
        [ TFT: "Willkommen, Anna — eingestempelt 08:47" ]
        [ TFT (on clock-out): "Tschüss, Anna —
                               heute 7h 42m, Soll erreicht" ]
```

### Security considerations

- Tokens are HMAC-signed and time-bound — replay is bounded to 30 s.
- Nonce deduplication on the server prevents replays within that window.
- The reader device authenticates itself to the server with mTLS or a shared
  device HMAC header. Without this, anyone on the LAN could POST replayed
  tokens.
- `reader_enabled` per user means a user who loses their phone can have the
  feature disabled by an admin while the rest of their account stays usable.
- Screenshots of the QR are useless after 30 s but still represent a brief
  window. Mitigation: shorter rotation (5 s) on screens that are visible to
  others, or require the user to also press a "confirm" button on the wall
  device for clock-*out* (the more sensitive direction).

### Pros

- No app to build, sign, or distribute on either platform.
- Cheap hardware, fully off-the-shelf.
- Degrades gracefully: if the camera fails, the QR page on the phone still
  works as a normal in-browser toggle button.
- Self-explanatory UX — users already know how to show a QR.

### Cons

- User has to actively unlock and present the phone screen (vs. tap-and-go).
- Camera reading is sensitive to glare and low brightness. Mitigation: hood
  the camera, force `screen.wakeLock`, allow second attempt within 2 s.

### Cost estimate

Hardware per wall device: **~70–95 €** with Raspberry Pi + screen, or
**~35–50 €** with twin ESP32s.

---

## Option B — BLE proximity with a companion app

### How it works

1. A small companion app ("HM Clock") is installed on every employee phone
   (iOS + Android).
2. The app stores a per-user secret (received once when the user logs in,
   bound to `reader_token`).
3. When the phone enters the BLE range of the wall device:
   - The wall device beacons a known service UUID.
   - The app wakes, computes a fresh HMAC payload, and either:
     - **(b1)** writes it to a GATT characteristic on the wall device, or
     - **(b2)** advertises it as manufacturer data and the wall device scans.
4. The wall device forwards the payload to the server toggle endpoint and
   displays the response.

### Hardware

| Part                          | Approx. price | Notes                                |
|-------------------------------|---------------|--------------------------------------|
| ESP32 (or nRF52)              | ~8 €          | BLE central + peripheral             |
| 3.5"–5" SPI TFT screen        | ~25 €         | shows greeting + worked time         |
| Buzzer / RGB LED              | ~2 €          | tap feedback                         |
| Optional capacitive button    | ~1 €          | physical "in"/"out" override         |

No camera, no Pi. The wall device is meaningfully cheaper than option A — the
cost moves into software (the app).

### Companion app — architecture

**Android**

- Foreground service or BLE-scoped background scan callback.
- App registers for BLE region monitoring with the wall-device service UUID.
- Can advertise (peripheral) reliably from background.
- Permissions: `BLUETOOTH_CONNECT`, `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_SCAN` (with `neverForLocation` flag on Android 12+).

**iOS**

- Core Bluetooth in central role can scan in background, but the
  service UUIDs must be listed in `Info.plist` and the system filters
  aggressively — first detection is fast, repeated detections may be
  throttled.
- Core Bluetooth in peripheral role from background is heavily restricted:
  the local name is dropped, advertising is moved to the "overflow" area,
  only other iOS devices can see it without explicitly scanning that
  service UUID.
- **Practical pattern**: make the wall device the BLE *peripheral*
  (advertising) and the phone app the *central* (scanning). When the app
  detects the wall device in range, it makes a *direct* HTTPS POST to the
  Redmine server with its signed payload. The wall device then polls
  `/hr_timeclock/reader_recent?device=...` (or receives a WebSocket /
  Action Cable push) to learn that "Anna just tapped me" and updates its
  TFT.
- This sidesteps iOS's peripheral-from-background restrictions entirely:
  the phone is always the central scanner.

### BLE protocol (recommended: phone-central variant)

```
Wall device advertises:
  Service UUID:        0000A1A1-... (custom, registered in app Info.plist)
  Manufacturer data:   device_id (2 bytes) | rssi-cal (1 byte)

Phone app behaviour:
  - Scan for service UUID, filter by RSSI ≥ -65 dBm (≈ within 1 m).
  - On detection, debounce 30 s per device_id.
  - POST {token, device_id, action: "auto"} to /hr_timeclock/reader_toggle
    with the user's session cookie (or app-issued bearer token).

Wall device behaviour:
  - Polls /hr_timeclock/reader_recent?device=<device_id>&since=<ts>
    every 1 s, or subscribes via Action Cable.
  - On new event, render greeting + state + worked-today on TFT.
```

### Reader firmware outline (ESP32, Arduino-style)

```cpp
#include <BLEDevice.h>
#include <HTTPClient.h>

void setup() {
  BLEDevice::init("HM-Clock-1");
  auto server = BLEDevice::createServer();
  auto svc = server->createService(SVC_UUID);
  svc->start();
  auto adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SVC_UUID);
  adv->setManufacturerData(buildMfgData(DEVICE_ID));
  adv->start();
}

void loop() {
  HTTPClient http;
  http.begin("https://redmine.example.com/hr_timeclock/reader_recent?device=" DEVICE_ID
             "&since=" + String(lastSeenTs));
  http.addHeader("X-HM-Device", DEVICE_ID);
  http.addHeader("X-HM-Device-Sig", signDeviceRequest());
  if (http.GET() == 200) {
    renderTftFromJson(http.getString());
  }
  delay(1000);
}
```

### Server endpoint additions (beyond shared toggle)

```
GET /hr_timeclock/reader_recent
    params: device_id, since (unix ts)
    auth:   X-HM-Device + X-HM-Device-Sig (device HMAC)
    returns: latest toggle event matching device, or 204 if none
```

### UX flow

```
[ user walks within 1 m of wall device ]
       │
       │  (phone app, woken by BLE scan, posts to server)
       ▼
[ server toggles state, records event tagged with device_id ]
       │
       ▼
[ wall device polls / receives push, renders:
  "Hallo Anna — eingestempelt 08:47" ]
```

### iOS caveats

- The app must be installed and the user must have launched it at least once
  after install for background BLE scanning to work.
- If the user force-quits the app, background scanning stops. The OS will
  re-launch the app on the next matched advertisement, but there is a delay
  on the first tap after a force-quit.
- Background scans of service UUIDs not listed in `Info.plist` are blocked.
  The wall-device service UUID must therefore be fixed at compile time.
- Bluetooth permission must be requested with a clear purpose string; older
  iOS versions additionally require Location permission for BLE.

### Security considerations

- The phone-central / server-direct variant means the wall device never sees
  the user's signed payload, so a compromised wall device cannot replay user
  tokens — it can only request `reader_recent`, which returns *its own*
  recent events.
- RSSI thresholding limits range to ~1 m, preventing tapping from across the
  room. Tunable per deployment.
- Mutual auth between wall device and server via mTLS or device HMAC, as in
  option A.
- App-issued bearer tokens are scoped (`reader.toggle`) and rotated on
  Redmine logout.

### Pros

- Most "magical" UX — phone in pocket, walk up, screen greets you.
- No camera, no QR rendering, no screen-on requirement.
- Reader hardware is cheaper than option A.

### Cons

- Two app codebases to build, sign, distribute, and maintain (or one
  cross-platform stack like Flutter / React Native — still nontrivial).
- iOS background BLE behaviour is fiddly: throttling, force-quit recovery,
  permission UX.
- Requires every employee to install and grant Bluetooth permissions, which
  is friction-heavy compared to bookmarking a page.
- Power consumption on phone is non-zero, and users will notice and complain
  if not tuned.

### Cost estimate

Hardware per wall device: **~40–55 €**. Software effort: significantly higher
than option A — budget several engineer-weeks for the app, store submissions,
and the rough edges of iOS background BLE.

---

## Comparison

| Dimension                       | Option A (QR + camera)     | Option B (BLE + app)        |
|---------------------------------|----------------------------|-----------------------------|
| User effort per tap             | unlock + show screen       | walk up to wall device      |
| Phone software required         | none (or Wallet pass / PWA)| companion app on both OSes  |
| iOS gotchas                     | minimal                    | background BLE, force-quit  |
| Hardware cost per wall device   | 35–95 €                    | 40–55 €                     |
| Engineering effort              | low (reader firmware only) | high (app + firmware)       |
| Failure-mode fallback           | trivial — page works as UI | none without the app        |
| Spoofing surface                | screenshot ≤ 30 s          | BLE replay (mitigated by HMAC + nonce) |
| Privacy footprint               | none in background         | continuous BLE scan         |
| Deployment per new employee     | bookmark / Wallet pass     | install + permissions       |

## Recommendation

Start with **A**: it delivers most of the perceived "magic" (no card, no
sticker, just the phone) with a fraction of the moving parts. Wallet
passes for iOS and Google Wallet for Android give it a polished feel
without any app development. If, after a quarter of real use, the
unlock-and-show step is the dominant complaint, layer **B** on top —
the server-side `reader_toggle` endpoint, the per-user
`reader_token`, and the wall-device display all carry over unchanged.

## Open questions to resolve before building

- Should clock-out require a second confirmation tap on the wall device, to
  prevent accidental "walked past the device on the way to the kitchen"
  clock-outs? Suggested default: yes, for `working → idle` only.
- Are reader events allowed to **resolve** an outstanding correction
  (`needs_correction`)? Suggested default: no — corrections must remain a
  web-UI action, the reader returns an error and a hint.
- Should multiple wall devices be supported (e.g. entrance + workshop)?
  Suggested default: yes — `device_id` is already in the event payload,
  admins can filter the calendar by device.
- Retention: how long are nonces cached? Suggested default: 5 minutes in
  memory, no DB persistence needed.
