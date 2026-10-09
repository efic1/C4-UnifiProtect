# Changelog

Versions are the integer in each driver's `<version>`, which Composer uses to compare updates.
Earlier development builds are summarised rather than listed individually.

## Camera driver 53 / Setup driver 5

Found in a code review for edge cases and controller load. Each item has a regression test.

### Camera driver
- **Polling starts when it should.** It now starts as soon as address, key and camera are known:
  after the setup driver configures a new camera, after hand entry in Composer, and at boot even
  when no RTSP alias is stored. Previously a new camera did not report events until a reload.
- **Polling survives faults.** An exception while handling a reply no longer ends the poll chain, and
  a watchdog abandons a poll whose reply never arrives.
- **Replies for a previous camera are discarded** (aliases, polls, snapshots), so switching camera
  can no longer leave the old camera's stream token or frame on the new one.
- **Status recovers.** "Unreachable" and "Auth Failed" clear when the console answers again or the
  address or key is corrected, and a single poll timeout no longer reports "Unreachable".
- **Events:** a reply without a connection state is ignored (it used to fire offline then online);
  the first event after load is no longer swallowed when its timestamp was 0; continuous motion
  fires the event once per episode instead of once per poll (doorbell rings still fire every time);
  a restart no longer announces the camera as online.
- **Stream tokens are refreshed** at startup and when a camera comes back online. A refresh never
  turns RTSP on in Protect.
- **Controller load:** startup requests are spread over several seconds, the first poll is offset
  per camera, and the random generator is seeded per device so retry jitter differs between cameras.
- **Snapshot listener:** simultaneous requests share one fetch instead of some getting a 503;
  configuration arriving while the listener starts no longer creates a second one; a frame older
  than a minute is no longer served when refreshes fail.

### Setup driver
- A camera driver deleted in Composer is recreated on the next sync.
- "Done" is reported when the last driver has actually been created, and a sync that never
  completes releases itself after 30 seconds.

## Camera driver 46 / Setup driver 3

First public release.

### Camera driver
- Live video over plain RTSP (port 7447), with remote viewing over 4Sight via the static URL path
  and `http_tunnel`.
- Stream quality chosen from the size the client requests; Preferred Quality when it gives none.
- Camera dropdown populated by discovery; stream tokens fetched on selection.
- RTSP enabled in Protect automatically when a camera has none (once; can be switched off).
- Snapshot thumbnails served from a per-camera listener on the controller, fetched on demand,
  released when idle.
- Detection events (motion, person, vehicle, animal, package, doorbell, online/offline) with
  matching variables; polling off by default, with adaptive bursts.
- RTSP port held at 7447 by correcting the proxy when it reports its stored value.
- HTTP 429 retried with backoff and jitter; one request at a time per camera.
- A single derived Driver Status, ordered by dependency.
- Diagnostics action.

### Setup driver
- Creates one camera driver per Protect camera, named after it, and pushes its configuration.
- Adopts camera drivers added by hand or left from an earlier install instead of duplicating them.
- Configures cameras one at a time to stay under Protect's rate limit.
- Push Settings for rotating the API key.

## Development history

The path to the first release, in the order problems were found. Details are in
`docs/DEVELOPMENT_NOTES.md`.

- Properties outside `<config>` were silently ignored.
- Actions arrive as `LUA_ACTION`; unhandled at first.
- Unclosed `<stream>` elements (copied from Snap One's examples) broke every camera's list.
- Stored stream tokens were wiped on reload by unordered property replay.
- Proxy replies were returned from `ReceivedFromProxy`, where they are discarded; moved to
  `UIRequest`.
- Dynamic streams worked on the LAN but not remotely; replaced with the static path and
  `http_tunnel`.
- The proxy's stored port of 554 silently overrode 7447.
- Returning `""` instead of an empty document stalled the camera view.
- Missing event descriptions and an empty `<states/>` broke the Programming tab.
- A status race left "No RTSP alias" showing after the tokens loaded.
- Bulk configuration tripped Protect's rate limit.
