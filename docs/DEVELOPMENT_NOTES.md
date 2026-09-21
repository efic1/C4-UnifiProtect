# Development notes

What was learned building these drivers. Much of it is either absent from Snap One's DriverWorks
documentation or contradicted by it, and most of it was found by shipping something broken. Each
item says what the symptom was, so the next person recognises it.

The authoritative sources used were the DriverWorks documentation repositories published by Snap
One (`snap-one/docs-driverworks-*` on GitHub) and the working, open-source
[control4-frigate](https://github.com/mattstein111/control4-frigate) driver. Where the two disagreed,
the working driver was right.

---

## The camera proxy

### Answer XML requests from `UIRequest`, not `ReceivedFromProxy`

**Symptom:** the proxy asks for stream URLs, the driver logs a perfect answer, nothing plays.
Composer's Camera Test reports *Get Rtsp (H264) URL failed*.

The same command arrives at both functions. `ReceivedFromProxy` is documented as returning nothing,
and anything it returns is discarded. `UIRequest(sCommand, tParams)` is the one whose return value
reaches the proxy. This is not in the camera proxy documentation; it came from reading a working
driver.

### Remote viewing needs the static URL path and `http_tunnel`

**Symptom:** video works on the LAN, fails over 4Sight unless a port is forwarded.

Declaring `requires_dynamic_stream_urls` makes the proxy hand the client a complete URL, which the
client then fetches directly — fine on the LAN, unreachable from outside. The static path (the
proxy composes `rtsp://<address>:<port>/` plus what `GET_RTSP_H264_QUERY_STRING` returns) together
with the undocumented `http_tunnel` capability keeps Director in the media path, and 4Sight relays
it. This was established by comparing against a commercial driver known to work remotely.

For `GET_RTSP_H264_QUERY_STRING`, return the bare token. Not `/token`, not `?token`, not a full URL.

### The proxy stores its own RTSP port, and reports it back

**Symptom:** every new camera needs 7447 typed in by hand; the driver's log shows 7447 while
Control4 actually requests 554.

`default_rtsp_port` in the capabilities is not reliably applied. On load, the proxy sends
`SET_RTSP_PORT` with its *stored* value — 554 on a new device. A driver that adopts that value is
overruled by the proxy. Instead, treat a driver property as the source of truth: when the proxy
reports a different port, push `RTSP_PORT_CHANGED` and `DEFAULT_RTSP_PORT_CHANGED` back. Defer the
reply (the proxy is mid-update when it reports), repeat the startup push after a few seconds (a
device created by `C4:AddDevice` may not have a listening proxy during `OnDriverLateInit`), and bound
the retries.

Note that when the static path is in use, the proxy composes the URL from **its** port, so a log line
printing the driver's own value can be confidently wrong.

### Every response must be a well-formed document

**Symptom 1:** one camera driver breaks the camera list for every camera in the project.
**Symptom 2:** the camera view stalls with no error.

Navigator parses stream lists together, so malformed XML from one driver takes down all of them.
Snap One's own examples show `<stream ...>` elements left unclosed — that is a documentation error,
and copying it produces the first symptom. Always self-close.

The proxy asks for snapshot and MJPEG query strings even when the driver does not advertise them. A
bare `""` in reply is not a document, and produces the second symptom. Return
`<snapshot_query_string></snapshot_query_string>`, `<mjpeg_query_string></mjpeg_query_string>` and
so on.

### Snapshots need a complete URL

The static snapshot path appends to the proxy's own address, which must stay pointed at the console
for RTSP. To serve snapshots from elsewhere (here, the controller), declare
`requires_dynamic_snapshot_urls` and answer `GET_SNAPSHOT_URLS` with a complete URL. That capability
appears in the Fundamentals guide but not in the camera proxy's capability list. Dynamic snapshots
and static streams coexist fine.

Offer no snapshot URL until the listener is actually running and the controller's address is known.
Advertising `SNAPSHOT` with nothing behind it crashed the app on entering the camera view.

### `SET_RSTP_PORT`

The documentation spells it `SET_RSTP_PORT` and describes it as the "Rapid Spanning Tree Protocol
port". The proxy sends `SET_RTSP_PORT`. Handle both.

---

## driver.xml

- `<properties>`, `<actions>`, `<script>` and `<documentation>` must be **inside** `<config>`.
  Outside it they are silently ignored: the driver loads, but with no settings, no actions and no
  documentation.
- Documentation must be a file (`<documentation file="www/documentation.html"/>`) with its own
  stylesheet. Inline CDATA renders as plain text with the tags showing.
- Every `<event>` needs a `<description>`, and an empty `<states/>` must not be present. Either
  breaks Composer's Programming tab for the device.
- The version in `<version>` must be an integer; Composer uses it to compare updates.

---

## Lua runtime

- **`C4:UpdateProperty` does not fire `OnPropertyChanged`.** Only user edits do. Any code that
  updates one property and expects its handler to run silently does nothing. Apply the change
  inline.
- **Composer delivers every action as `LUA_ACTION`**, with the action's `<command>` in
  `tParams.ACTION`.
- **`OnDriverLateInit` should replay stored properties in an explicit order.** `pairs()` has no
  order, and a handler that resets dependent state (for example, clearing stream tokens when the
  camera changes) will wipe values replayed before it. Guard with an "initializing" flag.
- **A function calling a `local` defined later in the file compiles cleanly** and throws
  `attempt to call a nil value` at runtime, only when that path runs. `tools/check_forward_refs.py`
  catches it.
- **`C4:GetLocalAddress` does not exist.** It is a method of the `CreateTCPServer` object. For the
  controller's address, use `C4:GetControllerNetworkAddress()`.
- **`C4:CreateServer(0, ...)`** lets the OS pick a port. Hardcoded ports collide with other drivers.
- **Derive status from state.** Sixteen independent writers of one status property, each firing as
  its own HTTP reply landed, meant whichever finished last won — including a stale failure message
  outliving the success that should have replaced it. There is now exactly one writer, and a test
  that enforces it.

---

## UniFi Protect (integration API, 6.x)

- Base path `/proxy/protect/integration/v1`, header `X-API-KEY`.
- **The API key is refused as a URL parameter** (401), accepted as a header (200). Snapshots cannot
  be handed to Navigator as an authenticated URL for that reason.
- **Stream tokens** come from `GET /cameras/{id}/rtsps-stream`, which returns quality → `rtsps://`
  URL. The plain-RTSP URL is the same token on port 7447 with no query string. Qualities not enabled
  are null.
- **RTSP is off by default**, per camera and per quality. `POST /cameras/{id}/rtsps-stream` with
  `{"qualities":["high","medium","low"]}` enables it. The request needs `Content-Type:
  application/json`, or Protect reports every field as missing.
- **A 404 on `rtsps-stream`** usually means RTSP is off for that camera, not that the API is missing.
  Only a 404 on `/meta/info` means the latter.
- **Snapshots:** `highQuality` is supported; `w=` is not (400). A 4K frame is about 1 MB and Protect
  re-encodes on every request.
- **Rate limiting:** configuring eight cameras at once, each firing several requests, produced HTTP
  429. Pace bulk operations, keep each camera to one request at a time, retry 429 with backoff and
  jitter, and honour `Retry-After`.

---

## Testing

- **Make the stub asynchronous.** A stub that answers HTTP instantly cannot reproduce ordering bugs.
  The "No RTSP alias" race was invisible until replies were queued and delivered separately.
- **One-shot timers must fire once.** A stub that re-fired every timer on each round turned a
  bounded retry into thousands of calls, and could equally hide a real runaway.
- **Mutation-test your tests.** Several tests here passed against broken code — a stub route that
  matched any snapshot URL returned the right frame even when the driver asked the wrong camera, on
  the wrong console. Break the code a test covers and confirm it fails.
- **Read a working implementation early.** Most of the time lost on this project went to reasoning
  from thin documentation when a working open-source driver already had the answer.
